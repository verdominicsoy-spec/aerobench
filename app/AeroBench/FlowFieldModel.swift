import AeroBench3D
import AeroBenchKit
import CoreGraphics
import Foundation
import Observation
import simd

/// One isosurface in the Explore view.
struct IsoLevel: Identifiable {
    let id = UUID()
    var level: Double
    var visible = true
    var opacity = 1.0
    var model: Model3D?
    var computing = false
}

/// What a click or drag on the frame does.
enum FrameTool: Equatable {
    case none
    case crop
    case exclude
    case legend
    case point(slot: Int, index: Int)  // spatial calibration frame slot, point 0 or 1
    case maskColor
    case measure  // the quick setup's known width: a horizontal line
}

@MainActor @Observable
final class FlowFieldModel {
    enum Mode: String, CaseIterable, Identifiable {
        case calibrate = "Calibrate"
        case explore = "Explore"

        var id: String { rawValue }
    }

    var mode: Mode = .calibrate
    /// The guided quick setup, or every setting.
    var showAllSettings = false

    // Source and calibration
    private(set) var sourceURL: URL?
    @ObservationIgnored private(set) var grabber: FrameGrabber?
    private(set) var frameCount = 0
    private(set) var frameSize = CGSize.zero
    var frameIndex = 0
    private(set) var frameImage: CGImage?
    var calibration = FlowCalibration() {
        didSet { if calibration != oldValue { onCalibrationChange?() } }
    }
    @ObservationIgnored var onCalibrationChange: (() -> Void)?
    var tool: FrameTool = .none
    var loadError: String?

    // Finding the crop, overlays and legend automatically
    var detectJob: JobItem?
    var detection: FlowDetection?
    var detectNotes: [String] = []

    // Checking one frame
    var previewJob: JobItem?
    var previewImage: CGImage?
    var previewStats: [String: Any] = [:]

    // Reconstruction and exploring
    var reconstructJob: JobItem?
    /// The engine's summary of the last reconstruction (ground fit, implied camera).
    var reconstructStats: [String: Any] = [:]
    private(set) var volume: FlowVolume?
    private(set) var volumeFolder: URL?
    var isoLevels: [IsoLevel] = []
    /// The no-fluid region (geometry), meshed by the engine on request.
    var objectOn = false
    var objectOpacity = 1.0
    var objectIgnoreBelowGround = true
    var objectModel: Model3D?
    var objectComputing = false
    var objectError: String?
    var windowOn = false { didSet { updateWindow() } }
    var windowLo = -1.0
    var windowHi = 0.0
    var sliceIndex = 0 { didSet { updateSlice() } }
    var sliceIn3D = true { didSet { updateSlice() } }
    private(set) var sliceImage: CGImage?
    private(set) var sliceFrameImage: CGImage?

    let viewer: SceneKitViewer

    init() {
        viewer = SceneKitViewer()
    }

    var needsCalibrationFrames: Int { calibration.spatial.frames.count }

    // MARK: Source

    func open(_ url: URL) async {
        loadError = nil
        do {
            let g = try await FrameGrabber(url: url)
            grabber = g
            sourceURL = url
            frameCount = g.frameCount
            frameSize = g.size
            calibration.sourceSize = [Int(g.size.width), Int(g.size.height)]
            if calibration.planes.lastFrame == nil || (calibration.planes.lastFrame ?? 0) >= g.frameCount {
                calibration.planes.lastFrame = g.frameCount - 1
            }
            frameIndex = min(frameIndex, g.frameCount - 1)
            await showFrame(frameIndex)
        } catch {
            loadError = error.localizedDescription
        }
    }

