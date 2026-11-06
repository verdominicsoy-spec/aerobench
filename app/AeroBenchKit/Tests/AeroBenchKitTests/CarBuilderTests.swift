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

    func testACardIsMadeFromTheWingAsSaveDoes() {
        var w = card(.front).wing
        w.rulesFor = .front
        w.rideHeight = 0.05
        let c = WingCard.make(wing: w, cl: -1.2, cd: 0.05, solver: "CFD", id: "a", name: "Front 1", revision: 3)
        let add = w.carContribution(cl: -1.2, cd: 0.05)
        XCTAssertEqual(c.cla, add.cla, accuracy: 1e-12)
        XCTAssertEqual(c.cda, add.cda, accuracy: 1e-12)
        XCTAssertEqual(c.xcp, 0.075, accuracy: 1e-12)
        XCTAssertEqual(c.position, .front)
        XCTAssertEqual(c.rideHeight, 0.05)
        XCTAssertEqual(c.revision, 3)
    }

    func testANewWingStartsAtTheFrontOfItsBox() {
        let p = Placement.start(card: card(.front), setup: setup())
        XCTAssertEqual(p.x, 917, accuracy: 1e-9)  // 298 + 629 - 10
        XCTAssertEqual(p.height, 40, accuracy: 1e-9)  // 30 mm clearance + 10
    }

    func testTheDraftTakesItsEndsSlotAtItsOwnRideHeight() {
        var combo = Combination(id: "k", name: "K")
        combo.front = Placement(card: "cfront", x: 600, height: 60)
        combo.rear = Placement(card: "crear", x: -100, height: 700)
        var d = card(.front, rideHeight: 0.08)
        d.id = "draft"
        let at = combo.draftPlacement(d, setup: setup())
        XCTAssertEqual(at, Placement(card: "draft", x: 600, height: 80))
        let shown = combo.overlaying(d, at: at)
        XCTAssertEqual(shown.front, at)
        XCTAssertEqual(shown.rear, combo.rear)
        XCTAssertEqual(combo.front?.card, "cfront")  // the stored combination is untouched
        XCTAssertNil(combo.without(.front).front)
    }

    func testAnEmptyEndGivesTheDraftTheStartSpot() {
        var d = card(.front)
        d.id = "draft"
        XCTAssertEqual(Combination(id: "k", name: "K").draftPlacement(d, setup: setup()), Placement(card: "draft", x: 917, height: 40))
    }

    func testTheDraftKeepsItsOwnHeightEvenBelowTheClearance() {
        var d = card(.front, rideHeight: 0.01)  // 10 mm: under the 30 mm clearance
        d.id = "draft"
        let at = Combination(id: "k", name: "K").draftPlacement(d, setup: setup())
        XCTAssertEqual(at.height, 10, accuracy: 1e-9)  // its numbers are made there; the box flags it, the car does not move it
    }

    func testTheCarsBoxInTheWingsFrame() {
        let c = card(.front)
        let b = CarRules.wingBox(c, placement: Placement(card: c.id, x: 600, height: 60), setup: setup())
        XCTAssertEqual(b.minX, -0.327, accuracy: 1e-9)
        XCTAssertEqual(b.maxX, 0.373, accuracy: 1e-9)
        XCTAssertEqual(b.minY, -0.033, accuracy: 1e-9)
        XCTAssertEqual(b.maxY, 0.287, accuracy: 1e-9)
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

    func testACardsSectionUndoesItsCarContribution() {
        var w = card(.front).wing
        w.span = 1.2
        w.factor3D = 0.7
        let add = w.carContribution(cl: -1.4, cd: 0.06)
        let back = w.sectionCoefficients(cla: add.cla, cda: add.cda)
        XCTAssertEqual(back.cl, -1.4, accuracy: 1e-12)
        XCTAssertEqual(back.cd, 0.06, accuracy: 1e-12)
        w.endplateHeight = 0.2  // the estimated 3D factor, with induced drag
        if w.finite3D != nil {
            let add3 = w.carContribution(cl: -1.4, cd: 0.06)
            let back3 = w.sectionCoefficients(cla: add3.cla, cda: add3.cda)
            XCTAssertEqual(back3.cl, -1.4, accuracy: 1e-9)
            XCTAssertEqual(back3.cd, 0.06, accuracy: 1e-9)
        }
    }
}
