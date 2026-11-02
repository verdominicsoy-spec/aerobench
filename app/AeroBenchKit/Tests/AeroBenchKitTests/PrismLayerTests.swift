import XCTest
@testable import AeroBenchKit

final class PrismLayerTests: XCTestCase {
    func testMatchesTheEngineFlatPlateSizes() throws {
        // 15 m/s air over a 1 m length, y+ 1: Re about 1.02e6.
        let p = try XCTUnwrap(PrismLayer(velocity: 15, density: 1.225, yPlus: 1))
        XCTAssertEqual(p.reynolds, 1.225 * 15 / 1.81e-5, accuracy: 1)
        // The engine's form: y = y+ L / (Re sqrt(Cf / 2)).
        let cf = 0.026 / pow(p.reynolds, 1.0 / 7)
        XCTAssertEqual(p.wallDistance, 1 / (p.reynolds * (cf / 2).squareRoot()), accuracy: 1e-12)
        XCTAssertEqual(p.firstCell, 2 * p.wallDistance)
        XCTAssertEqual(p.total, 0.37 * pow(p.reynolds, -0.2), accuracy: 1e-12)
        // Enough layers to reach the total, one fewer falls short.
        let reach = { (n: Int) in p.firstCell * (pow(1.2, Double(n)) - 1) / 0.2 }
        XCTAssertGreaterThanOrEqual(reach(p.layers), p.total)
        XCTAssertLessThan(reach(p.layers - 1), p.total)
    }

    func testRejectsInputsWithNoAnswer() {
        XCTAssertNil(PrismLayer(velocity: 0, density: 1.225, yPlus: 1))
        XCTAssertNil(PrismLayer(velocity: 15, density: 1.225, yPlus: 1, stretching: 1))
    }
}
