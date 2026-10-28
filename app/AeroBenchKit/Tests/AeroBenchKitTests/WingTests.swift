import XCTest
import simd
@testable import AeroBenchKit

/// Reference numbers from the engine's wing/panel.py on the same points.
final class PanelSolverTests: XCTestCase {
    private func naca(_ code: String) -> Airfoil { Airfoil.naca4(code)! }

    func testSingleSectionsMatchTheEngine() throws {
        let s0012 = try XCTUnwrap(PanelSolver(elements: [naca("0012").coords]))
        XCTAssertEqual(s0012.solve(alphaDeg: 5).clTotal, 0.6037127882, accuracy: 1e-6)
        XCTAssertEqual(s0012.solve(alphaDeg: 0).clTotal, 0, accuracy: 1e-9)
        let r = try XCTUnwrap(PanelSolver(elements: [naca("2412").coords])).solve(alphaDeg: 0)
        XCTAssertEqual(r.clTotal, 0.2608677840, accuracy: 1e-6)
        XCTAssertEqual(r.cmTotal, -0.0557838567, accuracy: 1e-6)
    }

    private func twoElement(inverted: Bool) -> Wing {
        Wing(elements: [
            WingElement(airfoil: naca("4412"), chord: 1.0, angle: 0, leadingEdge: .zero, inverted: inverted),
            WingElement(airfoil: naca("4412"), chord: 0.35, angle: 20, leadingEdge: SIMD2(0.97, inverted ? 0.05 : -0.05), inverted: inverted),
        ], alpha: inverted ? -4 : 4)
    }

    func testTwoElementsMatchTheEngineUprightAndInverted() throws {
        for inverted in [false, true] {
            let wing = twoElement(inverted: inverted)
            let solver = try XCTUnwrap(PanelSolver(elements: wing.elements.map { $0.placed() }, refChord: wing.refChord))
            let r = solver.solve(alphaDeg: wing.alpha)
            let sign = inverted ? -1.0 : 1.0
            XCTAssertEqual(r.cl[0], sign * 1.8316764781, accuracy: 1e-6)
            XCTAssertEqual(r.cl[1], sign * 0.3521301397, accuracy: 1e-6)
            if !inverted { XCTAssertEqual(r.cmTotal, -0.4099664567, accuracy: 1e-6) }
        }
    }

    func testElementsOnTopOfEachOtherAreRejected() {
        let c = naca("0012").coords
        XCTAssertNil(PanelSolver(elements: [c, c]))
        XCTAssertNil(PanelSolver(elements: [Array(c.prefix(4))]))
    }

    func testFastEnoughToDrag() throws {
        let wing = Wing(elements: [
            WingElement(airfoil: naca("4412"), chord: 1.0),
            WingElement(airfoil: naca("4412"), chord: 0.4, angle: 20, leadingEdge: SIMD2(0.95, 0.06)),
            WingElement(airfoil: naca("4412"), chord: 0.25, angle: 40, leadingEdge: SIMD2(1.3, 0.2)),
        ])
        let start = Date()
        let solver = try XCTUnwrap(PanelSolver(elements: wing.elements.map { $0.placed() }, refChord: wing.refChord))
        _ = solver.solve(alphaDeg: 0)
        // Debug builds are several times slower than the app's release build.
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
}

final class WingGeometryTests: XCTestCase {
    private let section = Airfoil.naca4("4412")!

    func testPlacedStaysCounterClockwiseEitherWayUp() {
        for inverted in [false, true] {
            let pts = WingElement(airfoil: section, chord: 0.3, angle: 10, leadingEdge: SIMD2(1, 2), inverted: inverted).placed()
            var area = 0.0
            for i in 0..<(pts.count - 1) { area += pts[i].x * pts[i + 1].y - pts[i + 1].x * pts[i].y }
            XCTAssertGreaterThan(area, 0)
            XCTAssertEqual(pts[(pts.count - 1) / 2], SIMD2(1, 2))  // the leading edge stays put
        }
    }

    func testAngleOfAttackMeansMoreLoadEitherWayUp() {
        let up = WingElement(airfoil: section, chord: 1, angle: 10, inverted: false)
        let down = WingElement(airfoil: section, chord: 1, angle: 10, inverted: true)
        XCTAssertLessThan(up.trailingEdge.y, 0)    // trailing edge down: more lift
        XCTAssertGreaterThan(down.trailingEdge.y, 0)  // trailing edge up: more downforce
    }

    private func wing() -> Wing {
        Wing(elements: [
            WingElement(airfoil: section, chord: 1.0, angle: 0, inverted: false),
            WingElement(airfoil: section, chord: 0.35, angle: 20, leadingEdge: SIMD2(0.95, -0.06), inverted: false),
        ])
    }

    func testTypingAGapOrOverlapMovesTheFlap() throws {
        var w = wing()
        w.setGap(0.012, of: 1)
        XCTAssertEqual(try XCTUnwrap(w.gap(of: 1)), 0.012, accuracy: 1e-6)
        w.setOverlap(0.03, of: 1)
        XCTAssertEqual(try XCTUnwrap(w.overlap(of: 1)), 0.03, accuracy: 1e-9)
        XCTAssertNil(w.gap(of: 0))
    }

