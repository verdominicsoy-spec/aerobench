import XCTest
import simd
@testable import AeroBenchKit

/// The live colour field from the panel method, and the wakes that give it Cp0.
final class PanelFieldTests: XCTestCase {
    private func naca(_ code: String) -> [SIMD2<Double>] { Airfoil.naca4(code)!.coords }

    func testInviscidFieldHasNoTotalPressureAndReadsTheFlow() throws {
        let r = try XCTUnwrap(PanelSolver(elements: [naca("0012")])).solve(alphaDeg: 0)
        let f = try XCTUnwrap(r.field(nx: 400))
        XCTAssertEqual(f.scalars.map(\.key), ["cp", "speed"])  // no drag given, so no Cp0
        // Far ahead: the free stream. At the nose: near stagnation. Inside: no flow.
        XCTAssertEqual(try XCTUnwrap(f.value("cp", at: SIMD2(-0.28, 0.35))), 0, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(f.value("speed", at: SIMD2(-0.28, 0.35))), 1, accuracy: 0.05)
        XCTAssertGreaterThan(try XCTUnwrap(f.value("cp", at: SIMD2(-0.01, 0))), 0.7)
        XCTAssertNil(f.value("cp", at: SIMD2(0.3, 0)))
        XCTAssertEqual(f.scalars[0].range[0], -f.scalars[0].range[1])  // Cp's zero mid-colormap
    }

    func testWakeCarriesTheElementsDrag() throws {
        let pts = naca("0012")
        let r = try XCTUnwrap(PanelSolver(elements: [pts])).solve(alphaDeg: 0)
        let cd = 0.012, theta = 0.5 * cd  // unit chord
        let box = (x0: -0.3, y0: -0.4, x1: 1.8, y1: 0.4)
        let wake = try XCTUnwrap(Wake(body: pts, cd: cd, panels: VortexPanels(r), box: box))
        // Across the wake at x = 1.5: the momentum deficit is the drag's.
        var integral = 0.0
        let dn = 1e-4
        for y in stride(from: -0.1, through: 0.1, by: dn) {
            let d = wake.deficit(at: SIMD2(1.5, y))
            integral += (1 - d) * d * dn
        }
        XCTAssertEqual(integral, theta, accuracy: 0.03 * theta)
        XCTAssertEqual(wake.deficit(at: SIMD2(-0.2, 0)), 0)  // nothing ahead of the wing
        XCTAssertEqual(wake.deficit(at: SIMD2(1.5, 0.2)), 0, accuracy: 1e-6)

        let f = try XCTUnwrap(r.field(nx: 160, wakeCd: [cd]))
        let cp0 = try XCTUnwrap(f.scalars.first { $0.key == "cp0" })
        XCTAssertEqual(cp0.range[1], 0)
        XCTAssertEqual(try XCTUnwrap(f.value("cp0", at: SIMD2(-0.2, 0.2))), 0, accuracy: 1e-6)
        XCTAssertLessThan(try XCTUnwrap(f.value("cp0", at: SIMD2(1.2, 0))), -0.05)
    }

    /// The loss grows along each surface from nothing at the nose into the
    /// wake: no step at the trailing edge (it showed as a hard straight edge).
    func testLossGrowsAlongTheSurfaceIntoTheWake() throws {
        let pts = naca("0012")
        let r = try XCTUnwrap(PanelSolver(elements: [pts])).solve(alphaDeg: 0)
        let box = (x0: -0.3, y0: -0.4, x1: 1.8, y1: 0.4)
        let wake = try XCTUnwrap(Wake(body: pts, cd: 0.012, panels: VortexPanels(r), box: box))
        // Across the trailing edge in 1 mm steps, at and off its centreline: no jump.
        for off in [0.0, 0.002, 0.004] {
            let xs = stride(from: 0.97, through: 1.03, by: 0.001).map { SIMD2($0, off) }
            let line = xs.map { Wing.inside($0, pts) ? Double.nan : wake.deficit(at: $0) }  // no flow inside
            let jump = zip(line, line.dropFirst()).compactMap { $0.isNaN || $1.isNaN ? nil : abs($1 - $0) }.max() ?? 0
            XCTAssertLessThan(jump, 0.08, "at \(off): \(line.map { String(format: "%.2f", $0) })")
            XCTAssertGreaterThan(line.filter { !$0.isNaN }.max() ?? 0, 0.1)
        }
        // Thin near the nose, thicker towards the trailing edge, at the same height off the surface.
        func above(_ x: Double) -> Double {
            let t = 0.6 * (0.2969 * x.squareRoot() - 0.126 * x - 0.3516 * x * x + 0.2843 * x * x * x - 0.1015 * x * x * x * x)
            return wake.deficit(at: SIMD2(x, t + 0.002))
        }
        XCTAssertLessThan(above(0.05), above(0.5))
        XCTAssertLessThan(above(0.5), above(0.95))
        XCTAssertLessThan(above(0.05), 0.05)
    }

