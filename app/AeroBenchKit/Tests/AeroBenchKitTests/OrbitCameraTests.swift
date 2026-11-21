import XCTest
import simd
@testable import AeroBench3D

final class OrbitCameraTests: XCTestCase {
    let aspect = 1.6

    private func camera(ortho: Bool) -> OrbitCamera {
        var c = OrbitCamera(orthographic: ortho)
        c.frame(center: [0.5, 0.2, 0.3], radius: 1.2, direction: [-1, -1, 0.8], up: [0, 0, 1], aspect: aspect)
        return c
    }

    func testZoomKeepsThePointUnderTheCursorFixed() {
        for ortho in [false, true] {
            var c = camera(ortho: ortho)
            let p = c.pointOnTargetPlane(ndc: [0.6, -0.4], aspect: aspect)
            let before = c.project(p, aspect: aspect)
            c.zoom(factor: 0.5, about: p)
            let after = c.project(p, aspect: aspect)
            XCTAssertEqual(before.x, after.x, accuracy: 1e-9, "ortho \(ortho)")
            XCTAssertEqual(before.y, after.y, accuracy: 1e-9, "ortho \(ortho)")
        }
    }

    func testZoomCanGetArbitrarilyClose() {
        var c = camera(ortho: false)
        let p = SIMD3<Double>(0.9, 0.1, 0.2)
        let start = simd_distance(c.position, p)
        for _ in 0..<60 { c.zoom(factor: 0.8, about: p) }
        XCTAssertLessThan(simd_distance(c.position, p), start * 1e-4)
        XCTAssertGreaterThan(c.distance, 0)
    }

    func testPanMovesContentWithTheCursor() {
        for ortho in [false, true] {
            var c = camera(ortho: ortho)
            let h = 600.0
            let p = c.target
            let before = c.project(p, aspect: aspect)
            c.pan(dx: 30, dy: -20, viewHeight: h)
            let after = c.project(p, aspect: aspect)
            // 30 points right is 30 / (h/2) in NDC height units, divided by aspect for x.
            XCTAssertEqual(after.x - before.x, 30 / (h / 2) / aspect, accuracy: 1e-9)
            XCTAssertEqual(after.y - before.y, -20 / (h / 2), accuracy: 1e-9)
        }
    }

    func testOrbitAboutAPivotKeepsThePivotOnScreen() {
        var c = camera(ortho: false)
        let pivot = SIMD3<Double>(0.8, -0.1, 0.25)
        let before = c.project(pivot, aspect: aspect)
        c.orbit(dx: 40, dy: 15, about: pivot)
        let after = c.project(pivot, aspect: aspect)
        XCTAssertEqual(before.x, after.x, accuracy: 1e-9)
        XCTAssertEqual(before.y, after.y, accuracy: 1e-9)
        XCTAssertEqual(simd_distance(c.position, pivot), simd_distance(camera(ortho: false).position, pivot), accuracy: 1e-9)
    }

    /// A pivot picked under the cursor off the view centre (as on mouse-down)
    /// stays under the cursor through a whole drag, in both projections.
    func testOrbitAboutAClickedPointKeepsItUnderTheCursor() {
        for ortho in [false, true] {
            var c = camera(ortho: ortho)
            let cursor = SIMD2<Double>(-0.55, 0.35)
            let pivot = c.pointOnTargetPlane(ndc: cursor, aspect: aspect) + c.forward * 0.3
            let before = c.project(pivot, aspect: aspect)
            for step in 0..<20 { c.orbit(dx: 12, dy: step < 10 ? 6 : -9, about: pivot) }
            let after = c.project(pivot, aspect: aspect)
            XCTAssertEqual(before.x, after.x, accuracy: 1e-9, "ortho \(ortho)")
            XCTAssertEqual(before.y, after.y, accuracy: 1e-9, "ortho \(ortho)")
            XCTAssertNotEqual(c.target, camera(ortho: ortho).target, "the view turned about the pivot, not the target")
        }
    }

