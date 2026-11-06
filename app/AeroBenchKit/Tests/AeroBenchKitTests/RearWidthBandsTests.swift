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
