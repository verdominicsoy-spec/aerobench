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
    }

    public mutating func release(at t: TimeInterval) {
        tick(at: t)
        if held { lastRelease = t }
        held = false
    }

    /// A camera frame: the measured head (cm), or nil when no face was found.
    /// `rest` is where the head eases to once the face has been gone a while.
    public mutating func face(_ head: SIMD3<Double>?, at t: TimeInterval, rest: SIMD3<Double>) {
        now = max(now, t)
        if let head {
            if lostFrom != nil, let shown = headCM {
                // Coming back after a loss: filter on from what is shown, not from the stale value.
                for i in 0..<3 { filters[i].reset(to: shown[i], at: t) }
            }
            lostFrom = nil
            lastFace = t
            headCM = SIMD3((0..<3).map { filters[$0].filter(head[$0], at: t) })
            return
        }
        guard let seen = lastFace, let shown = headCM, t - seen > faceLostAfter else { return }
        if lostFrom == nil { lostFrom = shown }
        let p = min(max((t - seen - faceLostAfter) / fade, 0), 1)
        headCM = simd_mix(lostFrom!, rest, SIMD3(repeating: p * p * (3 - 2 * p)))
    }

    public mutating func tick(at t: TimeInterval) {
        let dt = max(t - now, 0)
        now = max(now, t)
        progress = min(max(progress + (held ? dt : -dt) / fade, 0), 1)
        // Snap rounding residue, so "off" is exactly 0 and the peek camera is let go.
        if progress < 1e-9 { progress = 0 } else if progress > 1 - 1e-9 { progress = 1 }
    }
}