    func testMouseWheelZoomsAndTrackpadScrollPans() {
        // Trackpad two-finger scroll: precise deltas with a gesture or momentum phase.
        XCTAssertTrue(OrbitSCNView.scrollPans(precise: true, phase: .began, momentumPhase: [], command: false))
        XCTAssertTrue(OrbitSCNView.scrollPans(precise: true, phase: .changed, momentumPhase: [], command: false))
        XCTAssertTrue(OrbitSCNView.scrollPans(precise: true, phase: [], momentumPhase: .changed, command: false))
        // Command-scroll on a trackpad zooms.
        XCTAssertFalse(OrbitSCNView.scrollPans(precise: true, phase: .changed, momentumPhase: [], command: true))
        // A mouse wheel: line deltas, no phase.
        XCTAssertFalse(OrbitSCNView.scrollPans(precise: false, phase: [], momentumPhase: [], command: false))
        // A smooth-scrolling mouse: precise deltas but no phase.
        XCTAssertFalse(OrbitSCNView.scrollPans(precise: true, phase: [], momentumPhase: [], command: false))
    }

    func testOptionDragPansShiftDragOrbits() {
        XCTAssertTrue(OrbitSCNView.dragPans(.option))
        XCTAssertFalse(OrbitSCNView.dragPans(.shift))
        XCTAssertFalse(OrbitSCNView.dragPans([]))
    }

    func testPeekNeedsShiftAlone() {
        XCTAssertTrue(OrbitSCNView.peekHeld(.shift))
        XCTAssertTrue(OrbitSCNView.peekHeld([.shift, .capsLock]))  // caps lock is not a chord
        XCTAssertFalse(OrbitSCNView.peekHeld([.shift, .command]))
        XCTAssertFalse(OrbitSCNView.peekHeld([.shift, .option]))
        XCTAssertFalse(OrbitSCNView.peekHeld([]))
    }

    func testViewKeys() {
        // 1-7 in the toolbar's order, F to fit; anything else goes on to the app.
        XCTAssertEqual(OrbitSCNView.viewKey("1"), .view(.front))
        XCTAssertEqual(OrbitSCNView.viewKey("7"), .view(.iso))
        XCTAssertEqual(OrbitSCNView.viewKey("f"), .fit)
        XCTAssertEqual(OrbitSCNView.viewKey("F"), .fit)
        XCTAssertNil(OrbitSCNView.viewKey("8"))
        XCTAssertNil(OrbitSCNView.viewKey("x"))
        XCTAssertNil(OrbitSCNView.viewKey(""))
    }

    func testOrbitNeverFlipsOverTheTop() {
        var c = camera(ortho: false)
        for _ in 0..<200 { c.orbit(dx: 0, dy: -50) }
        XCTAssertGreaterThan(simd_dot(c.up, c.worldUp), -1e-9)
        XCTAssertFalse(c.position.x.isNaN)
    }

    func testTopViewHasAUsableScreenUp() {
        var c = OrbitCamera()
        c.frame(center: .zero, radius: 1, direction: [0, 0, 1], up: [1, 0, 0], aspect: aspect)
        XCTAssertEqual(c.screenUp, [1, 0, 0])
        XCTAssertFalse(c.right.x.isNaN)
        c.orbit(dx: 0, dy: 30)  // tip away from straight down
        XCTAssertLessThan(abs(simd_dot(c.forward, [0, 0, 1])), 0.9999)
    }

    func testFramingFitsTheSphere() {
        let c = camera(ortho: false)
        // The sphere's silhouette must sit inside the view.
        let edge = c.target + c.up * 1.2
        XCTAssertLessThan(abs(c.project(edge, aspect: aspect).y), 1)
    }

    func testLensChangeKeepsTheFraming() {
        // A narrower lens moves the camera back so the target plane shows the same area.
        var c = OrbitCamera()
        c.frame(center: [0.5, 0.2, 0.3], radius: 1.2, direction: [-1, -1, 0.8], up: [0, 0, 1], aspect: 1.6)
        let lens = 17 * Double.pi / 180
        let n = c.withFovY(lens)
        XCTAssertEqual(n.fovY, lens)
        XCTAssertEqual(n.distance * tan(lens / 2), c.distance * tan(c.fovY / 2), accuracy: 1e-9)
        XCTAssertEqual(simd_distance(n.target, c.target), 0, accuracy: 1e-12)
        XCTAssertEqual(simd_distance(n.forward, c.forward), 0, accuracy: 1e-12)
        // Orthographic: the lens does not change what is shown, so the camera stays.
        var o = c
        o.orthographic = true
        XCTAssertEqual(o.withFovY(lens).position, o.position)
    }
}
