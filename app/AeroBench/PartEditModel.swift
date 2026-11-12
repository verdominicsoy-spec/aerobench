import AeroBench3D
import AeroBenchKit
import Foundation
import Observation
import simd

/// Edit Part mode: the feature list on one STEP part, rebuilt by the warm
/// engine after every change. The list is the state, so undo and edits are
/// list changes, and it is saved beside the STEP after each one.
@MainActor @Observable
final class PartEditModel {
    var on = false
    private(set) var step: URL?
    private(set) var file = FeatureFile(part: nil, fingerprint: nil, features: [])
    var tool: EditFeature.Kind? {
        didSet {
            if tool != oldValue {
                draft = tool.map { EditFeature(id: nextID(), kind: $0) }
                hint = nil
            }
        }
    }
    var draft: EditFeature? {
        didSet { if draft != oldValue { rebuild() } }
    }
    var selectedFeature: String?
    private(set) var reply: PartEditReply?
    var status: String?
    var busy = false
    var saving = false
    private var hoveredEdge: Int?
    private var hoveredFace: Int?  // index in reply.faces
    /// Why the last click picked nothing, in words.
    var hint: String?
    @ObservationIgnored private var shown: Model3D?  // the rebuilt part on screen, for drawing its faces

    @ObservationIgnored var engine: WarmEngine?
    @ObservationIgnored weak var viewer: SceneKitViewer?
    @ObservationIgnored var showModel: ((Model3D) -> Void)?
    @ObservationIgnored var showError: ((String, Error) -> Void)?
    @ObservationIgnored private var runner: LatestOnly<JSONValue, PartEditReply>?
    @ObservationIgnored private weak var undoManager: UndoManager?
    @ObservationIgnored private var generation = 0  // the newest rebuild; older results are dropped

    // MARK: Session

    func start(step url: URL, engine: WarmEngine) {
        undoManager?.removeAllActions(withTarget: self)  // edits to another file must not undo into this one
        step = url
        self.engine = engine
        runner = LatestOnly { params in try PartEditReply.decode(try await engine.request("part-edit", params: params)) }
        do {
            file = try FeatureFile.load(beside: url) ?? FeatureFile(part: nil, fingerprint: nil, features: [])
        } catch {
            file = FeatureFile(part: nil, fingerprint: nil, features: [])
            showError?("Could not read the saved edits; starting afresh", error)
        }
        tool = nil
        selectedFeature = nil
        on = true
        rebuild()
    }

    func stop() {
        undoManager?.removeAllActions(withTarget: self)
        generation += 1  // a rebuild still running must not draw over the reloaded file
        on = false
        tool = nil
        reply = nil
        viewer?.setEditOverlay(edges: [], highlighted: [], selected: [], points: [])
    }

    func choosePart(_ name: String) {
        file.part = name
        file.fingerprint = nil
        save()
        rebuild()
    }

    // MARK: The list

