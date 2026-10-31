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

final class WingStudyTests: XCTestCase {
    /// The engine's optimiser places wings with its own copy of the geometry
    /// rules; these numbers come from it (tests/test_wing_optimise.py's starter wing).
    func testGeometryMatchesTheEngine() {
        let s = Airfoil.naca4("4412")!
        var w = Wing(elements: [
            WingElement(airfoil: s, chord: 0.30, angle: 3, leadingEdge: .zero, inverted: true),
            WingElement(airfoil: s, chord: 0.14, angle: 25, leadingEdge: SIMD2(0.27, 0.025), inverted: true),
        ])
        w.setGap(0.012, of: 1)
        XCTAssertEqual(w.elements[1].leadingEdge.x, 0.26931802154426326, accuracy: 1e-10)
        XCTAssertEqual(w.elements[1].leadingEdge.y, 0.027569751457336252, accuracy: 1e-10)
        XCTAssertEqual(w.overlap(of: 1)!, 0.029608180138330043, accuracy: 1e-10)
    }

    private let export = #"""
    {"study": "s", "objective": "max_cl", "objective_name": "Most downforce (lift, upright)", "direction": "maximize",
     "spec": {"variables": [{"element": 1, "kind": "angle", "low": 15, "high": 60}, {"element": 1, "kind": "gap", "low": 0.003, "high": 0.02}], "objective": "max_cl", "cd_cap": null, "cl_target": null, "sampler": "tpe"},
     "info": null,
     "trials": [
      {"number": 0, "state": "complete", "value": 2.25, "params": {"angle_1": 25.0, "gap_1": 0.012}, "cl": -2.25, "cd": 0.05, "cm": -0.2, "load": 2.25, "element_cl": [-1.35, -0.9], "feasible": true, "converged": true, "reason": null, "placement": [{"angle": 3.0, "leading_edge": [0.0, 0.0]}, {"angle": 25.0, "leading_edge": [0.2693, 0.0276]}], "gaps": [0.012], "overlaps": [0.0296], "seconds": 0.0, "iterations": null, "cells": 1},
      {"number": 1, "state": "complete", "value": 1.7, "params": {"angle_1": 33.8, "gap_1": 0.0152}, "cl": -1.7, "cd": 0.04, "cm": -0.2, "load": 1.7, "element_cl": [-1.02, -0.68], "feasible": true, "converged": true, "reason": null, "placement": [{"angle": 3.0, "leading_edge": [0.0, 0.0]}, {"angle": 33.8, "leading_edge": [0.2693, 0.0270]}], "gaps": [0.0152], "overlaps": [0.0296], "seconds": 0.0, "iterations": null, "cells": 1},
      {"number": 2, "state": "fail", "value": null, "params": {"angle_1": 15.0, "gap_1": 0.0081}, "cl": null, "cd": null, "cm": null, "load": null, "element_cl": null, "feasible": null, "converged": null, "reason": "SU2 diverged at every CFL tried", "placement": null, "gaps": null, "overlaps": null, "seconds": 0.0, "iterations": null, "cells": null},
      {"number": 3, "state": "complete", "value": 2.4, "params": {"angle_1": 29.0, "gap_1": 0.011}, "cl": -2.4, "cd": 0.06, "cm": -0.2, "load": 2.4, "element_cl": [-1.4, -1.0], "feasible": true, "converged": true, "reason": null, "placement": null, "gaps": null, "overlaps": null, "seconds": 0.0, "iterations": null, "cells": 1},
      {"number": 4, "state": "complete", "value": 1.6, "params": {"angle_1": 40.0, "gap_1": 0.018}, "cl": -1.6, "cd": 0.065, "cm": -0.2, "load": 1.6, "element_cl": [-1.0, -0.6], "feasible": true, "converged": true, "reason": null, "placement": null, "gaps": null, "overlaps": null, "seconds": 0.0, "iterations": null, "cells": 1}],
     "best": 3, "complete": 4, "failed": 1, "invalid": 0, "target": 5}
    """#

    func testDecodesTheEngineExport() throws {
        let s = try WingStudy.decode(exportFile: Data(export.utf8))
        XCTAssertEqual(s.trials.count, 5)
        XCTAssertEqual(s.trials[0].params["angle_1"], 25)  // keys kept as the engine wrote them
        XCTAssertEqual(s.spec.variables.map(\.name), ["angle_1", "gap_1"])
        XCTAssertEqual(s.bestTrial?.number, 3)
        XCTAssertEqual(s.trials[2].reason, "SU2 diverged at every CFL tried")
        XCTAssertEqual(s.trials[0].elementCl?.count, 2)
    }

    func testBestSoFarAndParetoFront() throws {
        let s = try WingStudy.decode(exportFile: Data(export.utf8))
        XCTAssertEqual(s.bestSoFar.map { $0.trial }, [0, 1, 3, 4])
        XCTAssertEqual(s.bestSoFar.map { $0.value }, [2.25, 2.25, 2.4, 2.4])
        // Trial 4 is beaten by 0 on both counts; 1 has the least drag, 3 the most downforce.
        XCTAssertEqual(s.paretoFront.map(\.number), [1, 0, 3])
    }

    func testLoadingATrialOntoTheCanvas() throws {
        let s = try WingStudy.decode(exportFile: Data(export.utf8))
        let a = Airfoil.naca4("4412")!
        let w = Wing(elements: [WingElement(airfoil: a, chord: 0.3), WingElement(airfoil: a, chord: 0.14)])
        let loaded = try XCTUnwrap(w.applying(s.trials[1]))
        XCTAssertEqual(loaded.elements[1].angle, 33.8)
        XCTAssertEqual(loaded.elements[1].leadingEdge, SIMD2(0.2693, 0.0270))
        XCTAssertNil(w.applying(s.trials[3]))  // no placement recorded
        XCTAssertNil(Wing(elements: [w.elements[0]]).applying(s.trials[1]))  // different element count
    }
}

final class WingFieldTests: XCTestCase {
    /// 3 x 2 grid over x 0..3, y 0..2, one scalar: bottom row 0, 1, 2; top row NaN, 4, 5.
    private func field() throws -> WingField {
        let json = #"""
        {"nx": 3, "ny": 2, "window": [0, 0, 3, 2], "v_inf": 1.0, "streamlines": [[[0, 0.5], [3, 0.5]]],
         "scalars": [{"key": "cp", "name": "Cp", "min": 0, "max": 5, "range": [0, 5], "colormap": [[0, 0, 0], [1, 1, 1]]}]}
        """#
        var bin = Data()
        for v: Float in [0, 1, 2, .nan, 4, 5] { withUnsafeBytes(of: v.bitPattern.littleEndian) { bin.append(contentsOf: $0) } }
        return try WingField(json: Data(json.utf8), binary: bin)
    }

    func testValuesAndStreamlines() throws {
        let f = try field()
        XCTAssertEqual(f.value("cp", at: SIMD2(1.5, 0.5)), 1)
        XCTAssertEqual(f.value("cp", at: SIMD2(2.5, 1.5)), 5)
        XCTAssertNil(f.value("cp", at: SIMD2(0.5, 1.5)))  // no flow there
        XCTAssertNil(f.value("cp", at: SIMD2(5, 1)))  // outside the window
        XCTAssertNil(f.value("speed", at: SIMD2(1, 1)))
        XCTAssertEqual(f.streamlines, [[SIMD2(0, 0.5), SIMD2(3, 0.5)]])
    }

    func testPixelsAreFlippedAndTransparentWithoutFlow() throws {
        let px = try field().pixels("cp")
        XCTAssertEqual(px.count, 3 * 2 * 4)
        XCTAssertEqual(Array(px[0..<4]), [0, 0, 0, 0])  // top-left is the NaN: transparent
        XCTAssertEqual(Array(px[8..<12]), [255, 255, 255, 255])  // top-right is 5: the top of the range
        XCTAssertEqual(Array(px[12..<16]), [0, 0, 0, 255])  // bottom-left is 0
    }

    func testRejectsAShortBinary() {
        let json = #"{"nx": 3, "ny": 2, "window": [0, 0, 3, 2], "streamlines": [], "scalars": [{"key": "cp", "name": "Cp", "min": 0, "max": 1, "range": [0, 1], "colormap": []}]}"#
        XCTAssertThrowsError(try WingField(json: Data(json.utf8), binary: Data(count: 8)))
    }
}

final class WingSweepTests: XCTestCase {
    func testAngles() {
        XCTAssertEqual(WingSweep.angles(from: -4, to: 4, step: 2), [-4, -2, 0, 2, 4])
        XCTAssertEqual(WingSweep.angles(from: 4, to: -4, step: -2), [-4, -2, 0, 2, 4])
        XCTAssertEqual(WingSweep.angles(from: 0, to: 20, step: 1, limit: 5).count, 5)
        XCTAssertEqual(WingSweep.angles(from: 0, to: 1, step: 0.5), [0, 0.5, 1])
    }

    func testDecodesTheEngineResult() throws {
        let row = #"{"alpha": -2.0, "folder": "a-2", "seconds": 61.5, "re": 450000, "mesh": {"cells": 32322, "triangles": 15443, "quads": 16879, "layers": 20, "first_cell_height_m": 1e-5, "layer_thickness_m": 0.004}, "mesh_level": "quick", "transition": [[0.1, 0.2]], "model": "sa", "model_name": "Spalart-Allmaras", "iterations": 900, "converged": true, "residual_drop": 5.1, "cl": -2.05, "cd": 0.045, "elements": [], "surface": [], "field_view": "field.json"}"#
        let json = #"{"data": {"rows": [\#(row)], "skipped": [4.0], "seconds": 290.2, "time_limit": 300}}"#
        let s = try WingSweep.decode(resultFile: Data(json.utf8))
        XCTAssertEqual(s.rows.count, 1)
        XCTAssertEqual(s.rows[0].alpha, -2)
        XCTAssertEqual(s.rows[0].folder, "a-2")
        XCTAssertEqual(s.rows[0].fieldView, "field.json")
        XCTAssertEqual(s.skipped, [4])
        XCTAssertEqual(s.timeLimit, 300)
    }
}

final class WingEstimateTests: XCTestCase {
    func testDecodesTheEngineResult() throws {
        let el = #"{"cl": -1.4478, "cd": 0.0287, "cm": -0.1, "cl_own": -2.123, "cd_own": 0.042, "cl_inviscid_own": -2.409, "effective_angle": 15.6, "upwash": -12.6, "transition_suction": 0.05, "transition_pressure": 0.6, "confidence": 0.99, "trusted": true, "held_below_stall": true}"#
        let json = #"{"data": {"ref_chord": 0.44, "re": [304000, 142000], "rows": [{"alpha": -2.0, "cl": -2.0, "cd": 0.04, "trusted": true, "elements": [\#(el)]}, {"alpha": 0.0, "cl": -1.87, "cd": 0.039, "trusted": false, "elements": [\#(el)]}]}}"#
        let e = try WingEstimate.decode(resultFile: Data(json.utf8))
        XCTAssertEqual(e.rows.count, 2)
        XCTAssertEqual(e.rows[0].elements[0].heldBelowStall, true)
        XCTAssertEqual(e.rows[0].elements[0].clInviscidOwn, -2.409)
        XCTAssertEqual(e.row(nearest: 0.4)?.alpha, 0)
        XCTAssertEqual(e.refChord, 0.44)
        XCTAssertNil(e.rows[0].elements[0].separationAngle)
    }

    func testDecodesTheLastElementsSeparationLine() throws {
        let el = #"{"cl": -0.4, "cd": 0.01, "cm": -0.1, "cl_own": -1.2, "cd_own": 0.03, "cl_inviscid_own": -1.5, "effective_angle": 14.6, "upwash": -12.3, "transition_suction": 0.05, "transition_pressure": 0.6, "confidence": 0.99, "trusted": true, "held_below_stall": false, "stall_angle": 15.0, "past_stall": false, "separation_angle": 15.59, "gap_ratio": 0.0303}"#
        let json = #"{"data": {"ref_chord": 0.44, "re": [304000], "rows": [{"alpha": 0.0, "cl": -1.9, "cd": 0.04, "trusted": true, "separating": false, "elements": [\#(el)]}]}}"#
        let last = try XCTUnwrap(WingEstimate.decode(resultFile: Data(json.utf8)).rows.first?.elements.first)
        XCTAssertEqual(last.separationAngle, 15.59)
        XCTAssertEqual(last.gapRatio, 0.0303)
    }
}

final class WingStudyCheckTests: XCTestCase {
    func testDecodesChecksAndPicksRANSsBest() throws {
        let json = #"""
        {"study": "s", "objective": "max_cl", "objective_name": "Most downforce", "direction": "maximize",
         "spec": {"variables": [], "objective": "max_cl", "cd_cap": null, "cl_target": null, "sampler": "tpe", "solver": "estimate"},
         "trials": [], "best": null, "complete": 0, "failed": 0, "invalid": 0, "target": 200, "solver": "estimate",
         "checks": [{"number": 4, "estimate_value": 1.95, "cl": -1.80, "cd": 0.05, "load": 1.80, "value": 1.80, "feasible": true, "converged": true, "reason": null},
                    {"number": 9, "estimate_value": 1.94, "cl": -1.90, "cd": 0.04, "load": 1.90, "value": 1.90, "feasible": true, "converged": true, "reason": null},
                    {"number": 2, "estimate_value": 1.93, "converged": false, "reason": "not converged"}]}
        """#
        let s = try WingStudy.decode(exportFile: Data(json.utf8))
        XCTAssertEqual(s.solver, "estimate")
        XCTAssertEqual(s.checks?.count, 3)
        XCTAssertEqual(s.checks?[0].estimateValue, 1.95)
        XCTAssertEqual(s.bestCheck?.number, 9)  // RANS disagrees with the estimate's order
        XCTAssertNil(s.checks?[2].value)
    }
}

final class LibraryPolarsTests: XCTestCase {
    func testDecodesAndSortsHighestFirst() throws {
        let json = """
        {"re": 300000.0, "n_crit": 9.0, "alphas": [-4, 24], "rows": {
          "naca/0012": {"cl_max": 1.19, "alpha_cl_max": 13, "ld_max": 52.3, "alpha_ld_max": 6, "cl_at_ld_max": 0.71, "cd_min": 0.0078, "trusted": true},
          "naca/4412": {"cl_max": 1.44, "alpha_cl_max": 17, "ld_max": 91.2, "alpha_ld_max": 7, "cl_at_ld_max": 1.2, "cd_min": 0.0085, "trusted": true},
          "naca/6412": {"cl_max": 1.60, "alpha_cl_max": 10, "ld_max": 96.8, "alpha_ld_max": 7, "cl_at_ld_max": 1.42, "cd_min": 0.0099, "trusted": false}}}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("polars-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let polars = try XCTUnwrap(AirfoilLibrary.Polars.load(url))
        XCTAssertEqual(polars.re, 3e5)
        XCTAssertEqual(polars.rows["naca/4412"]?.alphaClMax, 17)
        XCTAssertEqual(polars.rows["naca/6412"]?.trusted, false)

        let library = ["0012", "2412", "4412", "6412"].compactMap { Airfoil.naca4($0) }
        XCTAssertEqual(library.count, 4)
        XCTAssertEqual(AirfoilLibrary.sorted(library, by: .clMax, polars: polars).map(\.key),
                       ["naca/6412", "naca/4412", "naca/0012", "naca/2412"])  // no polar for 2412: last
        XCTAssertEqual(AirfoilLibrary.sorted(library, by: .name, polars: polars).map(\.key), library.map(\.key))
        XCTAssertEqual(AirfoilLibrary.sorted(library, by: .ldMax, polars: nil).map(\.key), library.map(\.key))
    }
}