    func showFrame(_ index: Int) async {
        guard let grabber else { return }
        frameIndex = min(max(index, 0), frameCount - 1)
        let wanted = frameIndex
        do {
            let image = try await grabber.image(at: wanted)
            if frameIndex == wanted { frameImage = image }
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Calibration edits from the frame canvas

    func apply(rect: CGRect) {
        let r = [rect.minX, rect.minY, rect.maxX, rect.maxY].map { Double($0.rounded()) }
        switch tool {
        case .crop: calibration.crop = r
        case .exclude: calibration.exclude.append(r)
        default: break
        }
        tool = .none
    }

    func apply(line from: CGPoint, to: CGPoint) {
        switch tool {
        case .legend:
            calibration.colormap = .init(preset: nil, legend: .init(frame: frameIndex, p0: [Double(from.x), Double(from.y)],
                                                                    p1: [Double(to.x), Double(to.y)], halfWidth: 3))
        case .measure:
            // Level, at the height it was started: only the width counts.
            let old = calibration.measure
            calibration.measure = .init(frame: frameIndex, p0: [Double(from.x), Double(from.y)], p1: [Double(to.x), Double(from.y)],
                                        width: old?.width ?? 0, centre: old?.centre ?? 0)
            calibration.applyMeasure()
        default:
            break
        }
        tool = .none
    }

    /// Changes the known width or where its middle is, and the scale with it.
    func setMeasure(width: Double? = nil, centre: Double? = nil) {
        // The width can be typed before the line is drawn.
        var m = calibration.measure ?? .init(frame: frameIndex, p0: [], p1: [], width: 0, centre: 0)
        if let width { m.width = width }
        if let centre { m.centre = centre }
        calibration.measure = m
        calibration.applyMeasure()
    }

    /// Changes the axes; the scale's points depend on which way right is.
    func setAxes(right: String? = nil, up: String? = nil) {
        if let right { calibration.axes.right = right }
        if let up { calibration.axes.up = up }
        calibration.applyMeasure()
    }

    func apply(point p: CGPoint) {
        switch tool {
        case .point(let slot, let index):
            ensureSpatialSlot(slot)
            var frame = calibration.spatial.frames[slot]
            if frame.frame != frameIndex {
                frame.frame = frameIndex  // points belong to the frame they were clicked on
                frame.points = frame.points.map { .init(px: [], world: $0.world) }
            }
            while frame.points.count < 2 { frame.points.append(.init(px: [], world: [0, 0])) }
            frame.points[index].px = [Double(p.x), Double(p.y)]
            calibration.spatial.frames[slot] = frame
        case .maskColor:
            if let rgb = frameImage?.pixelRGB(x: Int(p.x), y: Int(p.y)) {
                calibration.maskColors.append(rgb)
            }
        default:
            break
        }
        tool = .none
    }

    func ensureSpatialSlot(_ slot: Int) {
        calibration.spatial.mode = "points"
        while calibration.spatial.frames.count <= slot {
            calibration.spatial.frames.append(.init(frame: frameIndex, points: [.init(px: [], world: [0, 0]), .init(px: [], world: [0.5, 0])]))
        }
    }

    // MARK: Volume

    func setVolume(_ volume: FlowVolume, folder: URL) {
        self.volume = volume
        volumeFolder = folder
        isoLevels = []
        objectOn = false
        objectModel = nil
        objectError = nil
        windowLo = volume.vmin
        windowHi = (volume.vmin + volume.vmax) / 2
        viewer.show(nil, resetCamera: false)
        viewer.setFrame(volume.bounds)
        viewer.look(from: .iso)
        sliceIndex = volume.planeCount / 2
        updateWindow()
        mode = .explore
    }

    func updateIsosurfaces() {
        guard let volume else { return }
        var meshes: [TriangleMesh] = []
        var children: [ModelNode] = []
        if objectOn, let object = objectModel {
            let grey = SIMD4<Float>(0.72, 0.72, 0.75, Float(objectOpacity))
            for inst in object.instances() {
                var mesh = object.meshes[inst.node.mesh!]
                mesh.colors = Array(repeating: grey, count: mesh.positions.count)
                meshes.append(mesh)
                children.append(ModelNode(name: "Object", transform: inst.world, mesh: meshes.count - 1))
            }
        }
        for iso in isoLevels where iso.visible {
            guard let model = iso.model else { continue }
            let c = volume.color(iso.level)
            let rgba = SIMD4<Float>(c, Float(iso.opacity))
            for inst in model.instances() {
                var mesh = model.meshes[inst.node.mesh!]
                mesh.colors = Array(repeating: rgba, count: mesh.positions.count)
                meshes.append(mesh)
                children.append(ModelNode(name: String(format: "Cp0 = %.3g", iso.level), transform: inst.world, mesh: meshes.count - 1))
            }
        }
        let combined = meshes.isEmpty ? nil : Model3D(meshes: meshes, roots: [ModelNode(name: "Isosurfaces", children: children)], sourceName: "iso")
        viewer.show(combined, resetCamera: false)
    }

    private func updateWindow() {
        guard let volume, windowOn else {
            viewer.setPoints([], colors: [])
            return
        }
        let lo = min(windowLo, windowHi), hi = max(windowLo, windowHi)
        let pts = volume.windowPoints(lo: lo, hi: hi)
        viewer.setPoints(pts.positions, colors: pts.colors)
    }

    func refreshWindow() { updateWindow() }

    private func updateSlice() {
        guard let volume, (0..<volume.planeCount).contains(sliceIndex) else {
            sliceImage = nil
            viewer.setSlice(nil, center: .zero, right: .zero, up: .zero)
            return
        }
        sliceImage = volume.sliceImage(plane: sliceIndex)
        let place = volume.sliceFrame(plane: sliceIndex)
        viewer.setSlice(sliceIn3D ? sliceImage : nil, center: place.center, right: place.right, up: place.up)
        let frame = volume.frames[sliceIndex]
        Task {
            guard let grabber = self.grabber, let image = try? await grabber.image(at: frame) else { return }
            if self.volume?.frames[safe: self.sliceIndex] == frame { self.sliceFrameImage = image }
        }
    }

    func reset() {
        sourceURL = nil
        grabber = nil
        frameImage = nil
        frameCount = 0
        volume = nil
        volumeFolder = nil
        isoLevels = []
        objectOn = false
        objectModel = nil
        previewImage = nil
        previewStats = [:]
        reconstructStats = [:]
        detection = nil
        detectNotes = []
        viewer.show(nil, resetCamera: false)
        viewer.setFrame(nil)
        viewer.setPoints([], colors: [])
        viewer.setSlice(nil, center: .zero, right: .zero, up: .zero)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
