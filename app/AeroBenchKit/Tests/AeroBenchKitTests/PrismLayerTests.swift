import XCTest
@testable import AeroBenchKit

final class PrismLayerTests: XCTestCase {
    func testMatchesTheEngineFlatPlateSizes() throws {
        // 15 m/s air over a 1 m chord, y+ 1: Re about 1.02e6.
        let p = try XCTUnwrap(PrismLayer(velocity: 15, density: 1.225, yPlus: 1, chord: 1))
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

    func testTotalScalesWithChordNotYPlus() throws {
        let main = try XCTUnwrap(PrismLayer(velocity: 15, density: 1.225, yPlus: 1, chord: 0.3))
        let coarse = try XCTUnwrap(PrismLayer(velocity: 15, density: 1.225, yPlus: 30, chord: 0.3))
        XCTAssertEqual(main.total, 0.0089, accuracy: 0.0001)  // about 9 mm, not the 23 mm of a 1 m plate
        XCTAssertEqual(coarse.total, main.total)
        XCTAssertEqual(coarse.firstCell, 30 * main.firstCell, accuracy: 1e-12)
    }

    func testNoSlotKeepsStarDefaults() throws {
        let p = try XCTUnwrap(PrismLayer(velocity: 15, density: 1.225, yPlus: 1, chord: 0.3))
        XCTAssertEqual([p.gapFillPercentage, p.reductionPercentage, p.minimumThicknessPercentage], [25, 50, 10])
    }

    func testAWideSlotRaisesGapFillToFitTheLayer() throws {
        // 8.9 mm in a 30 mm slot needs 30 % a side.
        let p = try XCTUnwrap(PrismLayer(velocity: 15, density: 1.225, yPlus: 1, chord: 0.3, slotGap: 0.030))
        XCTAssertEqual(p.gapFillPercentage, 30)
        XCTAssertEqual(p.slotShare, 1)
        XCTAssertEqual(p.reductionPercentage, 50)
    }

    func testANarrowSlotKeepsEveryLayer() throws {
        // A 12 mm slot holds 40 % a side, 4.8 mm, about 54 % of the total.
        let p = try XCTUnwrap(PrismLayer(velocity: 15, density: 1.225, yPlus: 1, chord: 0.3, slotGap: 0.012))
        XCTAssertEqual(p.gapFillPercentage, 40)
        XCTAssertEqual(p.slotShare, 0.4 * 0.012 / p.total, accuracy: 1e-12)
        XCTAssertLessThan(p.reductionPercentage, 100 * p.slotShare)  // no layer dropped in the slot
        XCTAssertLessThan(p.minimumThicknessPercentage, p.reductionPercentage)
    }

    func testStarLengthFormat() {
        XCTAssertEqual(PrismLayer.starLength(3.677e-5), "3.677E-5 m")
        XCTAssertEqual(PrismLayer.starLength(0.0089), "8.900E-3 m")
    }

    func testRejectsInputsWithNoAnswer() {
        XCTAssertNil(PrismLayer(velocity: 0, density: 1.225, yPlus: 1, chord: 0.3))
        XCTAssertNil(PrismLayer(velocity: 15, density: 1.225, yPlus: 1, chord: 0.3, stretching: 1))
        XCTAssertNil(PrismLayer(velocity: 15, density: 1.225, yPlus: 1, chord: 0.3, slotGap: 0))
    }
}