final class AirfoilReshapeTests: XCTestCase {
    /// y on the upper and lower surfaces at x, by straight lines between points.
    private func surfaces(_ a: Airfoil, at x: Double) -> (upper: Double, lower: Double) {
        let i = a.coords.indices.min { a.coords[$0].x < a.coords[$1].x }!
        func at(_ s: [SIMD2<Double>]) -> Double {
            let s = s.sorted { $0.x < $1.x }
            let k = s.firstIndex { $0.x >= x }!
            let p = s[k - 1], q = s[k]
            return p.y + (q.y - p.y) * (x - p.x) / (q.x - p.x)
        }
        return (at(Array(a.coords[...i])), at(Array(a.coords[i...])))
    }

    func testCamberAndThicknessAsTheEngineDoes() throws {
        let base = try XCTUnwrap(Airfoil.naca4("0012"))
        XCTAssertEqual(base.reshaped(camber: 0, thickness: 1), base)
        let cambered = base.reshaped(camber: 0.02, thickness: 1)
        let mid = surfaces(cambered, at: 0.5)
        XCTAssertEqual((mid.upper + mid.lower) / 2, 0.02, accuracy: 3e-4)
        XCTAssertEqual(mid.upper - mid.lower, surfaces(base, at: 0.5).upper - surfaces(base, at: 0.5).lower, accuracy: 3e-4)
        let thin = base.reshaped(camber: 0, thickness: 0.75)
        XCTAssertEqual(surfaces(thin, at: 0.3).upper - surfaces(thin, at: 0.3).lower, 0.75 * 0.12, accuracy: 0.002)
        XCTAssertEqual(thin.coords.count, base.coords.count)
        XCTAssertTrue(thin.key.hasPrefix("shaped/"))

        let wing = Wing(elements: [WingElement(airfoil: base, chord: 0.3), WingElement(airfoil: base, chord: 0.14)])
        let trial = WingStudy.Trial(number: 3, state: "complete", value: 1, params: ["camber_1": 0.02, "angle_1": 20],
                                    placement: [.init(angle: 0, leadingEdge: [0, 0]), .init(angle: 20, leadingEdge: [0.28, 0.02])])
        let shaped = try XCTUnwrap(wing.applying(trial))
        XCTAssertEqual(shaped.elements[0].airfoil, base)
        XCTAssertEqual(shaped.elements[1].airfoil, cambered)

        // Loading it again onto the shaped wing, with the study's sections,
        // gives the same wing: shapes never stack.
        let again = try XCTUnwrap(shaped.applying(trial, sections: [base, base]))
        XCTAssertEqual(again.elements[1].airfoil, cambered)
        XCTAssertEqual(again.elements[1].airfoil.name, "NACA 0012 (camber +2.0%, thickness 100%)")
    }
}
