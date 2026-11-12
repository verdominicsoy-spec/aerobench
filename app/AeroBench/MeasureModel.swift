import AeroBench3D
import AeroBenchKit
import Foundation
import Observation
import simd

enum MeasureMode: String, CaseIterable, Identifiable {
    case distance = "Distance", angle = "Angle", radius = "Radius", toFace = "To face"

    var id: String { rawValue }

    var prompt: [String] {
        switch self {
        case .distance: ["Click the first point", "Click the second point"]
        case .angle: ["Click a point on the first line", "Click the corner", "Click a point on the second line"]
        case .radius: ["Click a round edge"]
        case .toFace: ["Click the point", "Click the face to measure to"]
        }
    }
}

/// One finished measurement: what it draws and what its label says.
struct Measurement: Identifiable {
    let id: Int
    let mode: MeasureMode
    let points: [SIMD3<Double>]
    let lines: [[SIMD3<Double>]]
    let anchor: SIMD3<Double>  // where the label sits
    let title: String
    let detail: String?
}

/// The CAD Viewer's measure tool: snaps to the edges, corners, midpoints and
/// hole centres of the part under the pointer, keeps every measurement until
/// it is deleted, and draws them over the model.
@MainActor @Observable
final class MeasureModel {
    var on = false {
        didSet {
            pending = []
            hover = nil
            message = nil
            redraw()
        }
    }
    var mode: MeasureMode = .distance {
        didSet {
            pending = []
            message = nil
            redraw()
        }
    }
    var snap = true
    private(set) var items: [Measurement] = []
    var selected: Int?
    private(set) var pending: [SIMD3<Double>] = []
    private(set) var hover: MeasureSnap?
    private(set) var message: String?
    /// Bumped on every camera move, so the labels follow.
    private(set) var cameraTick = 0

    @ObservationIgnored private let viewer: SceneKitViewer
    @ObservationIgnored private var model: Model3D?
    @ObservationIgnored private var worlds: [Int: simd_float4x4] = [:]  // node id: world transform
    @ObservationIgnored private var edges: [Int: FeatureEdges] = [:]  // mesh index: its feature edges, filled in the background
    @ObservationIgnored private var nodeEdges: [Int: (chains: [[SIMD3<Double>]], circles: [FeatureEdges.Circle?])] = [:]
    @ObservationIgnored private var projected: (key: String, node: Int, lines: [[SIMD3<Double>]])?
    @ObservationIgnored private var lastNode: Int?
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var generation = 0

    init(viewer: SceneKitViewer) {
        self.viewer = viewer
        viewer.onHover = { [weak self] p in self?.pointerMoved(p) }
        viewer.onClickPointer = { [weak self] p in self?.clicked(p) }
        viewer.onCameraChange = { [weak self] in
            guard let self, !self.items.isEmpty || !self.pending.isEmpty else { return }
            self.cameraTick &+= 1
        }
    }

    /// A new model: measurements of the last one do not apply.
    func setModel(_ model: Model3D?, keepMeasurements: Bool = false) {
        self.model = model
        worlds = Dictionary(model?.instances().map { ($0.node.id, $0.world) } ?? [], uniquingKeysWith: { a, _ in a })
        edges = [:]
        nodeEdges = [:]
        projected = nil
        lastNode = nil
        pending = []
        hover = nil
        if !keepMeasurements { items = [] }
        generation += 1
        let mine = generation
        if let model {
            Task {
                let found = await Task.detached(priority: .utility) {
                    Dictionary(uniqueKeysWithValues: model.meshes.indices.map { ($0, FeatureEdges(mesh: model.meshes[$0])) })
                }.value
                guard mine == self.generation else { return }
                self.edges = found
            }
        }
        redraw()
    }

    func remove(_ id: Int) {
        items.removeAll { $0.id == id }
        if selected == id { selected = nil }
        redraw()
    }

    func removeAll() {
        items = []
        selected = nil
        pending = []
        redraw()
    }

    func cancelPending() {
        pending = []
        message = nil
        redraw()
    }

    var prompt: String {
        message ?? mode.prompt[min(pending.count, mode.prompt.count - 1)]
    }

    // MARK: Pointer

    private func pointerMoved(_ p: EditPointer) {
        guard on else { return }
        let s = snap(at: p)
        if s != hover {
            hover = s
            redraw()
        }
    }

    private func clicked(_ p: EditPointer) {
        guard on else { return }
        message = nil
        switch mode {
        case .radius:
            guard let c = circle(at: p) else {
                message = "That is not a round edge: click on the edge of a hole, boss or fillet"
                return
            }
            add(radius: c)
        case .toFace where pending.count == 1:
            guard let hit = p.hit, let n = faceNormal(hit) else {
                message = "Click on a face of the model"
                return
            }
            let (d, foot) = Measure.toPlane(pending[0], point: hit.point, normal: n)
            add(.toFace, points: [pending[0], foot], lines: [[pending[0], foot]], anchor: 0.5 * (pending[0] + foot),
                title: "\(mm(d)) mm to face", detail: nil)
        default:
            guard let s = snap(at: p) else { return }
            pending.append(s.point)
            if mode == .distance, pending.count == 2 {
                let a = pending[0], b = pending[1], d = (b - a) * 1000
                add(.distance, points: [a, b], lines: [[a, b]], anchor: 0.5 * (a + b),
                    title: "\(mm(simd_distance(a, b))) mm",
                    detail: "Δx \(Self.f2(d.x))  Δy \(Self.f2(d.y))  Δz \(Self.f2(d.z))")
            } else if mode == .angle, pending.count == 3 {
                let a = pending[0], v = pending[1], b = pending[2]
                add(.angle, points: [a, v, b], lines: [[a, v, b]], anchor: v,
                    title: String(format: "%.2f°", Measure.angle(a, v, b)), detail: nil)
            }
        }
        redraw()
    }

