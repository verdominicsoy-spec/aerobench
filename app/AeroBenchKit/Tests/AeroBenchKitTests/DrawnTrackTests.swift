import XCTest
@testable import AeroBenchKit

final class DrawnTrackTests: XCTestCase {
    /// A dense circle, as the engine would send a centreline.
    private func circle(radius: Double, count: Int = 2000) -> ([Double], [Double]) {
        let th = (0..<count).map { 2 * Double.pi * Double($0) / Double(count) }
        return (th.map { radius * cos($0) }, th.map { radius * sin($0) })
    }

    func testFitFollowsTheCentreline() {
        let (x, y) = circle(radius: 20)
        let track = DrawnTrack.fit(x: x, y: y, closed: true, source: "circle")
        XCTAssertTrue(track.isUsable)
        XCTAssertLessThan(track.nodes.count, 20)  // few enough to drag
        XCTAssertEqual(track.length, 2 * .pi * 20, accuracy: 0.2)
        for p in track.samples(spacing: 1) {
            XCTAssertEqual((p.x * p.x + p.y * p.y).squareRoot(), 20, accuracy: 0.05)
            XCTAssertEqual(p.kappa, 1.0 / 20, accuracy: 0.002)
        }
        XCTAssertEqual(track.issues(track.samples()), [])
    }

    func testRuleBreaksAreFound() {
        let (x, y) = circle(radius: 2.5)
        let tight = DrawnTrack.fit(x: x, y: y, closed: true)
        let issues = tight.issues(tight.samples())
        XCTAssertEqual(issues.count, 1)  // one turn, round the whole loop
        XCTAssertEqual(issues.first?.kind, .tooTight)
        XCTAssertEqual(issues.first?.value ?? 0, 2.5, accuracy: 0.1)

        // A 100 m straight, open: too long. Then a 60 m one: fine.
        for (length, expected) in [(100.0, 1), (60.0, 0)] {
            let xs = stride(from: 0.0, through: length, by: 0.5).map { $0 }
            let line = DrawnTrack.fit(x: xs, y: xs.map { _ in 0 }, closed: false)
            let found = line.issues(line.samples()).filter { $0.kind == .longStraight }
            XCTAssertEqual(found.count, expected)
            if expected == 1 { XCTAssertEqual(found[0].value, length, accuracy: 0.5) }
            XCTAssertEqual(line.extremes(line.samples()).longestStraight, length, accuracy: 0.5)
        }
    }

    func testRunsWrapRoundAClosedLap() {
        XCTAssertEqual(DrawnTrack.runs([true, false, false, true], closed: true).map { [$0.0, $0.1] }, [[3, 2]])
        XCTAssertEqual(DrawnTrack.runs([true, false, false, true], closed: false).map { [$0.0, $0.1] }, [[0, 1], [3, 1]])
        XCTAssertEqual(DrawnTrack.runs([true, true], closed: true).map { [$0.0, $0.1] }, [[0, 2]])
    }

    func testSplitKeepsTheShape() {
        let (x, y) = circle(radius: 15)
        var track = DrawnTrack.fit(x: x, y: y, closed: true)
        let before = track.samples(spacing: 0.5)
        let n = track.nodes.count
        let at = track.split(segment: 2, at: 0.3)
        XCTAssertEqual(at, 3)
        XCTAssertEqual(track.nodes.count, n + 1)
        XCTAssertEqual(track.length, before.last!.s, accuracy: 0.01)
        let p = track.nodes[3]
        XCTAssertEqual((p.x * p.x + p.y * p.y).squareRoot(), 15, accuracy: 0.05)
        // The new node is where the click landed.
        let hit = track.nearest(to: [p.x + 0.1, p.y])!
        XCTAssertLessThan(hit.distance, 0.11)
    }

    func testHandlesStayInLine() {
        let (x, y) = circle(radius: 15)
        var track = DrawnTrack.fit(x: x, y: y, closed: true)
        let inLength = (track.nodes[1].inHandle * track.nodes[1].inHandle).sum().squareRoot()
        track.setHandle(1, out: true, to: [3, 4])
        XCTAssertEqual(track.nodes[1].outHandle, [3, 4])
        XCTAssertEqual(track.nodes[1].inX, -0.6 * inLength, accuracy: 1e-9)
        XCTAssertEqual(track.nodes[1].inY, -0.8 * inLength, accuracy: 1e-9)
    }

    func testReversedRunsTheOtherWay() {
        let (x, y) = circle(radius: 15)
        let track = DrawnTrack.fit(x: x, y: y, closed: true)
        XCTAssertGreaterThan(track.samples()[10].kappa, 0)
        XCTAssertLessThan(track.reversed().samples()[10].kappa, 0)
        XCTAssertEqual(track.reversed().length, track.length, accuracy: 0.01)
    }

    func testSavedWithTheSetupAndSentAsPoints() throws {
        let (x, y) = circle(radius: 20)
        var setup = LapSimSetup()
        setup.track.kind = .drawn
        setup.track.drawn = DrawnTrack.fit(x: x, y: y, closed: true, source: "FSG Hockenheim")
        let back = try AeroJSON.decoder().decode(LapSimSetup.self, from: AeroJSON.encoder().encode(setup))
        XCTAssertEqual(back.track, setup.track)
        guard case .object(let obj) = setup.track.jobValue(lapsimFolder: nil),
              case .object(let pts) = obj["points"], case .array(let xs) = pts["x"] else { return XCTFail() }
        XCTAssertEqual(obj["closed"], .bool(true))
        XCTAssertEqual(Double(xs.count), 2 * .pi * 20, accuracy: 15)  // about a metre apart, end not repeated
        // Nothing drawn yet: no points (the engine refuses them with a clear message), not a crash.
        var empty = LapSimTrack()
        empty.kind = .drawn
        guard case .object(let none) = empty.jobValue(lapsimFolder: nil), case .object(let nonePts) = none["points"] else { return XCTFail() }
        XCTAssertEqual(nonePts["x"], .array([]))
    }
}
