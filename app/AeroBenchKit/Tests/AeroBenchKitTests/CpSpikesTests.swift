import XCTest
@testable import AeroBenchKit

final class CpSpikesTests: XCTestCase {
    func testASpikeIsCutAndTheLineBreaks() {
        let x = (0...100).map(Double.init)  // 100 mm chord, a point every 1%
        var y = x.map { 1 + 0.01 * $0 }
        y[50] = 20  // a jump of about 18 in 1% of the chord: steeper than the limit
        let runs = CpSpikes.runs(x: x, y: y)
        XCTAssertNil(runs[50])
        XCTAssertEqual(runs[49], 0)
        XCTAssertEqual(runs[51], 1)
    }

    func testAGentleLineIsKeptWhole() {
        let x = (0...10).map { Double($0) * 10 }
        let runs = CpSpikes.runs(x: x, y: x.map { 3 - 0.02 * $0 })
        XCTAssertEqual(runs, Array(repeating: 0, count: 11))
    }
}
