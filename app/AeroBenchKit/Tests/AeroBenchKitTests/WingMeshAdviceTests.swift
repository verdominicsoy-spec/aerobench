import XCTest
@testable import AeroBenchKit

final class WingMeshAdviceTests: XCTestCase {
    private func run(level: String, cl: Double = -2.0, cd: Double = 0.05, yPlus: (Double, Double)? = (0.9, 0.7),
                     laminar: Bool = true, converged: Bool = true) throws -> WingRansResult {
        let y = yPlus.map { #", "y_plus": {"max": \#($0.0), "p95": \#($0.1), "mean": 0.5}"# } ?? ""
        let json = #"""
        {"data": {"re": 400000, "mesh": {"cells": 1, "triangles": 1, "quads": 0, "layers": 20, "first_cell_height_m": 1e-5,
          "layer_thickness_m": 0.003}, "mesh_level": "\#(level)", "transition": [[\#(laminar ? 0.3 : 0), 0]], "model": "sst",
          "model_name": "SST", "iterations": 1000, "converged": \#(converged), "residual_drop": 4, "cl": \#(cl), "cd": \#(cd),
          "elements": [], "surface": [], "alpha": 2\#(y)}}
        """#
        return try WingRansResult.decode(resultFile: Data(json.utf8))
    }

    func testTallWallCellsAskForMoreCells() throws {
        // Medium, as a real run: y+ up to 3.8, 95% under 2.6, with laminar zones.
        let a = try run(level: "medium", yPlus: (3.84, 2.62)).meshAdvice(others: [])
        XCTAssertEqual(a.verdict, .refine)
        XCTAssertTrue(a.reasons[0].hasPrefix("Wall cells too tall"))
        XCTAssertEqual(a.next, "medium")  // every level shares the wall cells: mesh again, not finer
    }

    func testTheSameYPlusIsFineOnFullyTurbulentWalls() throws {
        let a = try run(level: "medium", yPlus: (3.0, 2.6), laminar: false).meshAdvice(others: [])
        XCTAssertEqual(a.verdict, .unknown)  // walls fine, but one level says nothing about the rest
        XCTAssertTrue(a.reasons.last!.contains("run on fine"))
    }

    func testTwoLevelsThatAgreeAreEnough() throws {
        let fine = try run(level: "fine", cl: -2.005, cd: 0.0505)
        let a = fine.meshAdvice(others: [try run(level: "medium")])
        XCTAssertEqual(a.verdict, .enough)
        XCTAssertNil(a.next)
    }

    func testTwoLevelsThatDisagreeAskForMoreCells() throws {
        let medium = try run(level: "medium", cl: -2.1)
        let a = medium.meshAdvice(others: [try run(level: "coarse")])
        XCTAssertEqual(a.verdict, .refine)
        XCTAssertTrue(a.reasons.contains { $0.hasPrefix("Adding cells still moves it: Cl 5.0%") })
        // Seen from the coarse run, the finer one is the one to trust.
        let b = try run(level: "coarse").meshAdvice(others: [medium])
        XCTAssertTrue(b.reasons.contains { $0.contains("trust the finer run") })
    }

    func testNotConvergedIsNotAMeshProblem() throws {
        let a = try run(level: "medium", converged: false).meshAdvice(others: [])
        XCTAssertTrue(a.reasons.contains { $0.hasPrefix("Not converged: more cells will not fix that") })
    }

    func testAnOlderRunWithoutYPlusOnlyHasTheLevels() throws {
        let a = try run(level: "medium", yPlus: nil).meshAdvice(others: [])
        XCTAssertEqual(a.verdict, .unknown)
    }
}
