import XCTest
import simd
@testable import AeroBenchKit

/// The live colour field from the panel method, and the wakes that give it Cp0.
final class PanelFieldTests: XCTestCase {
    private func naca(_ code: String) -> [SIMD2<Double>] { Airfoil.naca4(code)!.coords }

    func testInviscidFieldHasNoTotalPressureAndReadsTheFlow() throws {
        let r = try XCTUnwrap(PanelSolver(elements: [naca("0012")])).solve(alphaDeg: 0)
        let f = try XCTUnwrap(r.field(nx: 120))
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
        XCTAssertLessThan(ms, 2000)  // debug build; the release app is several times quicker
    }
}
