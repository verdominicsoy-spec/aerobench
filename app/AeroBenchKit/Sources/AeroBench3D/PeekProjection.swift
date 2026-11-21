import Foundation
import simd

/// A rectangle perpendicular to the camera's forward direction: the virtual
/// window the screen shows during a head-tracked peek.
public struct PeekWindow: Equatable, Sendable {
    public var center: SIMD3<Double>  // world
    public var halfWidth: Double  // world, along OrbitCamera.right
    public var halfHeight: Double  // world, along OrbitCamera.up

    /// The eye for a head that has moved `offsetCM` since Shift went down (at
    /// `distanceCM`), `blend` of the way in. One to one, scaled so the rest eye
    /// stands for where you sat: sideways through the head's own angle, and
    /// leaning in to half the distance halves the eye's. Pressing Shift changes
    /// nothing until the head moves. Not the physical scale, which would narrow
    /// the view's 35° to the pane's 15° or so and flatten it.
    public static func eye(rest: SIMD3<Double>, offsetCM: SIMD3<Double>, distanceCM: Double, blend: Double) -> SIMD3<Double> {
        rest + offsetCM * (rest.z / max(distanceCM, 1e-6)) * blend
    }

    public init(center: SIMD3<Double>, halfWidth: Double, halfHeight: Double) {
        self.center = center
        self.halfWidth = halfWidth
        self.halfHeight = halfHeight
    }
}

/// Head-tracked peek: the screen is a window, the eye moves with the head, and
/// the frustum runs from the eye through the window's four edges (Kooima,
/// "Generalized Perspective Projection"), so the window stays pinned to the
/// view's edges while things behind and in front of it shift.
extension OrbitCamera {
    /// How far along forward the glass sits: where the model's bounding sphere begins,
    /// so all of it is behind the glass, but no nearer than a quarter of the way to the
    /// target, so zooming right into a part still peeks around it.
    public func peekDepth(center: SIMD3<Double>, radius: Double) -> Double {
        max(simd_dot(center - position, forward) - radius, 0.25 * distance)
    }

    /// The room behind the glass, from the glass back: as wide as the view at the target
    /// (or the glass, if wider), like a room seen through a smaller window, so the model fits in it.
    public func peekRoom(window: PeekWindow, aspect: Double) -> PeekWindow {
        let atTarget = peekWindow(depth: distance, aspect: aspect)
        return PeekWindow(center: window.center, halfWidth: max(window.halfWidth, atTarget.halfWidth),
                          halfHeight: max(window.halfHeight, atTarget.halfHeight))
    }

    /// The window at `depth` along forward, sized to what the un-peeked view shows there.
    public func peekWindow(depth: Double, aspect: Double) -> PeekWindow {
        let halfHeight = orthographic ? orthoHalfHeight : depth * tan(fovY / 2)
        return PeekWindow(center: position + forward * depth, halfWidth: halfHeight * aspect, halfHeight: halfHeight)
    }

    /// The eye that reproduces the un-peeked view: the camera itself in
    /// perspective; in orthographic, an eye far enough back to look parallel
    /// across the model's depth even when zoomed in on a small part of it.
    public func restEye(window: PeekWindow, depth: Double, boundsRadius: Double) -> SIMD3<Double> {
        SIMD3(0, 0, orthographic ? 1000 * max(window.halfHeight, boundsRadius) : depth)
    }

    /// Camera position and off-axis projection for an eye at `eye`, in the
    /// window's frame and world units (x along right, y along up, z toward the
    /// viewer from the window centre). The camera keeps the un-peeked
    /// orientation. The projection is OpenGL's
    /// (column-major, clip depth -1...1).
    public func peekCamera(window: PeekWindow, eye: SIMD3<Double>, near: Double, far: Double)
        -> (position: SIMD3<Double>, projection: simd_double4x4)
    {
        let n = near, f = far, ez = max(eye.z, 1e-9)
        let l = (-window.halfWidth - eye.x) * n / ez, r = (window.halfWidth - eye.x) * n / ez
        let b = (-window.halfHeight - eye.y) * n / ez, t = (window.halfHeight - eye.y) * n / ez
        let projection = simd_double4x4(columns: (
            SIMD4(2 * n / (r - l), 0, 0, 0),
            SIMD4(0, 2 * n / (t - b), 0, 0),
            SIMD4((r + l) / (r - l), (t + b) / (t - b), -(f + n) / (f - n), -1),
            SIMD4(0, 0, -2 * f * n / (f - n), 0)
        ))
        let position = window.center + right * eye.x + up * eye.y - forward * eye.z
        return (position, projection)
    }
}
