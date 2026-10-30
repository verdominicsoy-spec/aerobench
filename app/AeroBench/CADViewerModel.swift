import AeroBench3D
import AeroBenchKit
import CryptoKit
import Foundation
import Observation

enum TessellationPreset: String, CaseIterable, Identifiable {
    case coarse, medium, fine

    var id: String { rawValue }
}

/// State of the CAD Viewer. The 3D view itself lives in `viewer`.
@MainActor @Observable
final class CADViewerModel {
    enum Status {
        case empty
        case loading(String)
        case ready
        case failed(String, String?)
    }

    let viewer: SceneKitViewer
    private(set) var model: Model3D?
    private(set) var fileURL: URL?
    var status: Status = .empty
    private(set) var fromCache = false
    var job: JobItem?

    var preset: TessellationPreset = .medium
    var meshUnits: LengthUnit = .millimetre
    var upAxis: UpAxis = .z { didSet { viewer.upAxis = upAxis } }
    var projection: Projection = .perspective { didSet { viewer.projection = projection } }
    var snap = true { didSet { viewer.snapToVertices = snap } }
    var showStatistics = false { didSet { viewer.showsStatistics = showStatistics } }
    var hidden: Set<Int> = [] {
        didSet {
            viewer.setHidden(hidden)
            visibleBounds = model?.bounds(hidden: hidden)
            cutter = nil
            updateSection()
        }
    }

    // Section cut: the visible parts cut by a plane across one axis
    var sectionOn = false {
        didSet {
            if sectionOn && oldValue == false { centreSection() } else { updateSection() }
        }
    }
    var sectionAxis = 0 { didSet { if sectionAxis != oldValue { centreSection() } } }
    var sectionPosition = 0.0 { didSet { updateSection() } }  // metres along sectionAxis
    private(set) var sectionSegments: [(SIMD2<Double>, SIMD2<Double>)] = []
    @ObservationIgnored private var cutter: SectionCutter?

    var sectionRange: ClosedRange<Double> {
        guard let b = visibleBounds, b.max[sectionAxis] > b.min[sectionAxis] else { return 0...1 }
        return b.min[sectionAxis]...b.max[sectionAxis]
    }

    private func centreSection() {
        let r = sectionRange
        sectionPosition = (r.lowerBound + r.upperBound) / 2
    }

    private func updateSection() {
        guard sectionOn, let model else {
            sectionSegments = []
            viewer.setSlice(nil, center: .zero, right: .zero, up: .zero)
            return
        }
        if cutter == nil { cutter = SectionCutter(model: model, hidden: hidden) }
        sectionSegments = cutter?.cut(axis: sectionAxis, at: sectionPosition) ?? []
        // The plane itself in the 3D view, a little larger than the parts.
        guard let b = visibleBounds else { return }
        let (u, v) = SectionCutter.planeAxes(sectionAxis)
        var center = (b.min + b.max) / 2, right = SIMD3<Double>(repeating: 0), up = SIMD3<Double>(repeating: 0)
        center[sectionAxis] = sectionPosition
        right[u] = max(b.max[u] - b.min[u], 0.01) * 1.1
        up[v] = max(b.max[v] - b.min[v], 0.01) * 1.1
        viewer.setSlice(Self.planeImage, center: center, right: right, up: up)
    }

    /// A translucent blue square for the cut plane.
    private static let planeImage: CGImage? = {
        let rgba: [UInt8] = Array(repeating: [40, 110, 220, 70], count: 4).flatMap { $0 }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()
    private(set) var visibleBounds: (min: SIMD3<Double>, max: SIMD3<Double>)?

    var measuring = false {
        didSet { if !measuring { points = [] } }
    }
    private(set) var points: [SIMD3<Double>] = [] {
        didSet { viewer.setMarkers(points) }
    }

    // Geometry check
    var checkJob: JobItem?
    var repairJob: JobItem?
    private(set) var report: GeometryReport?
    var repairSummary: String?
    var shownIssues: Set<String> = [] {
        didSet { updateIssueMarkers() }
    }

    init() {
        viewer = SceneKitViewer()
        viewer.pointSize = 9
        viewer.onPick = { [weak self] pick in self?.picked(pick) }
    }

    static let tessellatedExtensions: Set<String> = ["step", "stp", "iges", "igs"]
    static let openableExtensions = tessellatedExtensions.union(ModelLoader.directExtensions)

    var isTessellatedFormat: Bool {
        fileURL.map { Self.tessellatedExtensions.contains($0.pathExtension.lowercased()) } ?? false
    }

    var triangleCount: Int { model?.triangleCount ?? 0 }

    func setFile(_ url: URL) {
        fileURL = url
        points = []
    }

    func setModel(_ model: Model3D, fromCache: Bool) {
        self.model = model
        self.fromCache = fromCache
        points = []
        hidden = []
        viewer.show(model)
        visibleBounds = model.bounds()
        status = .ready
        setReport(nil)
        cutter = nil
        if sectionOn { centreSection() }
    }

    func clear() {
        model = nil
        fileURL = nil
        points = []
        hidden = []
        viewer.show(nil)
        status = .empty
        setReport(nil)
        cutter = nil
        sectionOn = false
    }

    func isVisible(_ id: Int) -> Bool { !hidden.contains(id) }

    func setVisible(_ id: Int, _ visible: Bool) {
        if visible { hidden.remove(id) } else { hidden.insert(id) }
    }

    func clearMeasurement() { points = [] }

    private func picked(_ pick: PickResult) {
        guard measuring else { return }
        points = points.count >= 2 ? [pick.point] : points + [pick.point]
    }

    // MARK: Geometry check

    func setReport(_ report: GeometryReport?) {
        self.report = report
        repairSummary = nil
        shownIssues = Set((report?.allIssues ?? []).filter { $0.count > 0 && !$0.points.isEmpty && $0.severity != "info" }.map(\.kind))
    }

    /// Distinct, fixed colours per issue kind so markers can be told apart.
    static func color(for kind: String) -> SIMD4<Float> {
        switch kind {
        case "self_intersections": SIMD4(0.9, 0.1, 0.1, 1)
        case "interference": SIMD4(0.2, 0.5, 1.0, 1)
        case "non_manifold_edges": SIMD4(0.8, 0.0, 0.8, 1)
        case "open_edges", "brep_free_edges": SIMD4(1.0, 0.6, 0.0, 1)
        case "flipped": SIMD4(0.1, 0.75, 0.75, 1)
        case "duplicate_faces": SIMD4(0.6, 0.35, 0.1, 1)
        case "degenerate", "brep_small_edges": SIMD4(0.9, 0.85, 0.1, 1)
        default: SIMD4(1.0, 0.2, 0.5, 1)
        }
    }

    private func updateIssueMarkers() {
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD4<Float>] = []
        for issue in report?.allIssues ?? [] where shownIssues.contains(issue.kind) {
            let c = Self.color(for: issue.kind)
            for p in issue.points where p.count == 3 {
                positions.append(SIMD3(Float(p[0]), Float(p[1]), Float(p[2])))
                colors.append(c)
            }
        }
        viewer.setPoints(positions, colors: colors)
    }

    // MARK: Tessellation cache

    /// Cached .glb for a STEP/IGES file at a preset, keyed on path, size and
    /// modification date so an edited file is re-tessellated.
    static func cacheURL(for file: URL, preset: TessellationPreset) -> URL? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(file.standardizedFileURL.path)|\(size)|\(modified)|\(preset.rawValue)|v1"
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheFolder.appendingPathComponent("\(hash).glb")
    }

    static var cacheFolder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "AeroBench")
            .appendingPathComponent("tessellations")
    }
}
