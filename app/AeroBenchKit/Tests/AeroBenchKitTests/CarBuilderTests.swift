import XCTest
@testable import AeroBenchKit

final class CarBuilderTests: XCTestCase {
    private func setup() -> CarSetup {
        CarSetup(step: "/x/car.stp", wheels: [
            .init(name: "FL", centre: [-629, 600, 179], radius: 227, width: 250),
            .init(name: "FR", centre: [-629, -600, 179], radius: 227, width: 250),
            .init(name: "RL", centre: [-2179, 570, 179], radius: 227, width: 250),
            .init(name: "RR", centre: [-2179, -570, 179], radius: 227, width: 250),
        ], groundZ: -48)
    }

    private func card(_ position: WingPosition, cla: Double = 0.8, xcp: Double = 0, rideHeight: Double? = nil) -> WingCard {
        let flat = Airfoil(key: "test/flat", name: "flat", family: "test", source: "test", thickness: 0.02, thicknessX: 0.5,
                           camber: 0, camberX: 0, teThickness: 0,
                           coords: [SIMD2(1, 0), SIMD2(0.5, 0.01), SIMD2(0, 0), SIMD2(0.5, -0.01), SIMD2(1, 0)])
        let plate = WingElement(airfoil: flat, chord: 0.3, angle: 0, leadingEdge: SIMD2(0, 0))
        var w = Wing(elements: [plate])
        w.rideHeight = rideHeight
        return WingCard(id: "c\(position.rawValue)", name: "Test", position: position, wing: w, cla: cla, cda: 0.1,
                        xcp: xcp, solver: "estimate", rideHeight: rideHeight, speed: 15, revision: 1)
    }

    func testRulesBoxesComeFromTheCar() {
        let f = CarRules.box(.front, setup: setup())
        XCTAssertEqual(f.minX, -402, accuracy: 1e-9)
        XCTAssertEqual(f.maxX, 298, accuracy: 1e-9)
        XCTAssertEqual(f.minZ, -18, accuracy: 1e-9)
        XCTAssertEqual(f.maxZ, 302, accuracy: 1e-9)
        let r = CarRules.box(.rear, setup: setup())
        XCTAssertEqual(r.minX, -2179 - 227 - 250, accuracy: 1e-9)
        XCTAssertEqual(r.maxX, -2179, accuracy: 1e-9)  // no head restraint marked: the rear axle
        XCTAssertEqual(r.maxZ, -48 + 1100, accuracy: 1e-9)
    }

    func testAPlacementOutsideTheBoxIsClamped() {
        let c = card(.front)
        let inside = Placement(card: c.id, x: 600, height: 60)  // leading edge at x -29, trailing edge -329: inside -402...298
        XCTAssertFalse(inside.clamped(card: c, setup: setup()).clamped)
        let out = Placement(card: c.id, x: 1050, height: 60)  // leading edge at x 421, past the front limit at 298
        let (fixed, moved) = out.clamped(card: c, setup: setup())
        XCTAssertTrue(moved)
        let xs = fixed.placedElements(card: c, setup: setup()).flatMap { $0 }.map(\.x)
        XCTAssertLessThanOrEqual(xs.max()!, 298 + 1e-6)
    }

    func testAWingBiggerThanItsBoxIsReported() {
        let c = card(.front)  // 300 mm chord, 6 mm thick
        XCTAssertTrue(CarRules.fits(c, setup: setup()))
        var long = c
        long.wing.elements[0].chord = 0.8  // longer than the 700 mm front box
        XCTAssertFalse(CarRules.fits(long, setup: setup()))
    }

    func testPlacedElementsSitWhereTyped() {
        let c = card(.front)
        let pts = Placement(card: c.id, x: 400, height: 60).placedElements(card: c, setup: setup()).flatMap { $0 }
        XCTAssertEqual(pts.map(\.x).max()!, -629 + 400, accuracy: 1e-6)  // leading edge 400 mm ahead of the axle
        XCTAssertEqual(pts.map(\.x).min()!, -629 + 400 - 300, accuracy: 1e-6)  // 300 mm chord behind it
        XCTAssertEqual(pts.map(\.y).min()!, -48 + 60, accuracy: 1e-6)
    }

    func testQuickSumAndBalance() {
        let base = CarResult(mesh: "maxed", speed: 15, cla: 1.0, cda: 0.9, rearShare: 0.6, cla2dWings: 1.0, strips: [],
                             converged: true, wings: [])
        let front = card(.front, cla: 0.8)
        var combo = Combination(id: "a", name: "A")
        combo.front = Placement(card: front.id, x: 600, height: 60)
        let q = quick(base: base, combo: combo, cards: [front], setup: setup()) { _, _ in nil }
        XCTAssertEqual(q.cla, 1.8, accuracy: 1e-9)
        XCTAssertEqual(q.cda, 1.0, accuracy: 1e-9)
        let expected: Double = (0.6 * 1.0 - 0.8 * 600.0 / 1550.0) / 1.8
        XCTAssertEqual(q.rearShare ?? .nan, expected, accuracy: 1e-4)
        XCTAssertEqual(q.usedEstimate, [])
    }

