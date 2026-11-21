import XCTest
import simd
@testable import AeroBench3D

final class PeekStateTests: XCTestCase {
    let dt = 1.0 / 30

    func testFilterHoldsAConstant() {
        var f = OneEuroFilter()
        var y = 0.0
        for i in 0..<60 { y = f.filter(5, at: Double(i) * dt) }
        XCTAssertEqual(y, 5, accuracy: 1e-9)
    }

    func testFilterFollowsAStep() {
        var f = OneEuroFilter()
        for i in 0..<30 { _ = f.filter(0, at: Double(i) * dt) }
        var y = 0.0
        for i in 30..<39 { y = f.filter(10, at: Double(i) * dt) }  // 0.3 s after the step
        XCTAssertGreaterThan(y, 9)
    }

    func testFilterReducesNoise() {
        var f = OneEuroFilter()
        var out: [Double] = []
        for i in 0..<120 { out.append(f.filter(i % 2 == 0 ? 10.5 : 9.5, at: Double(i) * dt)) }
        let tail = out.suffix(60), mean = tail.reduce(0, +) / Double(tail.count)
        let sd = sqrt(tail.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(tail.count))
        XCTAssertLessThan(sd, 0.5 / 3)
    }

    private let rest = SIMD3<Double>(0, 0, 55)

    /// Pressed at 0 with a face already seen.
    private func pressedWithFace() -> PeekState {
        var s = PeekState()
        s.press(at: 0, trackerAvailable: true)
        s.face(SIMD3(1, 2, 55), at: 0, rest: rest)
        return s
    }

    func testBlendEasesInAndOut() {
        var s = pressedWithFace()
        XCTAssertEqual(s.blend, 0)
        var last = 0.0
        for t in stride(from: 0.01, through: 0.15, by: 0.01) {
            s.tick(at: t)
            XCTAssertGreaterThanOrEqual(s.blend, last)
            last = s.blend
        }
        s = pressedWithFace()
        s.tick(at: 0.075)
        XCTAssertGreaterThan(s.blend, 0)
        XCTAssertLessThan(s.blend, 1)
        s.tick(at: 0.15)
        XCTAssertEqual(s.blend, 1)
        s.release(at: 1.0)
        XCTAssertEqual(s.blend, 1)
        last = 1
        for t in stride(from: 1.01, through: 1.15, by: 0.01) {
            s.tick(at: t)
            XCTAssertLessThanOrEqual(s.blend, last)
            last = s.blend
        }
        s.tick(at: 1.15)
        XCTAssertEqual(s.blend, 0)
    }

    func testDeactivationEndsPeek() {
        var s = pressedWithFace()
        s.tick(at: 0.075)
        let mid = s.blend
        s.release(at: 0.075)  // e.g. the window lost key mid-ease
        XCTAssertEqual(s.blend, mid, accuracy: 1e-12, "no jump")
        s.tick(at: 0.2)
        XCTAssertEqual(s.blend, 0)
    }

    func testFaceLostEasesToRest() throws {
        var s = PeekState()
        let rest = SIMD3<Double>(0, 10, 55)
        s.press(at: 0, trackerAvailable: true)
        for i in 0..<30 { s.face(SIMD3(5, 0, 55), at: Double(i) * dt, rest: rest) }
        let lastFace = 29 * dt
        XCTAssertEqual(try XCTUnwrap(s.headCM).x, 5, accuracy: 1e-9)
        s.face(nil, at: lastFace + 0.4, rest: rest)
        XCTAssertEqual(try XCTUnwrap(s.headCM).x, 5, accuracy: 1e-9, "held while briefly lost")
        s.face(nil, at: lastFace + 0.58, rest: rest)
        let easing = try XCTUnwrap(s.headCM)
        XCTAssertLessThan(easing.x, 5)
        XCTAssertGreaterThan(easing.x, 0)
        s.face(nil, at: lastFace + 0.65, rest: rest)
        XCTAssertLessThan(simd_distance(try XCTUnwrap(s.headCM), rest), 1e-9)
    }

    func testNoBlendBeforeTheFirstFace() {
        // Easing toward a guessed head and then snapping to the real one is a jump.
        var s = PeekState()
        s.press(at: 0, trackerAvailable: true)
        s.tick(at: 0.5)
        XCTAssertEqual(s.blend, 0)
        s.face(SIMD3(1, 2, 55), at: 0.5, rest: rest)
        s.tick(at: 0.575)
        XCTAssertGreaterThan(s.blend, 0)
        XCTAssertLessThan(s.blend, 1)
    }

