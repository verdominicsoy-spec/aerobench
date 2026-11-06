import XCTest
import simd
@testable import AeroBenchKit

/// The panel solution's flow off the surface: velocity anywhere and the rough streamlines.
final class PanelFlowTests: XCTestCase {
    private func naca(_ code: String) -> [SIMD2<Double>] { Airfoil.naca4(code)!.coords }

    func testFarFieldIsTheFreestream() throws {
        let r = try XCTUnwrap(PanelSolver(elements: [naca("0012")])).solve(alphaDeg: 5)
        let a = 5 * Double.pi / 180
        let v = r.velocity(at: SIMD2(20, 15))
        XCTAssertEqual(v.x, cos(a), accuracy: 0.01)
        XCTAssertEqual(v.y, sin(a), accuracy: 0.01)
    }

    func testFlowAtTheSurfaceRunsAlongIt() throws {
        let pts = naca("2412")
        let r = try XCTUnwrap(PanelSolver(elements: [pts])).solve(alphaDeg: 4)
        var worst = 0.0
        for j in stride(from: 5, to: pts.count - 6, by: 5) {
            let d = pts[j + 1] - pts[j]
            let n = simd_normalize(SIMD2(d.y, -d.x))  // outward: Selig order runs counter-clockwise
            let v = r.velocity(at: 0.5 * (pts[j] + pts[j + 1]) + 1e-4 * n)
            worst = max(worst, abs(simd_dot(v, n)) / simd_length(v))
        }
        XCTAssertLessThan(worst, 0.05)
        // Inside the body the vortex sheet cancels the freestream.
        XCTAssertLessThan(simd_length(r.velocity(at: SIMD2(0.4, 0.03))), 0.05)
    }

    func testStreamlinesGoRoundNotThrough() throws {
        let pts = naca("0012")
        let r = try XCTUnwrap(PanelSolver(elements: [pts])).solve(alphaDeg: 3)
        let lines = r.streamlines(count: 24)
        XCTAssertEqual(lines.count, 24)
        let body = VortexPanels(r)
        for line in lines {
            XCTAssertFalse(line.contains { body.inside($0) })
            let seed = line[0].y
            if abs(seed) > 0.1 {  // all but the lines into the nose pass the wing, out of the box (x to 1.8, y to 0.56)
                let end = line.last!
                XCTAssertTrue(end.x > 1.75 || abs(end.y) > 0.52, "seeded at y \(seed), ends at \(end)")
            }
        }
    }

    func testStreamlinesStayAboveTheGround() throws {
        var w = Wing(elements: [WingElement(airfoil: Airfoil.naca4("4412")!, chord: 0.3, angle: 4)])
        w.rideHeight = 0.03
        let ge = try XCTUnwrap(w.inGroundEffect)
        let r = try XCTUnwrap(PanelSolver(elements: ge.elements, refChord: 0.3, ground: ge.ground)).solve(alphaDeg: 0)
        // The image holds the flow along the ground.
        for x in stride(from: -0.2, through: 0.5, by: 0.05) {
            XCTAssertEqual(r.velocity(at: SIMD2(x, ge.ground)).y, 0, accuracy: 1e-9)
        }
        let lines = r.streamlines(count: 20)
        XCTAssertFalse(lines.joined().contains { $0.y < ge.ground })
        // Not stopped by it either: the lines reach the far end.
        let through = lines.filter { $0.last!.x > ge.elements[0].map(\.x).max()! + 0.2 }
        XCTAssertGreaterThanOrEqual(through.count, 18)
    }
}
