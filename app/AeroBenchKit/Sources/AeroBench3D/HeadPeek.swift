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

        public init(enabled: Bool, distanceCM: Double, hfovDegrees: Double) {
            self.enabled = enabled
            self.distanceCM = distanceCM
            self.hfovDegrees = hfovDegrees
        }
    }

    public var config: Config {
        didSet {
            if !config.enabled { release(at: CACurrentMediaTime()) }
            stopCameraIfIdle()
        }
    }

    public let tracker = HeadTracker()
    /// The view on the built-in display; nil when it is elsewhere (no peeking).
    var layout: HeadGeometry.Layout?
    private(set) var state = PeekState()
    private var calibration: [Double]?

    public init(config: Config) {
        self.config = config
        tracker.onSample = { [weak self] sample in self?.receive(sample) }
    }

    var blend: Double { state.blend }
    var headCM: SIMD3<Double>? { state.headCM }
    /// Straight in front of the view's centre, at the calibrated distance.
    var restCM: SIMD3<Double> { SIMD3(0, 0, config.distanceCM) }

    private var available: Bool {
        guard config.enabled, layout != nil else { return false }
        switch tracker.status {
        case .off, .starting, .running: return true
        case .needsPermission, .denied, .noCamera: return false
        }
    }

    func press(at t: TimeInterval) {
        state.press(at: t, trackerAvailable: available)
        if state.wantsCamera { tracker.start() }
    }

    func release(at t: TimeInterval) {
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

    /// Collects about a second of eye separations at `distanceCM` and returns
    /// the webcam's horizontal field of view in degrees; nil if no face was seen.
    public func calibrate(distanceCM: Double) async -> Double? {
        tracker.start()
        for _ in 0..<40 where tracker.status == .starting {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard tracker.status == .running else { return nil }
        calibration = []
        try? await Task.sleep(for: .seconds(1))
        let separations = calibration ?? []
        calibration = nil
        stopCameraIfIdle()
        return HeadGeometry.calibratedHFOV(separations: separations, distanceCM: distanceCM).map { $0 * 180 / .pi }
    }

    private func stopCameraIfIdle() {
        if !state.wantsCamera, calibration == nil { tracker.stop() }
    }

    private func receive(_ sample: HeadGeometry.Sample?) {
        if let sample { calibration?.append(sample.separation) }
        guard let layout else { return }
        let head = sample.map {
            HeadGeometry.head($0, hfov: config.hfovDegrees * .pi / 180, imageAspect: tracker.imageAspect,
                              distanceCM: config.distanceCM, layout: layout, mirrored: tracker.mirrored)
        }
        state.face(head, at: sample?.time ?? CACurrentMediaTime(), rest: restCM)
    }
}
