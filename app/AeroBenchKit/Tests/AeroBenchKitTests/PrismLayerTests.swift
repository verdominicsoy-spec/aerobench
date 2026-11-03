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
        XCTAssertEqual(p.treatment, .resolved)
        XCTAssertEqual(p.achievedYPlus, 1, accuracy: 0.001)
        XCTAssertEqual(p.warnings, [.noClearance])
        // Enough layers to reach the total, one fewer falls short.
        let reach = { (n: Int) in p.firstCell * (pow(1.2, Double(n)) - 1) / 0.2 }
        XCTAssertGreaterThanOrEqual(reach(p.layers), p.total)
        XCTAssertLessThan(reach(p.layers - 1), p.total)
    }

    func testWallFunctionsSizeByCountNotBoundaryLayer() throws {
        let p = try XCTUnwrap(PrismLayer(velocity: 20, density: 1.225, yPlus: 40, length: 1,
                                         layers: 4, stretching: 1.25))
        XCTAssertEqual(p.treatment, .wallFunctions)
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
        XCTAssertEqual(p.treatment, .resolved)
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

    func testYPlus40SwitchesToWallFunctionsAndDropsLayersThatDoNotFit() throws {
        // The old resolved repro at y+ 40: a 4 mm cap holds two of the three layers.
        let p = try XCTUnwrap(PrismLayer(velocity: 20, density: 1.225, yPlus: 40, length: 1,
                                         layers: 3, clearance: 0.012, stretching: 1.3))
        XCTAssertEqual(p.treatment, .wallFunctions)
        XCTAssertEqual(p.layers, 2)
        XCTAssertEqual(p.firstCell, 1.421e-3, accuracy: 0.0005e-3)
        XCTAssertEqual(p.total, 3.27e-3, accuracy: 0.005e-3)
        XCTAssertEqual(p.total, p.firstCell * 2.3, accuracy: 1e-12)
        XCTAssertTrue(p.warnings.contains(.layersDropped))
    }

    func testModeFollowsYPlus() {
        XCTAssertEqual(PrismLayer.WallTreatment(yPlus: 0.5), .resolved)
        XCTAssertEqual(PrismLayer.WallTreatment(yPlus: 1), .resolved)
        XCTAssertEqual(PrismLayer.WallTreatment(yPlus: 5), .resolved)
        XCTAssertEqual(PrismLayer.WallTreatment(yPlus: 5.1), .wallFunctions)
        XCTAssertEqual(PrismLayer.WallTreatment(yPlus: 30), .wallFunctions)
        XCTAssertEqual(PrismLayer.WallTreatment(yPlus: 150), .wallFunctions)
    }

    func testBufferLayerYPlusWarns() throws {
        let p = try XCTUnwrap(PrismLayer(velocity: 20, density: 1.225, yPlus: 10, length: 1, clearance: 0.028))
        XCTAssertEqual(p.treatment, .wallFunctions)
        XCTAssertTrue(p.warnings.contains(.bufferLayer))
        let q = try XCTUnwrap(PrismLayer(velocity: 20, density: 1.225, yPlus: 3, length: 1, clearance: 0.028))
        XCTAssertEqual(q.treatment, .resolved)
        XCTAssertTrue(q.warnings.contains(.bufferLayer))
    }

    func testYPlusOver100Warns() throws {
        let p = try XCTUnwrap(PrismLayer(velocity: 20, density: 1.225, yPlus: 150, length: 1, clearance: 0.1))
        XCTAssertEqual(p.treatment, .wallFunctions)
        XCTAssertTrue(p.warnings.contains(.tooFar))
        XCTAssertFalse(p.warnings.contains(.bufferLayer))
    }

    func testWarningsForEachLimit() throws {
        let steep = try XCTUnwrap(PrismLayer(velocity: 20, density: 1.225, yPlus: 40, length: 1,
                                             layers: 6, stretching: 1.4))
        XCTAssertEqual(steep.warnings, [.thickStack, .steepStretching])
        let thin = try XCTUnwrap(PrismLayer(velocity: 80, density: 1.225, yPlus: 0.5, length: 1, clearance: 0.1))
        XCTAssertEqual(thin.warnings, [.thinFirstCell])
    }

    func testGapThinnerThanTheFirstCellWarnsInsteadOfDroppingLayers() throws {
        // A wheel at y+ 40 with 1 mm to the ground: one 1.35 mm cell can't fit a 0.33 mm cap.
        let wheel = try XCTUnwrap(PrismLayer(velocity: 20, density: 1.225, yPlus: 40, length: 0.5, clearance: 0.001, stretching: 1.25))
        XCTAssertTrue(wheel.warnings.contains(.gapTooSmall))
        XCTAssertFalse(wheel.warnings.contains(.layersDropped))
        // 28 mm typed as 0.028 into the mm box: the cap falls under the near wall cell.
        let typo = try XCTUnwrap(PrismLayer(velocity: 20, density: 1.225, yPlus: 1, length: 1, clearance: 0.028e-3))
        XCTAssertTrue(typo.warnings.contains(.gapTooSmall))
    }

    func testSmallPartAtWallFunctionYPlusWarns() throws {
        // A 25 mm suspension arm at y+ 40: the first cell is about the whole boundary layer.
        let arm = try XCTUnwrap(PrismLayer(velocity: 20, density: 1.225, yPlus: 40, length: 0.025, layers: 3, stretching: 1.3))
        XCTAssertTrue(arm.warnings.contains(.smallPart))
        let body = try XCTUnwrap(PrismLayer(velocity: 20, density: 1.225, yPlus: 40, length: 3, stretching: 1.25))
        XCTAssertFalse(body.warnings.contains(.smallPart))
    }

    func testTypoWarnings() throws {
        let stretch = try XCTUnwrap(PrismLayer(velocity: 20, density: 1.225, yPlus: 1, length: 1, stretching: 1.01))
        XCTAssertTrue(stretch.warnings.contains(.manyLayers))
        let millimetres = try XCTUnwrap(PrismLayer(velocity: 16.67, density: 1.225, yPlus: 1, length: 300))
        XCTAssertTrue(millimetres.warnings.contains(.unlikelyLength))
    }

    func testNonFiniteInputsHaveNoAnswerInsteadOfTrapping() {
        XCTAssertNil(PrismLayer(velocity: .infinity, density: 1.225, yPlus: 1, length: 1))
        XCTAssertNil(PrismLayer(velocity: .nan, density: 1.225, yPlus: 1, length: 1))
        XCTAssertNil(PrismLayer(velocity: 20, density: 1.225, yPlus: 1, length: 1, clearance: .infinity))
        XCTAssertNil(PrismLayer(velocity: 20, density: 1.225, yPlus: 1, length: 1, stretching: .infinity))
        XCTAssertNil(PrismLayer(velocity: 20, density: 1.225, yPlus: 40, length: 1, stretching: 1e300))
    }

    func testRejectsInputsWithNoAnswer() {
        XCTAssertNil(PrismLayer(velocity: 0, density: 1.225, yPlus: 1, length: 0.3))
        XCTAssertNil(PrismLayer(velocity: 15, density: 1.225, yPlus: 1, length: 0.3, stretching: 1))
        XCTAssertNil(PrismLayer(velocity: 15, density: 1.225, yPlus: 1, length: 0.3, clearance: 0))
        XCTAssertNil(PrismLayer(velocity: 15, density: 1.225, yPlus: 40, length: 0.3, layers: 7))
    }
}
