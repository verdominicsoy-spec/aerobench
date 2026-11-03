import XCTest
@testable import AeroBenchKit

final class PrismLayerTests: XCTestCase {
    func testResolvedWingAt60KmH() throws {
        // 60 km/h over a 300 mm chord, y+ 1: Re about 338,400.
        let p = try XCTUnwrap(PrismLayer(velocity: 60 / 3.6, density: 1.225, yPlus: 1, length: 0.3))
        XCTAssertEqual(p.reynolds, 338_400, accuracy: 100)
        XCTAssertEqual(p.frictionVelocity, 0.765, accuracy: 0.001)
        XCTAssertEqual(p.wallDistance, 19.3e-6, accuracy: 0.05e-6)
        XCTAssertEqual(p.firstCell, 2 * p.wallDistance)  // STAR reads y+ at the centroid
        XCTAssertEqual(p.firstCell, 38.6e-6, accuracy: 0.1e-6)
        XCTAssertEqual(p.boundaryLayer, 8.70e-3, accuracy: 0.005e-3)
        XCTAssertEqual(p.total, p.boundaryLayer)
        XCTAssertFalse(p.capped)
        XCTAssertEqual(p.layers, 22)
        XCTAssertEqual(p.achievedYPlus, 1, accuracy: 0.001)
        XCTAssertEqual(p.warnings, [.noClearance])
        // Enough layers to reach the total, one fewer falls short.
        let reach = { (n: Int) in p.firstCell * (pow(1.2, Double(n)) - 1) / 0.2 }
        XCTAssertGreaterThanOrEqual(reach(p.layers), p.total)
        XCTAssertLessThan(reach(p.layers - 1), p.total)
    }

    func testWallFunctionsSizeByCountNotBoundaryLayer() throws {
        let p = try XCTUnwrap(PrismLayer(velocity: 20, density: 1.225, yPlus: 40, length: 1,
                                         treatment: .wallFunctions, layers: 4, stretching: 1.25))
        XCTAssertEqual(p.firstCell, 1.42e-3, accuracy: 0.005e-3)
        XCTAssertEqual(p.total, 8.19e-3, accuracy: 0.005e-3)
        XCTAssertEqual(p.total, p.firstCell * (pow(1.25, 4) - 1) / 0.25, accuracy: 1e-12)
        XCTAssertEqual(p.layers, 4)
        XCTAssertEqual(p.warnings, [])
    }

    func testClearanceCapsTheTotalAtAThird() throws {
        let p = try XCTUnwrap(PrismLayer(velocity: 20, density: 1.225, yPlus: 1, length: 1,
                                         clearance: 0.028, stretching: 1.2))
        XCTAssertEqual(p.uncappedTotal, 21.97e-3, accuracy: 0.01e-3)
        XCTAssertEqual(p.total, 9.33e-3, accuracy: 0.005e-3)
        XCTAssertTrue(p.capped)
        XCTAssertEqual(p.layers, 22)
        XCTAssertFalse(p.warnings.contains(.noClearance))
    }

    func testFullCarCaseWarnsWithoutClearance() throws {
        // The settings that crushed a 28 mm floor gap: 1 m reference, 20 m/s, resolved.
        let p = try XCTUnwrap(PrismLayer(velocity: 20, density: 1.225, yPlus: 1, length: 1))
        XCTAssertEqual(p.total, 21.97e-3, accuracy: 0.01e-3)
        XCTAssertFalse(p.capped)
        XCTAssertTrue(p.warnings.contains(.noClearance))
    }

    func testWallFunctionsDropLayersThatDoNotFitUnderTheCap() throws {
        // 1.42 mm first cell, 12 mm clearance: a 4 mm cap holds two layers, not four.
        let p = try XCTUnwrap(PrismLayer(velocity: 20, density: 1.225, yPlus: 40, length: 1,
                                         treatment: .wallFunctions, layers: 4, clearance: 0.012, stretching: 1.25))
        XCTAssertEqual(p.total, 0.004, accuracy: 1e-12)
        XCTAssertEqual(p.layers, 2)
    }

    func testWarningsForEachLimit() throws {
        let steep = try XCTUnwrap(PrismLayer(velocity: 20, density: 1.225, yPlus: 40, length: 1,
                                             treatment: .wallFunctions, layers: 6, stretching: 1.4))
        XCTAssertEqual(steep.warnings, [.thickStack, .steepStretching])
        let lowYPlus = try XCTUnwrap(PrismLayer(velocity: 20, density: 1.225, yPlus: 5, length: 1,
                                                treatment: .wallFunctions))
        XCTAssertTrue(lowYPlus.warnings.contains(.yPlusOutOfRange))
        let thin = try XCTUnwrap(PrismLayer(velocity: 80, density: 1.225, yPlus: 0.5, length: 1, clearance: 0.1))
        XCTAssertEqual(thin.warnings, [.thinFirstCell])
    }

    func testStarLinesInOrder() throws {
        let p = try XCTUnwrap(PrismLayer(velocity: 20, density: 1.225, yPlus: 40, length: 1,
                                         treatment: .wallFunctions, layers: 4, stretching: 1.25))
        let lines = p.starLines.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "Number of Prism Layers\t4")
        XCTAssertTrue(lines[1].hasPrefix("Prism Layer Total Thickness\t8.19"))
        XCTAssertTrue(lines[2].hasPrefix("Prism Layer Near Wall Thickness\t1.42"))
        XCTAssertTrue(lines[3].hasPrefix("// stretching 1.25, achieved y+ 40"))
    }

    func testRejectsInputsWithNoAnswer() {
        XCTAssertNil(PrismLayer(velocity: 0, density: 1.225, yPlus: 1, length: 0.3))
        XCTAssertNil(PrismLayer(velocity: 15, density: 1.225, yPlus: 1, length: 0.3, stretching: 1))
        XCTAssertNil(PrismLayer(velocity: 15, density: 1.225, yPlus: 1, length: 0.3, clearance: 0))
        XCTAssertNil(PrismLayer(velocity: 15, density: 1.225, yPlus: 40, length: 0.3, treatment: .wallFunctions, layers: 7))
    }
}