    func testAWingMovedOffItsHeightIsReEstimated() {
        let base = CarResult(mesh: "maxed", speed: 15, cla: 1.0, cda: 0.9, rearShare: 0.6, cla2dWings: 1.0, strips: [],
                             converged: true, wings: [])
        let front = card(.front, cla: 0.8, rideHeight: 0.05)
        var combo = Combination(id: "a", name: "A")
        combo.front = Placement(card: front.id, x: 600, height: 80)
        let q = quick(base: base, combo: combo, cards: [front], setup: setup()) { _, h in
            XCTAssertEqual(h, 0.08, accuracy: 1e-12)
            return (cla: 0.7, cda: 0.1)
        }
        XCTAssertEqual(q.usedEstimate, [.front])
        XCTAssertEqual(q.cla, 1.7, accuracy: 1e-9)
    }

    private func base() -> CarResult {
        CarResult(mesh: "maxed", speed: 15, cla: 1.0, cda: 0.9, rearShare: 0.6, cla2dWings: 1.0, strips: [], converged: true, wings: [])
    }

    func testAFullResultGoesOutOfDateWhenAnythingChanges() {
        var front = card(.front)
        var combo = Combination(id: "a", name: "A")
        combo.front = Placement(card: front.id, x: 600, height: 60)
        XCTAssertFalse(combo.isStale(cards: [front], baseRevision: 3))  // no full result: nothing to be out of date
        combo.recordFull(base(), cards: [front], baseRevision: 3)
        XCTAssertFalse(combo.isStale(cards: [front], baseRevision: 3))
        combo.front?.x = 620
        XCTAssertTrue(combo.isStale(cards: [front], baseRevision: 3))  // the wing moved since
        combo.front?.x = 600
        front.revision += 1
        XCTAssertTrue(combo.isStale(cards: [front], baseRevision: 3))  // the card was edited since
        XCTAssertTrue(combo.isStale(cards: [card(.front)], baseRevision: 4))  // the bare car was run again
    }

    func testAPendingReEstimateIsFlagged() {
        var combo = Combination(id: "a", name: "A")
        let inGround = card(.front, cla: 0.8, rideHeight: 0.05)
        combo.front = Placement(card: inGround.id, x: 600, height: 80)
        XCTAssertEqual(quick(base: base(), combo: combo, cards: [inGround], setup: setup()) { _, _ in nil }.pendingEstimate, [.front])
        let freeAir = card(.front, cla: 0.8, rideHeight: nil)  // a front wing designed in free air, placed over the ground
        combo.front = Placement(card: freeAir.id, x: 600, height: 80)
        XCTAssertEqual(quick(base: base(), combo: combo, cards: [freeAir], setup: setup()) { _, h in
            XCTAssertEqual(h, 0.08, accuracy: 1e-12)
            return (cla: 0.9, cda: 0.1)
        }.usedEstimate, [.front])
    }

    func testABaselineMatchesTheSameSettingsHoweverNumbersDecode() {
        let asSent = JSONValue.object(["speed": .double(15), "ground": .object(["moving": .bool(false), "speed": .double(15)]),
                                       "wheels": .object(["rotating": .bool(true), "speed": .double(15)])])
        let asRead = JSONValue.object(["speed": .int(15), "ground": .object(["moving": .bool(false), "speed": .int(15)]),
                                       "wheels": .object(["rotating": .bool(true), "speed": .int(15)])])
        var b = base()
        b.n = 7
        b.flow = asRead
        XCTAssertTrue(b.ranWith(asSent, n: 7))
        XCTAssertFalse(b.ranWith(asSent, n: 5))
        let moving = JSONValue.object(["speed": .double(15), "ground": .object(["moving": .bool(true), "speed": .double(15)]),
                                       "wheels": .object(["rotating": .bool(true), "speed": .double(15)])])
        XCTAssertFalse(b.ranWith(moving, n: 7))
    }

    func testANullCentreOfPressureDecodes() throws {
        let json = #"""
        {"data": {"mesh": "coarse", "speed": 15, "cla": 0, "cda": 0.5, "rear_share": null, "cla_2d_wings": 0, "converged": true,
          "wings": [], "n": 7, "flow": {"speed": 15, "ground": {"moving": false, "speed": 15}}, "open_gaps": 3,
          "failed": [{"y": 200, "width": 150, "reason": "SU2 diverged at every CFL tried"}],
          "strips": [{"y": 50, "width": 100, "lift": 0, "drag": 5, "x_cp": null, "converged": true, "wing_lift": {}, "wing_drag": {}}]}}
        """#
        let r = try CarResult.decode(resultFile: Data(json.utf8))
        XCTAssertNil(r.strips[0].xCp)
        XCTAssertNil(r.rearShare)
        XCTAssertEqual(r.n, 7)
        XCTAssertEqual(r.groundMoving, false)
        XCTAssertEqual(r.openGaps, 3)
        XCTAssertEqual(r.failed?.first?.y, 200)
    }

    func testDecodesACarResult() throws {
        let json = #"""
        {"data": {"mesh": "coarse", "speed": 15, "cla": 0.8, "cda": 0.5, "rear_share": 0.4, "cla_2d_wings": 0.8,
          "converged": false, "wings": [{"position": "front", "cla": 0.2, "cda": 0.05, "cla_2d": 0.3, "cda_2d": 0.04}],
          "strips": [{"y": 50, "width": 100, "lift": -10, "drag": 5, "x_cp": -1000, "converged": false,
                      "reason": "residual fell 1.0 orders", "wing_lift": {"front": -3}, "wing_drag": {"front": 1}}]}}
        """#
        let r = try CarResult.decode(resultFile: Data(json.utf8))
        XCTAssertEqual(r.rearShare, 0.4)
        XCTAssertFalse(r.converged)
        XCTAssertEqual(r.strips[0].wingLift["front"], -3)
        XCTAssertEqual(r.wings[0].cla2d, 0.3)
    }
}