    /// The suction side (the faster one) carries the thicker layer: an upright
    /// cambered section's upper side, an inverted one's lower side.
    /// A boundary layer's loss hugs the wall: stopped there, nearly gone one θ out
    /// (RANS of a two-element wing: 2 mm to half loss at 60% chord, where it drew 12).
    func testTheSurfaceLayerHugsTheWall() throws {
        let pts = naca("0012")
        let r = try XCTUnwrap(PanelSolver(elements: [pts])).solve(alphaDeg: 0)
        let box = (x0: -0.3, y0: -0.4, x1: 1.8, y1: 0.4)
        let theta = 0.006
        let wake = try XCTUnwrap(Wake(body: pts, cd: 2 * theta, panels: VortexPanels(r), box: box))
        let top = try XCTUnwrap(pts.filter { $0.x > 0.55 && $0.x < 0.65 }.max { $0.y < $1.y })
        XCTAssertGreaterThan(wake.deficit(at: top + SIMD2(0, 0.0002)), 0.8)
        XCTAssertLessThan(wake.deficit(at: top + SIMD2(0, theta)), 0.05)
    }

    func testTheSuctionSideHasTheThickerLayer() throws {
        let box = (x0: -0.3, y0: -0.4, x1: 1.8, y1: 0.4)
        for inverted in [false, true] {
            let pts = WingElement(airfoil: Airfoil.naca4("4412")!, chord: 1, angle: 4, inverted: inverted).placed()
            let r = try XCTUnwrap(PanelSolver(elements: [pts])).solve(alphaDeg: 0)
            let wake = try XCTUnwrap(Wake(body: pts, cd: 0.02, panels: VortexPanels(r), box: box, speed: r.speed[0]))
            // 6 mm off each surface at 80% chord.
            let up = try XCTUnwrap(pts.filter { $0.x > 0.7 && $0.x < 0.9 }.max { $0.y < $1.y })
            let down = try XCTUnwrap(pts.filter { $0.x > 0.7 && $0.x < 0.9 }.min { $0.y < $1.y })
            let above = wake.deficit(at: up + SIMD2(0, 0.006)), below = wake.deficit(at: down - SIMD2(0, 0.006))
            if inverted { XCTAssertGreaterThan(below, above) } else { XCTAssertGreaterThan(above, below) }
        }
    }

    func testMainWakeSlidesPastTheFlap() throws {
        // A flap tucked under the main's trailing edge: the main's wake must go on past it.
        let main = WingElement(airfoil: Airfoil.naca4("4412")!, chord: 0.3, angle: 0)
        var flap = WingElement(airfoil: Airfoil.naca4("4412")!, chord: 0.135, angle: 18)
        flap.leadingEdge = main.trailingEdge + SIMD2(-0.015, -0.012)
        let placed = Wing(elements: [main, flap]).elements.map { $0.placed() }
        let r = try XCTUnwrap(PanelSolver(elements: placed, refChord: 0.3)).solve(alphaDeg: 0)
        let box = (x0: -0.3, y0: -0.4, x1: 1.2, y1: 0.4)
        let wake = try XCTUnwrap(Wake(body: placed[0], cd: 0.02, panels: VortexPanels(r), box: box))
        XCTAssertGreaterThan(wake.end.x, 1.1, "the main's wake stopped at \(wake.end)")
        // Beyond where a wake ends there is no deficit, so no disc round its end.
        let short = try XCTUnwrap(Wake(body: placed[0], cd: 0.02, panels: VortexPanels(r), box: (x0: -0.3, y0: -0.4, x1: 0.5, y1: 0.4)))
        XCTAssertEqual(short.deficit(at: short.end + SIMD2(0.05, 0)), 0)
    }

    func testFieldStopsWhenCancelled() throws {
        let r = try XCTUnwrap(PanelSolver(elements: [naca("2412")])).solve(alphaDeg: 4)
        XCTAssertNil(r.field(nx: 120, isCancelled: { true }))
    }

    func testFieldIsQuick() throws {
        // A main and a flap, the field at the canvas's size.
        let main = WingElement(airfoil: Airfoil.naca4("4412")!, chord: 0.3, angle: 0)
        var flap = WingElement(airfoil: Airfoil.naca4("4412")!, chord: 0.12, angle: 20)
        flap.leadingEdge = SIMD2(0.29, -0.02)
        let w = Wing(elements: [main, flap])
        let r = try XCTUnwrap(PanelSolver(elements: w.elements.map { $0.placed() }, refChord: 0.3)).solve(alphaDeg: 2)
        let start = Date()
        let f = try XCTUnwrap(r.field(wakeCd: [0.01, 0.02]))
        let ms = Date().timeIntervalSince(start) * 1000
        print("live field \(f.nx) x \(f.ny): \(Int(ms)) ms")
        XCTAssertEqual(f.scalars.count, 3)
        XCTAssertLessThan(ms, 10000)  // a debug build; about 20 ms in the release app
    }
}