    func testCameraStopForgetsTheHead() throws {
        var s = pressedWithFace()
        s.tick(at: 0.2)
        s.release(at: 0.2)
        s.tick(at: 0.4)
        s.cameraStopped()
        XCTAssertNil(s.headCM)
        s.press(at: 60, trackerAvailable: true)
        s.tick(at: 60.2)
        XCTAssertEqual(s.blend, 0, "waits for a fresh face")
        s.face(SIMD3(-3, 4, 55), at: 60.2, rest: rest)
        XCTAssertEqual(try XCTUnwrap(s.headCM).x, -3, accuracy: 1e-9, "not filtered from the old head")
    }

    func testShiftPressSetsTheNeutralHead() throws {
        // Where your head is when you press Shift is "straight on": nothing moves until you do.
        var s = PeekState()
        s.press(at: 0, trackerAvailable: true)
        s.face(SIMD3(3, 12, 55), at: 0, rest: rest)
        XCTAssertEqual(try XCTUnwrap(s.offsetCM).x, 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(s.offsetCM).y, 0, accuracy: 1e-9)
        for i in 1...30 { s.face(SIMD3(8, 12, 55), at: Double(i) * dt, rest: rest) }
        XCTAssertEqual(try XCTUnwrap(s.offsetCM).x, 5, accuracy: 0.05)
        s.release(at: 1.5)
        // The next press re-centres on wherever the head is then.
        s.press(at: 2, trackerAvailable: true)
        s.face(SIMD3(8, 12, 55), at: 2, rest: rest)
        XCTAssertEqual(try XCTUnwrap(s.offsetCM).x, 0, accuracy: 0.05)
    }

    func testHeldWhileWaitingForTheFirstFace() {
        // The display loop runs while Shift is held, even at blend 0 before the
        // camera has found a face; stopping there left a cold start dead.
        var s = PeekState()
        s.press(at: 0, trackerAvailable: true)
        s.tick(at: 0.3)
        XCTAssertEqual(s.blend, 0)
        XCTAssertTrue(s.isHeld)
        s.release(at: 0.4)
        XCTAssertFalse(s.isHeld)
        s.press(at: 1, trackerAvailable: false)
        XCTAssertFalse(s.isHeld)
    }

    func testFacesDoNotSlowTheFade() {
        // Camera frames arrive between display ticks; they must not eat tick time.
        var s = PeekState()
        s.press(at: 0, trackerAvailable: true)
        s.face(SIMD3(1, 2, 55), at: 0, rest: rest)
        var t = 0.0
        while t < 0.15 - 1e-9 {
            t += 1.0 / 60
            s.face(SIMD3(1, 2, 55), at: t + 0.005, rest: rest)  // a frame lands just after each tick
            s.tick(at: t + 1.0 / 60 * 0.5)
        }
        s.tick(at: 0.15)
        XCTAssertEqual(s.blend, 1, "fully in after the 0.15 s fade")
    }

    func testUnavailableTrackerNeverBlends() {
        var s = PeekState()
        s.press(at: 0, trackerAvailable: false)
        s.tick(at: 1)
        XCTAssertEqual(s.blend, 0)
        XCTAssertFalse(s.wantsCamera)
    }

    func testCameraStopsAfter30s() {
        var s = PeekState()
        XCTAssertFalse(s.wantsCamera)
        s.press(at: 0, trackerAvailable: true)
        XCTAssertTrue(s.wantsCamera)
        s.release(at: 1)
        s.tick(at: 30.9)
        XCTAssertTrue(s.wantsCamera)
        s.tick(at: 31.1)
        XCTAssertFalse(s.wantsCamera)
        s.press(at: 40, trackerAvailable: true)
        XCTAssertTrue(s.wantsCamera)
    }

    /// Pressed at 0, then a face at `distance` every frame from `from` for `seconds`.
    private func feed(_ s: inout PeekState, distance: Double, from: Double = 0, seconds: Double) {
        if from == 0 { s.press(at: 0, trackerAvailable: true) }
        var t = from
        while t < from + seconds { s.measure(distance: distance, at: t); s.face(rest, at: t, rest: rest); t += dt }
    }

    func testDistanceSettlesOnASteadyFace() throws {
        var s = PeekState()
        feed(&s, distance: 27.5, seconds: 1)
        XCTAssertEqual(try XCTUnwrap(s.distanceCM), 27.5, accuracy: 1e-6)
        var none = PeekState()
        none.press(at: 0, trackerAvailable: true)
        XCTAssertNil(none.distanceCM)
    }

