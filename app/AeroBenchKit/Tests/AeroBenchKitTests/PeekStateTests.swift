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
}
