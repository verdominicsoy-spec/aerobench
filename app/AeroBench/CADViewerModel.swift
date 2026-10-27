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
        }
    }
    private(set) var visibleBounds: (min: SIMD3<Double>, max: SIMD3<Double>)?

    var measuring = false {
        didSet { if !measuring { points = [] } }
    }
    private(set) var points: [SIMD3<Double>] = [] {
        didSet { viewer.setMarkers(points) }
    }

    init() {
        viewer = SceneKitViewer()
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
    }

    func clear() {
        model = nil
        fileURL = nil
        points = []
        hidden = []
        viewer.show(nil)
        status = .empty
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
