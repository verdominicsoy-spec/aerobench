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
        /// Multiplies head movement: 1 turns the view by the head's own angle.
        public var sensitivity: Double

        /// distanceCM cancels out (head movement is used as an angle); hfovDegrees is
        /// the MacBook webcam's, as macOS does not report it, and any error in it
        /// only scales the movement, which sensitivity covers.
        public init(enabled: Bool = true, distanceCM: Double = 55, hfovDegrees: Double = 62, sensitivity: Double = 2) {
            self.enabled = enabled
            self.distanceCM = distanceCM
            self.hfovDegrees = hfovDegrees
            self.sensitivity = sensitivity
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
    var offsetCM: SIMD2<Double>? { state.offsetCM }
    var tiltOffset: Double { state.tiltOffset }
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
        let head = sample.map {
            HeadGeometry.head($0, hfov: config.hfovDegrees * .pi / 180, imageAspect: tracker.imageAspect,
                              distanceCM: config.distanceCM, layout: layout, mirrored: tracker.mirrored)
        }
        let tilt = sample.map { HeadGeometry.tilt($0, mirrored: tracker.mirrored) } ?? 0
        state.face(head, tilt: tilt, at: sample?.time ?? CACurrentMediaTime(), rest: state.neutralCM ?? restCM)
    }
}
