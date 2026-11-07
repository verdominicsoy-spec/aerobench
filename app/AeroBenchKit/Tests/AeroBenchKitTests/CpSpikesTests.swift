import XCTest
@testable import AeroBenchKit

final class CpSpikesTests: XCTestCase {
    func testASpikeIsCutAndTheLineBreaks() {
        let x = (0...100).map(Double.init)  // 100 mm chord, a point every 1%
        var y = x.map { 1 + 0.01 * $0 }
        y[50] = 20  // a jump of about 18 in 1% of the chord: far steeper than the limit
        let runs = CpSpikes.runs(x: x, y: y)
        XCTAssertNil(runs[50])
        XCTAssertEqual(runs[49], 0)
        XCTAssertEqual(runs[51], 1)
    }

    /// A spike rising from the surface's first point cuts the higher neighbour,
    /// leaving the first point alone: a lone point draws no line, so it goes too
    /// (kept, it stretched the scale to 400 and flattened the real curves).
    func testALonePointLeftByACutIsDropped() {
        let x = (0...20).map(Double.init)
        var y = x.map { _ in 1.0 }
        y[0] = 433; y[1] = 554; y[2] = 785; y[3] = 400; y[4] = 120
        let runs = CpSpikes.runs(x: x, y: y)
        XCTAssertNil(runs[0])
        XCTAssertNotNil(runs[10])
        let kept = zip(y, runs).compactMap { $1 == nil ? nil : $0 }
        XCTAssertLessThan(CpSpikes.domain(kept).upperBound, 2)
    }

    func testAGentleLineIsKeptWhole() {
        let x = (0...10).map { Double($0) * 10 }
        let runs = CpSpikes.runs(x: x, y: x.map { 3 - 0.02 * $0 })
        XCTAssertEqual(runs, Array(repeating: 0, count: 11))
    }
}
