import Foundation
import QuartzCore
import simd

/// Hold Shift to peek: ties the webcam (HeadTracker), the head maths
/// (HeadGeometry) and the peek's timing (PeekState) together. The viewer
/// sets `layout` and calls press, release and tick; it reads blend and headCM.
@MainActor
public final class HeadPeek {
    public struct Config: Equatable, Sendable {
        public var enabled: Bool
        public var distanceCM: Double
        public var hfovDegrees: Double

        /// distanceCM is the seat assumed until the eye gap gives a distance; hfovDegrees
        /// is the MacBook webcam's, as macOS does not report it.
        public init(enabled: Bool = true, distanceCM: Double = 55, hfovDegrees: Double = 62) {
            self.enabled = enabled
            self.distanceCM = distanceCM
            self.hfovDegrees = hfovDegrees
        }
    }

    public var config: Config {
        didSet {
            if !config.enabled {
                // Off means the camera goes now, not when the 30 s grace runs out.
                state = PeekState()
                tracker.stop()
            }
            stopCameraIfIdle()
        }
    }

    public let tracker = HeadTracker()
    /// The view on the built-in display; nil when it is elsewhere (no peeking).
    var layout: HeadGeometry.Layout?
    private(set) var state = PeekState()
    private var shiftDown = false

    public init(config: Config) {
        self.config = config
        tracker.onSample = { [weak self] sample in self?.receive(sample) }
    }

    var blend: Double { state.blend }
    var offsetCM: SIMD3<Double>? { state.offsetCM }
    /// Your distance when Shift went down: the eye's scale for this peek.
    var pressDistanceCM: Double { state.neutralCM?.z ?? config.distanceCM }
    /// Straight in front of the view's centre.
    var restCM: SIMD3<Double> { SIMD3(0, 0, config.distanceCM) }

    private var available: Bool {
        guard config.enabled, layout != nil else { return false }
        switch tracker.status {
        case .off, .starting, .running, .noCamera: return true  // no camera: try again, it may be back
        case .needsPermission, .denied: return false
        }
    }

    func press(at t: TimeInterval) {
        shiftDown = true
        if config.enabled, layout != nil, tracker.status == .needsPermission {
            // The first Shift asks for the camera; carry on if it is still held.
            Task {
                guard await tracker.requestAccess(), shiftDown else { return }
                press(at: CACurrentMediaTime())
            }
            return
        }
        state.press(at: t, trackerAvailable: available)
        if state.wantsCamera { tracker.start() }
    }

    func release(at t: TimeInterval) {
        shiftDown = false
        let wasWanted = state.wantsCamera
        state.release(at: t)
        // Let the camera go once nobody has peeked for a while.
        if wasWanted {
            DispatchQueue.main.asyncAfter(deadline: .now() + state.stopAfter + 0.1) { [weak self] in
                guard let self else { return }
                self.state.tick(at: CACurrentMediaTime())
                self.stopCameraIfIdle()
            }
        }
    }

    func tick(at t: TimeInterval) {
        state.tick(at: t)
    }

    private func stopCameraIfIdle() {
        if !state.wantsCamera {
            tracker.stop()
            state.cameraStopped()
        }
    }

    private func receive(_ sample: HeadGeometry.Sample?) {
        guard let layout else { return }
        let time = sample?.time ?? CACurrentMediaTime(), hfov = config.hfovDegrees * .pi / 180
        state.measure(distance: sample.map { HeadGeometry.distance($0, hfov: hfov) }, at: time)
        let placed = state.placementDistanceCM ?? config.distanceCM, depth = state.distanceCM ?? config.distanceCM
        let head = sample.map { s -> SIMD3<Double> in
            var h = HeadGeometry.head(s, hfov: hfov, imageAspect: tracker.imageAspect,
                                      distanceCM: placed, layout: layout, mirrored: tracker.mirrored)
            h.z = depth  // the eye's depth keeps the slow, steady distance
            return h
        }
        state.face(head, at: time, rest: state.neutralCM ?? restCM)
    }
}
