import Foundation
import simd

/// CAD-style camera: orbit about a pivot (turntable, world up stays up),
/// pan in the view plane, zoom toward a point (the one under the cursor).
/// Pure maths, so it can be tested without a window.
public struct OrbitCamera: Equatable, Sendable {
    public var position: SIMD3<Double>
    public var target: SIMD3<Double>
    public var worldUp: SIMD3<Double>
    /// Used for the screen's up direction when looking straight along worldUp.
    public var fallbackUp: SIMD3<Double>
    public var fovY: Double  // radians, vertical
    public var orthographic: Bool
    public var orthoHalfHeight: Double  // world units

    public init(position: SIMD3<Double> = [0, -5, 0], target: SIMD3<Double> = .zero, worldUp: SIMD3<Double> = [0, 0, 1],
                fallbackUp: SIMD3<Double> = [1, 0, 0], fovY: Double = 35 * .pi / 180,
                orthographic: Bool = false, orthoHalfHeight: Double = 1) {
        self.position = position
        self.target = target
        self.worldUp = worldUp
        self.fallbackUp = fallbackUp
        self.fovY = fovY
        self.orthographic = orthographic
        self.orthoHalfHeight = orthoHalfHeight
    }

    public var forward: SIMD3<Double> { simd_normalize(target - position) }
    public var distance: Double { simd_distance(target, position) }

    /// The up vector to hand to look(at:), never parallel to forward.
    public var screenUp: SIMD3<Double> {
        abs(simd_dot(forward, simd_normalize(worldUp))) > 0.9999 ? fallbackUp : worldUp
    }

    public var right: SIMD3<Double> { simd_normalize(simd_cross(forward, screenUp)) }
    public var up: SIMD3<Double> { simd_cross(right, forward) }

    // MARK: Projection

    /// Normalised device coordinates (-1...1, y up) of a world point.
    public func project(_ p: SIMD3<Double>, aspect: Double) -> SIMD2<Double> {
        let d = p - position
        let x = simd_dot(d, right), y = simd_dot(d, up), z = simd_dot(d, forward)
        if orthographic {
            return SIMD2(x / (orthoHalfHeight * aspect), y / orthoHalfHeight)
        }
        let t = tan(fovY / 2)
        return SIMD2(x / (z * t * aspect), y / (z * t))
    }

    /// Where a screen point (NDC) meets the plane through the target facing the camera.
    public func pointOnTargetPlane(ndc: SIMD2<Double>, aspect: Double) -> SIMD3<Double> {
        if orthographic {
            return target + right * ndc.x * orthoHalfHeight * aspect + up * ndc.y * orthoHalfHeight
        }
        let t = tan(fovY / 2)
        let dir = simd_normalize(forward + right * ndc.x * t * aspect + up * ndc.y * t)
        let depth = distance / simd_dot(dir, forward)
        return position + dir * depth
    }

    /// World units per screen point at the target's depth.
    public func worldPerPoint(viewHeight: Double) -> Double {
        let half = orthographic ? orthoHalfHeight : distance * tan(fovY / 2)
        return 2 * half / max(viewHeight, 1)
    }

    // MARK: Moves

    /// Turntable orbit about `pivot` (default the target). dx, dy in points;
    /// dragging right turns the model right, dragging up tips it toward you.
    public mutating func orbit(dx: Double, dy: Double, about pivot: SIMD3<Double>? = nil, radiansPerPoint: Double = 0.008) {
        let p = pivot ?? target
        let yaw = simd_quatd(angle: -dx * radiansPerPoint, axis: simd_normalize(worldUp))
        apply(yaw, about: p)
        let pitch = simd_quatd(angle: dy * radiansPerPoint, axis: right)
        var trial = self
        trial.apply(pitch, about: p)
        let angle = acos(min(max(simd_dot(trial.forward, simd_normalize(worldUp)), -1), 1))
        let wasAtPole = abs(simd_dot(forward, simd_normalize(worldUp))) > 0.9999
        if wasAtPole || (angle > 0.005 && angle < .pi - 0.005) {
            self = trial
        }
    }

    private mutating func apply(_ q: simd_quatd, about p: SIMD3<Double>) {
        position = p + q.act(position - p)
        target = p + q.act(target - p)
        fallbackUp = q.act(fallbackUp)
    }

    /// Moves the view so content follows the cursor: dx right, dy up, in points.
    public mutating func pan(dx: Double, dy: Double, viewHeight: Double) {
        let s = worldPerPoint(viewHeight: viewHeight)
        let delta = -right * dx * s - up * dy * s
        position += delta
        target += delta
    }

    /// Zooms by `factor` (< 1 closer) keeping `point` fixed on screen.
    public mutating func zoom(factor: Double, about point: SIMD3<Double>) {
        let f = min(max(factor, 0.05), 20)
        if orthographic {
            let d = point - position
            let perp = d - forward * simd_dot(d, forward)
            position += perp * (1 - f)
            target += perp * (1 - f)
            orthoHalfHeight = max(orthoHalfHeight * f, 1e-6)
        } else {
            let newPosition = point + (position - point) * f
            let newTarget = point + (target - point) * f
            guard simd_distance(newPosition, newTarget) > 1e-6 else { return }
            position = newPosition
            target = newTarget
        }
    }

    /// Looks at a sphere from `direction` (centre to camera) so it fills the view.
    public mutating func frame(center: SIMD3<Double>, radius: Double, direction: SIMD3<Double>, up: SIMD3<Double>, aspect: Double) {
        let halfV = fovY / 2
        let halfH = atan(tan(halfV) * aspect)
        let r = max(radius, 1e-6)
        let dist = r / sin(min(halfV, halfH)) * 1.05
        target = center
        position = center + simd_normalize(direction) * dist
        let viewUpIsWorldUp = abs(simd_dot(simd_normalize(direction), simd_normalize(worldUp))) < 0.9999
        if !viewUpIsWorldUp { fallbackUp = simd_normalize(up) }
        orthoHalfHeight = r * 1.05 * max(1, 1 / aspect)
    }
}
