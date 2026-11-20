import Foundation
import simd

/// A rectangle perpendicular to the camera's forward direction: the virtual
/// window the screen shows during a head-tracked peek.
public struct PeekWindow: Equatable, Sendable {
    public var center: SIMD3<Double>  // world
    public var halfWidth: Double  // world, along OrbitCamera.right
    public var halfHeight: Double  // world, along OrbitCamera.up

    /// The eye part way (t, 0...1) from `rest` to `head`. Sideways linearly; in
    /// depth through 1/z, which is how strong the perspective looks, so an ease
    /// from a far eye (orthographic) does not arrive all at the end.
    public static func blendEye(rest: SIMD3<Double>, head: SIMD3<Double>, t: Double) -> SIMD3<Double> {
        let xy = simd_mix(SIMD2(rest.x, rest.y), SIMD2(head.x, head.y), SIMD2(repeating: t))
        let inverseZ = (1 - t) / rest.z + t / head.z
        return SIMD3(xy.x, xy.y, t >= 1 ? head.z : t <= 0 ? rest.z : 1 / inverseZ)
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
    /// Depth of the window plane: the front of a bounding sphere, clamped to
    /// [minDepth, distance], so the model sits behind the glass.
    public func peekDepth(boundsCenter: SIMD3<Double>, boundsRadius: Double, minDepth: Double) -> Double {
        let front = simd_dot(boundsCenter - position, forward) - boundsRadius
        return min(max(front, minDepth), max(distance, minDepth))
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
    /// orientation. The projection is OpenGL's (column-major, clip depth -1...1).
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
