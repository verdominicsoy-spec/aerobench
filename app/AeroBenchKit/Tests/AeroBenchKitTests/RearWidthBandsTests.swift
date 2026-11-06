import XCTest
@testable import AeroBenchKit

/// FS 2027 T8.2.2: the rear wing zone narrows between the rear tyre tops and 700 mm.
final class RearWidthBandsTests: XCTestCase {
    // realtest's car: rear tyres 250 wide at y ±572, tops 455 mm off the ground
    let setup = CarSetup(step: "", wheels: [
        .init(name: "FL", centre: [-629, 613, 179], radius: 227, width: 250),
        .init(name: "FR", centre: [-629, -613, 179], radius: 227, width: 250),
        .init(name: "RL", centre: [-2179, 572, 181], radius: 227, width: 250),
        .init(name: "RR", centre: [-2179, -572, 181], radius: 227, width: 250),
    ], groundZ: -48, headRestraint: [-1647, 700])

    func testBands() {
        let b = CarRules.widthBands(setup)
        XCTAssertEqual(b.count, 3)
        XCTAssertEqual(b[0].maxSpan, 2 * (613 + 125), accuracy: 1e-9)  // inside the wheels
        XCTAssertEqual(b[1].minZ, 181 + 227, accuracy: 1e-9)           // from the rear tyre tops
        XCTAssertEqual(b[1].maxZ, -48 + 700, accuracy: 1e-9)
        XCTAssertEqual(b[1].maxSpan, 2 * (572 - 125 - 150), accuracy: 1e-9)  // 594 mm
        XCTAssertEqual(b[2].maxSpan, 2 * (572 + 125), accuracy: 1e-9)  // to the rear wheels' outer edges
        XCTAssertEqual(b[2].maxZ, -48 + 1100, accuracy: 1e-9)
    }

    func testBoxStartsWhereTheSpanFits() {
        XCTAssertEqual(CarRules.box(.rear, setup: setup, span: 1.0).minZ, -48 + 700, accuracy: 1e-9)  // too wide below 700
        XCTAssertEqual(CarRules.box(.rear, setup: setup, span: 0.5).minZ, -48 + 30, accuracy: 1e-9)   // fits every band
        XCTAssertEqual(CarRules.box(.rear, setup: setup).minZ, -48 + 30, accuracy: 1e-9)              // no span: the whole zone
        XCTAssertEqual(CarRules.box(.front, setup: setup, span: 2.0).minZ, -48 + 30, accuracy: 1e-9)  // front unchanged
    }
}

/// Moving the wing on the Wing Lab canvas moves it on the car: the box stays.
final class WingBoxPlacementTests: XCTestCase {
    let setup = RearWidthBandsTests().setup

    private func card(_ wing: Wing) -> WingCard {
        WingCard.make(wing: wing, cl: 0, cd: 0, solver: "", id: "d", name: "", revision: -1)
    }

    func testPlacementInvertsTheBox() throws {
        var wing = Wing(elements: [WingElement(airfoil: Airfoil(key: "test/flat", name: "flat", family: "test", source: "test", thickness: 0.02, thicknessX: 0.5,
                                                                            camber: 0, camberX: 0.5, teThickness: 0,
                                                                            coords: [SIMD2(1, 0), SIMD2(0, 0.01), SIMD2(0, 0), SIMD2(1, 0)]),
                                               chord: 0.3, leadingEdge: SIMD2(0.1, 0.2))])
        wing.rulesFor = .rear
        wing.span = 0.5
        let at = Placement(card: "d", x: -400, height: 800)
        let box = CarRules.wingBox(card(wing), placement: at, setup: setup)
        let back = CarRules.placement(for: card(wing), in: box, setup: setup)
        XCTAssertEqual(back.x, at.x, accuracy: 1e-6)
        XCTAssertEqual(back.height, at.height, accuracy: 1e-6)

        // Drag the wing 50 mm downstream and 20 mm up on the canvas: it moves on the car, the box doesn't
        wing.elements[0].leadingEdge += SIMD2(0.05, 0.02)
        let moved = CarRules.placement(for: card(wing), in: box, setup: setup)
        XCTAssertEqual(moved.x, at.x - 50, accuracy: 1e-6)  // car x is forward, the wing frame's x downstream
        XCTAssertEqual(moved.height, at.height + 20, accuracy: 1e-6)
        let again = CarRules.wingBox(card(wing), placement: moved, setup: setup)
        for (a, b) in [(again.minX, box.minX), (again.minY, box.minY), (again.maxX, box.maxX), (again.maxY, box.maxY)] {
            XCTAssertEqual(a, b, accuracy: 1e-9)
        }
    }
}