    func set(_ features: [EditFeature], actionName: String, undo: UndoManager?) {
        let old = file.features
        undoManager = undo
        undo?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.set(old, actionName: actionName, undo: undo) }
        }
        undo?.setActionName(actionName)
        file.features = features
        save()
        rebuild()
    }

    func apply(undo: UndoManager?) {
        guard let draft, ready(draft) else { return }
        var list = file.features
        if let i = list.firstIndex(where: { $0.id == draft.id }) { list[i] = draft } else { list.append(draft) }
        set(list, actionName: Self.describe(draft), undo: undo)
        tool = nil
        selectedFeature = nil
    }

    func cancel() {
        tool = nil
        selectedFeature = nil
        rebuild()
    }

    func remove(_ id: String, undo: UndoManager?) {
        guard let f = file.features.first(where: { $0.id == id }) else { return }
        if selectedFeature == id {  // it was open in its tool: Apply must not bring it back
            selectedFeature = nil
            tool = nil
        }
        set(file.features.filter { $0.id != id }, actionName: "Remove \(Self.describe(f))", undo: undo)
    }

    /// Loads a feature into its tool's panel; Apply replaces it in place.
    func edit(_ id: String) {
        guard let f = file.features.first(where: { $0.id == id }) else { return }
        selectedFeature = id
        tool = f.kind
        draft = f
    }

    private func save() {
        guard let step else { return }
        do { try file.save(beside: step) } catch { showError?("Could not save the edits beside the STEP", error) }
    }

    private func nextID() -> String {
        let used = file.features.compactMap { Int($0.id.dropFirst()) }
        return "f\((used.max() ?? 0) + 1)"
    }

    /// Whether a draft has every pick its kind needs, so it can be previewed.
    func ready(_ f: EditFeature) -> Bool {
        switch f.kind {
        case .point, .pushpull, .mirror, .cut: f.refs.count == 1
        case .move: true
        case .deleteface, .thicken: !f.refs.isEmpty
        case .spline: f.refs.count >= 2
        case .plane, .extrude: f.refs.count == 2
        case .fill: f.refs.count >= 3
        case .add, .fillet, .chamfer: !f.refs.isEmpty
        }
    }

    static func describe(_ f: EditFeature) -> String {
        let mm = { (key: String) in f.values[key].map { String(format: "%g mm", $0) } ?? "" }
        switch f.kind {
        case .fillet: return "Fillet \(mm("radius"))"
        case .chamfer: return "Chamfer \(mm("distance"))"
        case .extrude: return "Extrude \(mm("distance"))"
        case .pushpull: return "Push/Pull \(mm("distance"))"
        case .thicken: return "Thicken \(mm("thickness"))"
        case .deleteface: return "Delete \(f.refs.count) face\(f.refs.count == 1 ? "" : "s")"
        case .move:
            let v = { (k: String) in f.values[k] ?? 0 }
            return String(format: "Move %g, %g, %g mm", v("dx"), v("dy"), v("dz"))
                + (["rx", "ry", "rz"].contains { v($0) != 0 } ? String(format: ", turn %g, %g, %g°", v("rx"), v("ry"), v("rz")) : "")
        case .mirror: return (f.values["keep"] ?? 1) != 0 ? "Mirror copy" : "Mirror"
        case .cut: return "Cut by plane"
        default: return f.kind.title
        }
    }

    // MARK: Rebuild

    func rebuild() {
        guard on, let step, let runner else { return }
        var features = file.features
        if let draft, ready(draft) {
            if let i = features.firstIndex(where: { $0.id == draft.id }) { features[i] = draft } else { features.append(draft) }
        }
        var params: [String: JSONValue] = ["path": .string(step.path)]
        if let part = file.part { params["part"] = .string(part) }
        if let fp = file.fingerprint { params["fingerprint"] = .string(fp) }
        do {
            params["features"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(features))
        } catch {
            showError?("Could not send the edits to the engine", error)
            return
        }
        busy = true
        generation += 1
        let mine = generation
        Task { @MainActor in
            guard let result = await runner.submit(.object(params)) else { return }  // a newer edit replaced it
            guard mine == generation, on else { return }  // superseded, or edit mode was left
            busy = false
            switch result {
            case .success(let r): await show(r, generation: mine)
            case .failure(let e): status = e.localizedDescription
            }
        }
    }

    private func show(_ r: PartEditReply, generation mine: Int) async {
        reply = r
        if r.parts.count > 1 && file.part == nil {
            status = "This file has several parts: pick one to edit"
            return
        }
        if file.fingerprint != nil && file.fingerprint != r.fingerprint {
            // The STEP was exported again: its old picks may now point at other faces. Mark them
            // stale (the engine reports them lost) and take the new fingerprint, so new picks work.
            file.features = file.features.map { f in
                var f = f
                f.refs = f.refs.map { ref in
                    var ref = ref
                    if ref.src == "part" { ref.src = "stale" }
                    if ref.tangent?.src == "part" { ref.tangent?.src = "stale" }
                    return ref
                }
                return f
            }
            file.fingerprint = r.fingerprint
            save()
            status = "The STEP changed since these edits: edit the features marked lost and pick again"
            rebuild()
            return
        }
        if file.fingerprint == nil {
            file.fingerprint = r.fingerprint
            save()
        }
        status = r.features.first { $0.status != "ok" }.map { "\($0.id): \($0.message ?? $0.status)" }
        do {
            let url = URL(fileURLWithPath: r.glb)
            let model = try await Task.detached(priority: .userInitiated) { try ModelLoader.load(url, units: .metre) }.value
            guard mine == generation, on else { return }  // a newer rebuild finished loading first
            shown = model
            showModel?(model)
        } catch {
            status = "Could not show the rebuilt part: \(error.localizedDescription)"
        }
        drawOverlay()
    }

    // MARK: Picking

    @ObservationIgnored private var projected: (key: String, lines: [[SIMD3<Double>]])?

    private func edgeIndex(at pointer: EditPointer) -> Int? {
        guard let reply, let viewer else { return nil }
        // Every edge projected once per camera position, not on every mouse move.
        let key = "\(reply.glb)#\(viewer.cameraRevision)#\(viewer.view.bounds.size)"  // a resize moves every point too
        let lines: [[SIMD3<Double>]]
        if let p = projected, p.key == key {
            lines = p.lines
        } else {
            lines = reply.edges.map { $0.points.compactMap { p in p.count == 3 ? viewer.projectWithDepth(SIMD3(p[0], p[1], p[2])) : nil } }
            projected = (key, lines)
        }
        return EdgePick.nearest(lines, to: pointer.screen, within: 9,
                                surfaceDepth: pointer.hit.map { viewer.projectWithDepth($0.point).z })
    }

    private func pointRef(at screen: SIMD2<Double>) -> EditRef? {
        guard let reply, let viewer else { return nil }
        let near = reply.points.min { a, b in
            simd_length(viewer.projectToScreen(Self.v(a.position)) - screen) < simd_length(viewer.projectToScreen(Self.v(b.position)) - screen)
        }
        guard let p = near, simd_length(viewer.projectToScreen(Self.v(p.position)) - screen) <= 8 else { return nil }
        return EditRef(src: p.id, kind: "point")
    }

    private func faceRef(_ pointer: EditPointer) -> EditRef? {
        pointer.hit?.faceIndex.flatMap { reply?.face(atTriangle: $0)?.ref }
    }

    /// What the active tool picks, so only that lights up under the pointer.
    private var wantsEdges: Bool { [.point, .extrude, .fill, .fillet, .chamfer].contains(draft?.kind) }
    private var wantsFaces: Bool {
        guard let d = draft else { return false }
        return [.point, .add, .pushpull, .deleteface, .thicken].contains(d.kind)
            || ([.plane, .mirror, .cut].contains(d.kind) && d.refs.isEmpty)
    }

    func hover(_ pointer: EditPointer) {
        let e = wantsEdges ? edgeIndex(at: pointer) : nil
        let f = e == nil && wantsFaces ? pointer.hit?.faceIndex.flatMap { t in reply?.faces.firstIndex { t >= $0.start && t < $0.start + $0.count } } : nil
        if e != hoveredEdge || f != hoveredFace {
            hoveredEdge = e
            hoveredFace = f
            drawOverlay()
        }
    }

    func pick(_ pointer: EditPointer) {
        guard var d = draft else { return }
        hint = nil
        let edge = edgeIndex(at: pointer).flatMap { reply?.edges[$0].ref }
        let before = d.refs
        defer {
            if draft?.refs == before, hint == nil { hint = Self.missHint(d.kind, edge: edge, face: faceRef(pointer)) }
        }
        switch d.kind {
        case .point:
            guard let host = edge ?? faceRef(pointer), let hit = pointer.hit?.point else { return }
            d.refs = [host]
            d.values = ["x": hit.x * 1000, "y": hit.y * 1000, "z": hit.z * 1000]
        case .spline:
            if let p = pointRef(at: pointer.screen) { d.refs.append(p) }
        case .plane:
            if d.refs.isEmpty, let f = faceRef(pointer) { d.refs = [f] } else if let p = pointRef(at: pointer.screen) {
                d.refs = Array(d.refs.prefix(1)) + [p]
            }
        case .extrude:
            if let e = edge { d.refs = [e] + d.refs.filter { $0.kind == "plane" } }
        case .fill:
            guard var e = edge else { return }
            // A part edge stays tangent to the face the pointer is over; click it from the other side to flip.
            if e.src == "part", let f = faceRef(pointer), f.kind == "face" { e.tangent = f }
            if let i = d.refs.firstIndex(where: { $0.src == e.src && $0.kind == e.kind && $0.i == e.i }) { d.refs[i] = e } else { d.refs.append(e) }
        case .add:
            if let f = faceRef(pointer), f.kind == "surface", !d.refs.contains(f) { d.refs.append(f) }
        case .fillet, .chamfer:
            if let e = edge, e.kind == "edge" {
                if let i = d.refs.firstIndex(of: e) { d.refs.remove(at: i) } else { d.refs.append(e) }
            }
        case .pushpull:
            if let f = faceRef(pointer), f.kind == "face" { d.refs = [f] }
        case .deleteface:
            if let f = faceRef(pointer), f.kind == "face" {
                if let i = d.refs.firstIndex(of: f) { d.refs.remove(at: i) } else { d.refs.append(f) }
            }
        case .thicken:
            if let f = faceRef(pointer), f.kind == "surface" {
                if let i = d.refs.firstIndex(of: f) { d.refs.remove(at: i) } else { d.refs.append(f) }
            }
        case .mirror, .cut:
            if let f = faceRef(pointer), f.kind == "face" { d.refs = [f] }
        case .move:
            return
        }
        draft = d
        drawOverlay()
    }

    /// Why a click picked nothing, for the tool's panel.
    private static func missHint(_ kind: EditFeature.Kind, edge: EditRef?, face: EditRef?) -> String {
        let nearEdge = "Click closer to an edge: it lights up when it can be picked."
        switch kind {
        case .point: return "Click on the part: an edge or a face."
        case .spline: return "Click the amber points, in order. Make points with the Point tool first."
        case .plane: return "Click a flat face first, or pick XY, YZ or ZX; then an amber point."
        case .extrude: return "Click a spline or an edge. " + nearEdge
        case .fill: return nearEdge
        case .add: return face?.kind == "face" ? "Add takes surfaces made by Fill or Extrude, not the part's own faces."
            : "Click the surfaces made by Fill or Extrude."
        case .fillet, .chamfer: return edge != nil ? "That is a spline, not an edge of the part." : nearEdge
        case .pushpull: return face == nil ? "Click a flat face of the part." : "Push/Pull needs a face of the part, not a surface."
        case .deleteface: return face == nil ? "Click the faces to remove: a hole's wall, a fillet, a boss's faces." : "Delete face works on the part's own faces."
        case .thicken: return "Click the surfaces made by Fill or Extrude."
        case .mirror, .cut: return "Pick XY, YZ, ZX or a plane feature, or click a flat face of the part."
        case .move: return "Move takes no picks: type the shift and turn."
        }
    }

    /// Drops the active tool's picks, keeping its values.
    func clearPicks() {
        draft?.refs = []
        hint = nil
        drawOverlay()
    }

    /// The plane of an extrude or a plane feature: a standard one or a plane feature.
    func usePlane(_ ref: EditRef) {
        guard var d = draft else { return }
        if d.kind == .plane { d.refs = [ref] + d.refs.dropFirst().filter { $0.kind == "point" } }
        if d.kind == .extrude { d.refs = d.refs.filter { $0.kind != "plane" } + [ref] }
        if d.kind == .mirror || d.kind == .cut { d.refs = [ref] }
        draft = d
    }

    private func drawOverlay() {
        guard let reply, let viewer else { return }
        let picked = Set(draft?.refs.map { EditRef(src: $0.src, kind: $0.kind, i: $0.i) } ?? [])
        let selected = Set(reply.edges.indices.filter { k in reply.edges[k].ref.map { picked.contains($0) } ?? false })
        let pickedFaces = reply.faces.indices.filter { k in reply.faces[k].ref.map { picked.contains(EditRef(src: $0.src, kind: $0.kind, i: $0.i)) } ?? false }
        viewer.setEditOverlay(edges: reply.edges.map { $0.points.compactMap { p in p.count == 3 ? SIMD3(p[0], p[1], p[2]) : nil } },
                              highlighted: hoveredEdge.map { [$0] } ?? [], selected: selected,
                              points: reply.points.map { Self.v($0.position) },
                              hoverFaces: hoveredFace.map { faceCorners([$0]) } ?? [], selectedFaces: faceCorners(pickedFaces))
    }

    /// The triangles of the reply's faces on the shown part, world space.
    private func faceCorners(_ faces: [Int]) -> [SIMD3<Double>] {
        guard let reply, let shown, let inst = shown.instances().first, let m = inst.node.mesh else { return [] }
        let mesh = shown.meshes[m]
        var out: [SIMD3<Double>] = []
        for k in faces where reply.faces.indices.contains(k) {
            let f = reply.faces[k]
            for t in f.start..<(f.start + f.count) {
                guard let tri = mesh.triangle(t) else { break }
                for v in [tri.0, tri.1, tri.2] {
                    let w = inst.world * SIMD4<Float>(v, 1)
                    out.append(SIMD3(Double(w.x), Double(w.y), Double(w.z)))
                }
            }
        }
        return out
    }

    private static func v(_ p: [Double]) -> SIMD3<Double> { p.count == 3 ? SIMD3(p[0], p[1], p[2]) : .zero }
}

extension EditFeature.Kind {
    var title: String {
        switch self {
        case .point: "Point"
        case .spline: "Spline"
        case .plane: "Plane"
        case .extrude: "Extrude"
        case .fill: "Fill"
        case .add: "Add"
        case .fillet: "Fillet"
        case .chamfer: "Chamfer"
        case .pushpull: "Push/Pull"
        case .deleteface: "Delete face"
        case .move: "Move"
        case .mirror: "Mirror"
        case .cut: "Cut"
        case .thicken: "Thicken"
        }
    }
}
