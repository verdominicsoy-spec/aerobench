import Foundation
import simd

/// One Euro filter (Casiez, Roussel and Vogel, CHI 2012): heavy smoothing when
/// the signal is still, little when it moves, so webcam jitter goes without
/// adding lag. Also looks `lead` seconds ahead to cover the camera's latency.
public struct OneEuroFilter: Sendable {
    public var minCutoff: Double
    public var beta: Double
    public var dCutoff: Double
    public var lead: Double
    private var x: Double?
    private var dx = 0.0
    private var t = 0.0

    public init(minCutoff: Double = 1.8, beta: Double = 0.02, dCutoff: Double = 1, lead: Double = 0.04) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
        self.lead = lead
    }

    public mutating func filter(_ value: Double, at time: TimeInterval) -> Double {
        guard let previous = x else {
            reset(to: value, at: time)
            return value
        }
        let dt = max(time - t, 1e-3)
        t = time
        func alpha(_ cutoff: Double) -> Double { 1 / (1 + 1 / (2 * .pi * cutoff * dt)) }
        dx += alpha(dCutoff) * ((value - previous) / dt - dx)
        let next = previous + alpha(minCutoff + beta * abs(dx)) * (value - previous)
        x = next
        return next + dx * lead
    }

    /// Starts again from `value`, still.
    public mutating func reset(to value: Double, at time: TimeInterval) {
        x = value
        dx = 0
        t = time
    }
}

/// The peek over time: how far it is blended in, and where the head is.
/// Pure state; the viewer feeds it key presses, faces and display ticks.
public struct PeekState: Sendable {
    public let fade: Double
    public let faceLostAfter: Double
    public let stopAfter: Double

    /// 0 off ... 1 full peek, eased.
    public var blend: Double { progress * progress * (3 - 2 * progress) }
    /// Filtered head position in cm (view-centred), nil before the first face.
    public private(set) var headCM: SIMD3<Double>?
    /// Where the head was when Shift went down: "straight on" for this peek.
    public private(set) var neutralCM: SIMD3<Double>?
    /// Head movement since Shift was pressed, cm (x right, y up); nil before a face.
    public var offsetCM: SIMD2<Double>? {
        guard let h = headCM, let n = neutralCM else { return nil }
        return SIMD2(h.x - n.x, h.y - n.y)
    }
    /// Head tilt since Shift was pressed, radians, clockwise as you see it; 0 before a face.
    public var tiltOffset: Double {
        guard let t = tilt, let n = neutralTilt else { return 0 }
        return t - n
    }
    /// Shift is down (and the tracker could be used).
    public var isHeld: Bool { held }
    /// Whether the webcam should be running.
    public var wantsCamera: Bool {
        held || (lastRelease.map { now - $0 < stopAfter } ?? false)
    }

    private var progress = 0.0  // linear 0...1; blend eases it
    private var held = false
    private var now = 0.0
    private var lastRelease: TimeInterval?
    private var lastFace: TimeInterval?
    private var lostFrom: SIMD3<Double>?  // where the head was when the face went
    private var filters = [OneEuroFilter(), OneEuroFilter(), OneEuroFilter()]
    private var tilt: Double?  // filtered, radians
    private var neutralTilt: Double?  // the tilt when Shift went down: level for this peek
    private var tiltLostFrom: Double?
    private var tiltFilter = OneEuroFilter()
    /// Smoothed eye distance, cm; nil before a face. Held while the face is lost.
    public private(set) var distanceCM: Double?
    // Slow and without lead: blinks and the pupil/contour switch must not twitch the gain.
    private var distanceFilter = Self.newDistanceFilter()
    private static func newDistanceFilter() -> OneEuroFilter { OneEuroFilter(minCutoff: 0.4, beta: 0.005, lead: 0) }

    /// How much livelier the peek is for how close you are: `reference` ÷ distance,
    /// held to 0.5...2 so a misread face can't fling the view; 1 before a face.
    public func gain(reference: Double) -> Double {
        guard let d = distanceCM else { return 1 }
        return min(max(reference / max(d, 1e-6), 0.5), 2)
    }

    public init(fade: Double = 0.15, faceLostAfter: Double = 0.5, stopAfter: Double = 30) {
        self.fade = fade
        self.faceLostAfter = faceLostAfter
        self.stopAfter = stopAfter
    }

    public mutating func press(at t: TimeInterval, trackerAvailable: Bool) {
        tick(at: t)
        guard trackerAvailable else { return }
        held = true
        lastRelease = nil
        neutralCM = headCM  // nil until the first face: set there
        neutralTilt = tilt
    }

    public mutating func release(at t: TimeInterval) {
        tick(at: t)
        if held { lastRelease = t }
        held = false
    }

    /// A camera frame: the measured head (cm), or nil when no face was found.
    /// `rest` is where the head eases to once the face has been gone a while.
    public mutating func face(_ head: SIMD3<Double>?, tilt measured: Double = 0, distance: Double? = nil,
                              at t: TimeInterval, rest: SIMD3<Double>) {
        // Not the fade's clock: a frame landing between ticks would eat tick time.
        if let head {
            if lostFrom != nil, let shown = headCM {
                // Coming back after a loss: filter on from what is shown, not from the stale value.
                for i in 0..<3 { filters[i].reset(to: shown[i], at: t) }
                if let shownTilt = tilt { tiltFilter.reset(to: shownTilt, at: t) }
                if let shownDistance = distanceCM { distanceFilter.reset(to: shownDistance, at: t) }
            }
            lostFrom = nil
            tiltLostFrom = nil
            lastFace = t
            tilt = tiltFilter.filter(measured, at: t)
            if let distance { distanceCM = distanceFilter.filter(distance, at: t) }
            if held, neutralTilt == nil { neutralTilt = tilt }
            headCM = SIMD3((0..<3).map { filters[$0].filter(head[$0], at: t) })
            if held, neutralCM == nil { neutralCM = headCM }
            return
        }
        guard let seen = lastFace, let shown = headCM, t - seen > faceLostAfter else { return }
        if lostFrom == nil { lostFrom = shown; tiltLostFrom = tilt }
        let p = min(max((t - seen - faceLostAfter) / fade, 0), 1), eased = p * p * (3 - 2 * p)
        headCM = simd_mix(lostFrom!, rest, SIMD3(repeating: eased))
        if let from = tiltLostFrom { tilt = from + ((neutralTilt ?? from) - from) * eased }  // eases to level
    }

    /// The webcam stopped: the last head is stale, so the next peek waits for a fresh face.
    public mutating func cameraStopped() {
        headCM = nil
        neutralCM = nil
        lastFace = nil
        lostFrom = nil
        filters = [OneEuroFilter(), OneEuroFilter(), OneEuroFilter()]
        tilt = nil
        neutralTilt = nil
        tiltLostFrom = nil
        tiltFilter = OneEuroFilter()
        distanceCM = nil
        distanceFilter = Self.newDistanceFilter()
    }

    public mutating func tick(at t: TimeInterval) {
        let dt = max(t - now, 0)
        now = max(now, t)
        // Ease in only once the head is known: easing toward a guess and then
        // snapping to the real head would be a jump.
        let rising = held && headCM != nil
        progress = min(max(progress + (rising ? dt : -dt) / fade, 0), 1)
        // Snap rounding residue, so "off" is exactly 0 and the peek camera is let go.
        if progress < 1e-9 { progress = 0 } else if progress > 1 - 1e-9 { progress = 1 }
    }
}