    func testIssues() {
        var w = wing()
        w.setGap(0.012, of: 1)
        XCTAssertTrue(w.issues.isEmpty, "\(w.issues)")
        w.minGap = 0.02
        XCTAssertEqual(w.issues.map(\.kind), [.tooClose])
        w.elements[1].leadingEdge = SIMD2(0.5, 0.0)  // inside the main element
        XCTAssertEqual(w.issues.map(\.kind), [.intersects])
        w = wing()
        w.setGap(0.012, of: 1)
        w.rulesBox = RulesBox(minX: -0.1, minY: -0.5, maxX: 1.1, maxY: 0.5)  // the flap reaches x = 1.28
        XCTAssertEqual(w.issues, [WingIssue(kind: .outsideRules, elements: [1])])
    }

    func testExportAndLapSim() {
        var w = wing()
        w.span = 1.2
        w.factor3D = 0.8
        XCTAssertTrue(w.datFile(of: 0).hasPrefix("NACA 4412 (Main, mm, wing frame)\n1000.1665 1.2489\n"), w.datFile(of: 0))
        XCTAssertEqual(w.csvFile().split(separator: "\n").count, 1 + 2 * section.coords.count)
        let (cla, cda) = w.carContribution(cl: 2.0, cd: 0.05)
        XCTAssertEqual(cla, -2.0 * 1.2 * 1.35 * 0.8, accuracy: 1e-12)  // an upright wing's lift is negative downforce
        XCTAssertEqual(cda, 0.05 * 1.2 * 1.35 * 0.8, accuracy: 1e-12)
        XCTAssertEqual(w.carContribution(cl: -2.0, cd: 0.05).cla, 2.0 * 1.2 * 1.35 * 0.8, accuracy: 1e-12)
    }

    func testWingRoundTrips() throws {
        let w = wing()
        let data = try JSONEncoder().encode(w)
        XCTAssertEqual(try JSONDecoder().decode(Wing.self, from: data), w)
        let old = try JSONDecoder().decode(Wing.self, from: Data(#"{"elements": []}"#.utf8))
        XCTAssertEqual(old.span, 1.0)
    }
}

final class WingPolarTests: XCTestCase {
    func testDecodesTheEngineResult() throws {
        let file = #"""
        {"data": {"re": 500000.0, "n_crit": 9.0, "inverted": true, "rows": [
          {"alpha": 2.0, "cl": -0.6, "cd": 0.008, "cm": 0.1, "transition_suction": 0.4, "transition_pressure": 1.0, "confidence": 0.97, "trusted": true},
          {"alpha": 4.0, "cl": -0.8, "cd": 0.010, "cm": 0.1, "transition_suction": 0.2, "transition_pressure": 1.0, "confidence": 0.6, "trusted": false}]}}
        """#
        let polar = try WingPolar.decode(resultFile: Data(file.utf8))
        XCTAssertEqual(polar.rows.count, 2)
        XCTAssertEqual(polar.rows[1].trusted, false)
        XCTAssertEqual(polar.rows[0].liftToDrag, 75, accuracy: 1e-9)
        XCTAssertEqual(polar.row(near: 3.4)?.alpha, 4)
        XCTAssertNil(polar.row(near: 20))
        XCTAssertEqual(Wing(speed: 20).reynolds(chord: 0.3), 1.225 * 20 * 0.3 / 1.81e-5, accuracy: 1e-6)
    }
}

final class WingRansResultTests: XCTestCase {
    func testDecodesTheEngineResult() throws {
        let file = #"""
        {"data": {"re": 1000000.0, "mesh": {"file": "wing.su2", "cells": 70000, "triangles": 33000, "quads": 37000,
          "first_cell_height_m": 3.1e-05, "layer_thickness_m": 0.015, "layers": 31, "min_gap_m": 0.0388,
          "surface_nodes": [530, 419], "min_quality": 0.02, "bad_cells": 0},
         "mesh_level": "medium", "transition": [[0.3, 0.6], [0.1, 0.4]], "model": "sst-lm",
         "model_name": "SST with Langtry-Menter transition", "iterations": 1800, "converged": false,
         "residual_drop": 3.2, "cl_change": 0.001, "cd_change": 0.0001, "reason": "residual fell 3.2 orders, needs 4.0",
         "cl": 2.1, "cd": 0.031, "cm": -0.4, "elements": [{"marker": "wall_0", "cl": 1.7, "cd": 0.02, "cmz": -0.3},
          {"marker": "wall_1", "cl": 0.4, "cd": 0.011, "cmz": -0.1}],
         "surface": [{"x": [0, 0.5, 1], "y": [0, 0.05, 0], "cp": [1, -1, 0.2]}], "field": "flow.vtu",
         "cfl": 10.0, "attempts": [{"cfl": 25.0, "outcome": "diverged at iteration 60"}, {"cfl": 10.0, "outcome": "finished"}]}}
        """#
        let r = try WingRansResult.decode(resultFile: Data(file.utf8))
        XCTAssertFalse(r.converged)
        XCTAssertEqual(r.elements.map(\.marker), ["wall_0", "wall_1"])
        XCTAssertEqual(r.mesh.layers, 31)
        XCTAssertEqual(r.attempts?.first?.outcome, "diverged at iteration 60")
        XCTAssertEqual(r.liftToDrag, 2.1 / 0.031, accuracy: 1e-9)
    }
}
