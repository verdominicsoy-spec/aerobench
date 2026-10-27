import AeroBenchKit
import AppKit
import SwiftUI

public enum StandardView: String, CaseIterable, Identifiable, Sendable {
    case front, back, left, right, top, bottom, iso

    public var id: String { rawValue }
    public var title: String { rawValue == "iso" ? "Iso" : rawValue.capitalized }
}

public enum Projection: String, CaseIterable, Identifiable, Sendable {
    case perspective, orthographic

    public var id: String { rawValue }
}

/// Which model axis points up. CAD (CATIA, STEP) is usually z, many mesh
/// tools use y.
public enum UpAxis: String, CaseIterable, Identifiable, Codable, Sendable {
    case z, y

    public var id: String { rawValue }
}

public struct PickResult: Sendable {
    public var point: SIMD3<Double>  // world, metres
    public var nodeID: Int?
    public var snapped: Bool
}

/// The renderer-neutral 3D core: shared by the CAD Viewer and, later, the
/// Flow Field Viewer. SceneKitViewer is the v1 implementation.
@MainActor
public protocol Viewer3D: AnyObject {
    var view: NSView { get }
    var projection: Projection { get set }
    var upAxis: UpAxis { get set }
    var snapToVertices: Bool { get set }
    var showsStatistics: Bool { get set }
    var onPick: ((PickResult) -> Void)? { get set }

    /// Replaces the model. With resetCamera false the view stays where it is.
    func show(_ model: Model3D?, resetCamera: Bool)
    func setHidden(_ ids: Set<Int>)
    func look(from view: StandardView)
    func fitAll()
    func setMarkers(_ points: [SIMD3<Double>])

    /// Frames the camera on these bounds (metres) instead of the model's,
    /// and draws them as a box labelled in mm. nil goes back to the model.
    func setFrame(_ bounds: (min: SIMD3<Double>, max: SIMD3<Double>)?)
    /// Coloured points, for showing voxels. Empty clears them.
    func setPoints(_ positions: [SIMD3<Float>], colors: [SIMD4<Float>])
    /// An image on a plane: centred at `center`, its full width along
    /// `right` and full height along `up` (world vectors, metres). nil clears it.
    func setSlice(_ image: CGImage?, center: SIMD3<Double>, right: SIMD3<Double>, up: SIMD3<Double>)
}

extension Viewer3D {
    public func show(_ model: Model3D?) {
        show(model, resetCamera: true)
    }
}

/// Hosts any Viewer3D in SwiftUI.
public struct Viewer3DView: NSViewRepresentable {
    public let viewer: any Viewer3D

    public init(viewer: any Viewer3D) {
        self.viewer = viewer
    }

    public func makeNSView(context: Context) -> NSView { viewer.view }
    public func updateNSView(_ nsView: NSView, context: Context) {}
}
