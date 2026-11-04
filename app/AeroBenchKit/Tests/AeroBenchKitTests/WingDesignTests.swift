import XCTest
@testable import AeroBenchKit

final class WingDesignTests: XCTestCase {
    private func setup() -> CarSetup {
        CarSetup(step: "/x/car.stp", wheels: [
            .init(name: "FL", centre: [-629, 600, 179], radius: 227, width: 250),
            .init(name: "FR", centre: [-629, -600, 179], radius: 227, width: 250),
            .init(name: "RL", centre: [-2179, 570, 179], radius: 227, width: 250),
            .init(name: "RR", centre: [-2179, -570, 179], radius: 227, width: 250),
        ], groundZ: -48)
    }

    private func card(rideHeight: Double?) -> WingCard {
        var w = Wing()
        w.rideHeight = rideHeight
        return WingCard(id: "c", name: "Test", position: .front, wing: w, cla: 0.8, cda: 0.1, xcp: 0,
                        solver: "estimate", rideHeight: rideHeight, speed: 15, revision: 1)
    }

    static let sample = """
    {"data": {"goal": "max_cla", "box": [0, 0.03, 0.7, 0.35],
     "base": {"ride_height": 0.03, "elements": [{"key": "naca/6412", "name": "NACA 6412", "unit": [[1, 0], [0, 0], [1, 0]],
              "chord": 0.4, "angle": 3, "leading_edge": [0, 0.05], "inverted": true, "coords": [[0, 0.05]]},
              {"key": null, "name": null, "unit": [[1, 0], [0, 0], [1, 0]], "chord": 0.2, "angle": 25,
              "leading_edge": [0.38, 0.08], "inverted": true, "coords": [[0.38, 0.08]]}]},
     "study": {"study": "d", "objective": "max_cla", "objective_name": "Most downforce (ClA)", "direction": "maximize",
               "spec": {"variables": [{"element": 0, "kind": "angle", "low": -4, "high": 12}], "objective": "max_cla",
                        "cd_cap": null, "cl_target": null, "sampler": "tpe", "solver": "estimate"},
               "trials": [], "best": null, "complete": 20, "failed": 0, "invalid": 3, "target": 20, "solver": "estimate",
               "checks": []},
     "finalists": [
       {"number": 7, "params": {"angle_0": 3.2}, "estimate_value": 0.9, "cla": 0.88, "cda": 0.07, "cla_cda": 12.6,
        "car_cla": null, "car_cda": null, "rear_share": null, "from": "RANS", "ride_height": 0.04, "x": 0.02,
        "rans": {"cl": -2.1, "cd": 0.05, "converged": true, "separated": false, "reason": null, "value": 0.88}},
       {"number": 3, "params": {"angle_0": 5.0}, "estimate_value": 0.95, "cla": 0.95, "cda": 0.08, "cla_cda": 11.9,
        "car_cla": null, "car_cda": null, "rear_share": null, "from": "estimate", "ride_height": 0.03, "x": 0.0,
        "rans": {"cl": -2.4, "cd": 0.4, "converged": true, "separated": true, "reason": "Main separates in RANS", "value": null}}]}}
    """

    func testDecodesADesignResult() throws {
        let r = try WingDesignResult.decode(resultFile: Data(Self.sample.utf8))
        XCTAssertEqual(r.finalists.count, 2)
        XCTAssertEqual(r.finalists[0].rans?.separated, false)
        XCTAssertEqual(r.finalists[0].claCda, 12.6)
        XCTAssertNil(r.finalists[1].rans?.value)
        XCTAssertTrue(r.finalists[0].held)
        XCTAssertFalse(r.finalists[1].held)
        XCTAssertEqual(r.base.elements[1].key, nil)
        XCTAssertEqual(r.base.elements[0].leadingEdge, [0, 0.05])
    }

    func testAFinalistThatMissesItsTargetInRansDoesNotHold() throws {
        // A drag limit or balance missed in RANS: converged, attached, a (penalised) value, but not feasible.
        let missed = Self.sample.replacingOccurrences(of: "\"separated\": false, \"reason\": null, \"value\": 0.88}",
                                                      with: "\"separated\": false, \"reason\": null, \"value\": 0.5, \"feasible\": false}")
        let r = try WingDesignResult.decode(resultFile: Data(missed.utf8))
        XCTAssertEqual(r.finalists[0].rans?.value, 0.5)
        XCTAssertFalse(r.finalists[0].held)
    }

    func testTheDesignBoxIsTheCarsBoxFromTheGround() {
        let b = CarRules.designBox(.front, setup: setup())  // front box x -402...298, z -18...302, ground -48
        XCTAssertEqual(b.minX, 0, accuracy: 1e-12)
        XCTAssertEqual(b.maxX, 0.700, accuracy: 1e-12)
        XCTAssertEqual(b.minY, 0.030, accuracy: 1e-12)
        XCTAssertEqual(b.maxY, 0.350, accuracy: 1e-12)
    }

    func testADesignPositionBecomesAPlacement() {
        let p = Placement.fromDesign(card: card(rideHeight: 0.05), x: 0.10, setup: setup())
        XCTAssertEqual(p.x, 298 - 100 + 629, accuracy: 1e-9)  // leading edge 100 mm behind the box front, from the front axle
        XCTAssertEqual(p.height, 50, accuracy: 1e-9)
        XCTAssertEqual(Placement.fromDesign(card: card(rideHeight: nil), x: 0.10, setup: setup()).height, 30, accuracy: 1e-9)
    }
}
