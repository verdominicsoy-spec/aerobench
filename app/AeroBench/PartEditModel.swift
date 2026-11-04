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
        didSet { if tool != oldValue { draft = tool.map { EditFeature(id: nextID(), kind: $0) } } }
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
        case .point, .pushpull: f.refs.count == 1
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
        return EdgePick.nearest(lines, to: pointer.screen, within: 6,
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

    func hover(_ pointer: EditPointer) {
        let e = edgeIndex(at: pointer)
        if e != hoveredEdge {
            hoveredEdge = e
            drawOverlay()
        }
    }

    func pick(_ pointer: EditPointer) {
        guard var d = draft else { return }
        let edge = edgeIndex(at: pointer).flatMap { reply?.edges[$0].ref }
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
        }
        draft = d
        drawOverlay()
    }

    /// The plane of an extrude or a plane feature: a standard one or a plane feature.
    func usePlane(_ ref: EditRef) {
        guard var d = draft else { return }
        if d.kind == .plane { d.refs = [ref] + d.refs.dropFirst().filter { $0.kind == "point" } }
        if d.kind == .extrude { d.refs = d.refs.filter { $0.kind != "plane" } + [ref] }
        draft = d
    }

    private func drawOverlay() {
        guard let reply, let viewer else { return }
        let picked = Set(draft?.refs.map { EditRef(src: $0.src, kind: $0.kind, i: $0.i) } ?? [])
        let selected = Set(reply.edges.indices.filter { k in reply.edges[k].ref.map { picked.contains($0) } ?? false })
        viewer.setEditOverlay(edges: reply.edges.map { $0.points.compactMap { p in p.count == 3 ? SIMD3(p[0], p[1], p[2]) : nil } },
                              highlighted: hoveredEdge.map { [$0] } ?? [], selected: selected,
                              points: reply.points.map { Self.v($0.position) })
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
        }
    }
}