    private func add(radius c: FeatureEdges.Circle) {
        let u = simd_normalize(simd_cross(abs(c.normal.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0), c.normal))
        let v = simd_cross(c.normal, u)
        let ring = (0...64).map { i -> SIMD3<Double> in
            let a = Double(i) / 64 * 2 * .pi
            return c.centre + c.radius * (cos(a) * u + sin(a) * v)
        }
        add(.radius, points: [c.centre], lines: [ring, [c.centre, ring[0]]], anchor: ring[0],
            title: "R \(mm(c.radius)) mm", detail: "Ø \(mm(2 * c.radius)) mm")
    }

    private func add(_ mode: MeasureMode, points: [SIMD3<Double>], lines: [[SIMD3<Double>]], anchor: SIMD3<Double>,
                     title: String, detail: String?) {
        items.append(Measurement(id: nextID, mode: mode, points: points, lines: lines, anchor: anchor, title: title, detail: detail))
        selected = nextID
        nextID += 1
        pending = []
    }

    // MARK: Snapping

    /// The edges of the part under the pointer (or the last one, over a hole), in world space.
    private func partEdges(_ p: EditPointer) -> (node: Int, chains: [[SIMD3<Double>]], circles: [FeatureEdges.Circle?])? {
        if let id = p.hit?.nodeID { lastNode = id }
        guard let id = p.hit?.nodeID ?? lastNode, let world = worlds[id],
              let mesh = model?.node(id: id)?.mesh, let fe = edges[mesh] else { return nil }
        if let e = nodeEdges[id] { return (id, e.chains, e.circles) }
        let chains = fe.chains.map { $0.map { q -> SIMD3<Double> in
            let w = world * SIMD4<Float>(SIMD3<Float>(q), 1)
            return SIMD3(Double(w.x), Double(w.y), Double(w.z))
        } }
        let circles = fe.circles.map { $0?.transformed(world) }
        nodeEdges[id] = (chains, circles)
        return (id, chains, circles)
    }

    private func screenLines(node: Int, _ chains: [[SIMD3<Double>]]) -> [[SIMD3<Double>]] {
        let key = "\(viewer.cameraRevision)#\(viewer.view.bounds.size)"
        if let p = projected, p.key == key, p.node == node { return p.lines }
        let lines = chains.map { $0.map(viewer.projectWithDepth) }
        projected = (key, node, lines)
        return lines
    }

    private func snap(at p: EditPointer) -> MeasureSnap? {
        let surface = p.hit?.point
        guard snap, let e = partEdges(p) else { return surface.map { MeasureSnap(kind: .surface, point: $0) } }
        return MeasureSnap.choose(cursor: p.screen, surface: surface, surfaceDepth: surface.map { viewer.projectWithDepth($0).z },
                                  chains: e.chains, circles: e.circles, project: viewer.projectWithDepth,
                                  screen: screenLines(node: e.node, e.chains))
    }

    /// The round edge nearest the pointer, within 10 points.
    private func circle(at p: EditPointer) -> FeatureEdges.Circle? {
        guard let e = partEdges(p) else { return nil }
        let screen = screenLines(node: e.node, e.chains)
        let round = e.circles.indices.filter { e.circles[$0] != nil }
        let surfaceDepth = p.hit.map { viewer.projectWithDepth($0.point).z }
        guard let k = EdgePick.nearest(round.map { screen[$0] }, to: p.screen, within: 10, surfaceDepth: surfaceDepth) else { return nil }
        return e.circles[round[k]]
    }

    private func faceNormal(_ hit: PickResult) -> SIMD3<Double>? {
        guard let id = hit.nodeID, let world = worlds[id], let m = model?.node(id: id)?.mesh,
              let tri = hit.faceIndex.flatMap({ model?.meshes[m].triangle($0) }) else { return nil }
        let w = [tri.0, tri.1, tri.2].map { v -> SIMD3<Double> in
            let c = world * SIMD4<Float>(v, 1)
            return SIMD3(Double(c.x), Double(c.y), Double(c.z))
        }
        let n = simd_cross(w[1] - w[0], w[2] - w[0])
        return simd_length(n) > 0 ? n : nil
    }

    // MARK: Drawing

    private func redraw() {
        var lines = items.flatMap(\.lines)
        var points = items.flatMap(\.points)
        if on {
            var run = pending
            if let h = hover, !run.isEmpty, mode != .toFace { run.append(h.point) }
            if run.count > 1 { lines.append(run) }
            points += pending
        }
        viewer.setMeasureOverlay(lines: lines, points: points, hover: on ? hover?.point : nil)
    }

    func project(_ p: SIMD3<Double>) -> SIMD3<Double> { viewer.projectWithDepth(p) }

    private func mm(_ metres: Double) -> String { Self.f2(metres * 1000) }
    static func f2(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(2))) }
}