    func testDistanceIsSmoothed() throws {
        var s = PeekState()
        feed(&s, distance: 55, seconds: 1)
        feed(&s, distance: 45.8, from: 1, seconds: 0.1)
        XCTAssertGreaterThan(try XCTUnwrap(s.distanceCM), 55 - 0.5 * (55 - 45.8))
        feed(&s, distance: 45.8, from: 1.1, seconds: 1.9)
        XCTAssertEqual(try XCTUnwrap(s.distanceCM), 45.8, accuracy: 0.01 * 45.8)
    }

    func testDistanceHeldWhenTheFaceIsLost() {
        var s = PeekState()
        feed(&s, distance: 27.5, seconds: 1)
        s.face(nil, at: 1 + s.faceLostAfter + s.fade + 1, rest: rest)
        XCTAssertEqual(s.distanceCM ?? 0, 27.5, accuracy: 1e-6)
    }

    func testOneBadFrameDoesNotJerkTheDistance() {
        for spike in [110.0, 5e6] {
            var s = PeekState()
            feed(&s, distance: 55, seconds: 1)
            var t = 1.0
            s.measure(distance: spike, at: t); s.face(rest, at: t, rest: rest)
            for _ in 0..<30 {
                XCTAssertEqual(s.distanceCM ?? 0, 55, accuracy: 0.55, "spike \(spike)")
                t += dt
                s.measure(distance: 55, at: t); s.face(rest, at: t, rest: rest)
            }
        }
    }

    func testDistanceFollowsTheShownHeadWhenTheFaceComesBack() throws {
        // Leaned in, the face drops out and the head eases back to the press; coming back
        // at the press distance must not lunge in from the old, leaned-in distance.
        var s = PeekState()
        s.press(at: 0, trackerAvailable: true)
        var t = 0.0
        while t < 1 { s.measure(distance: 55, at: t); s.face([0, 0, 55], at: t, rest: [0, 0, 55]); t += dt }
        while t < 2 { s.measure(distance: 30, at: t); s.face([0, 0, 30], at: t, rest: [0, 0, 55]); t += dt }
        s.face(nil, at: 2 + s.faceLostAfter + s.fade + 0.5, rest: [0, 0, 55])
        let back = 3 + s.faceLostAfter + s.fade
        s.measure(distance: 55, at: back)
        XCTAssertEqual(try XCTUnwrap(s.distanceCM), 55, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(s.placementDistanceCM), 55, accuracy: 0.5)
    }

    func testPlacementDistanceFollowsALeanQuickly() throws {
        // The head's sideways place uses a quicker distance, so leaning in doesn't swim;
        // the eye's depth keeps the slow one.
        var s = PeekState()
        feed(&s, distance: 55, seconds: 1)
        feed(&s, distance: 40, from: 1, seconds: 0.3)
        XCTAssertEqual(try XCTUnwrap(s.placementDistanceCM), 40, accuracy: 2)
        XCTAssertGreaterThan(try XCTUnwrap(s.distanceCM), 44)
    }

    func testPressWhileTheFaceIsLostWaitsForAFreshFace() throws {
        // The head shown then is the eased rest, not where you are: the next face sets "straight on".
        var s = PeekState()
        s.press(at: 0, trackerAvailable: true)
        for i in 0..<30 { s.face([0, 0, 55], at: Double(i) * dt, rest: rest) }
        s.release(at: 1)
        s.face(nil, at: 1 + s.faceLostAfter + s.fade + 0.1, rest: [0, 0, 55])
        s.press(at: 2.5, trackerAvailable: true)
        s.face([4, -10, 48], at: 2.6, rest: rest)
        let offset = try XCTUnwrap(s.offsetCM)
        XCTAssertEqual(simd_length(offset), 0, accuracy: 1e-9)
    }

    func testNoDistanceAfterTheCameraStops() {
        var s = PeekState()
        feed(&s, distance: 27.5, seconds: 1)
        s.cameraStopped()
        XCTAssertNil(s.distanceCM)
    }

    func testOffsetIncludesLeaningIn() throws {
        var s = PeekState()
        s.press(at: 0, trackerAvailable: true)
        s.face(SIMD3(0, 0, 55), at: 0, rest: rest)
        for i in 1...30 { s.face(SIMD3(0, 0, 40), at: Double(i) * dt, rest: rest) }
        XCTAssertEqual(try XCTUnwrap(s.offsetCM).z, -15, accuracy: 0.1)
    }

    func testDistanceIsMeasuredBeforeTheHead() throws {
        // The head is placed with the smoothed distance, so it is read first.
        var s = PeekState()
        s.press(at: 0, trackerAvailable: true)
        s.measure(distance: 40, at: 0)
        XCTAssertEqual(try XCTUnwrap(s.distanceCM), 40, accuracy: 1e-9)
    }
}
