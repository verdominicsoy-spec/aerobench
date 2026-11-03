import XCTest
@testable import AeroBenchKit

final class BodyRepairResultTests: XCTestCase {
    func testDecodesAPlanResult() throws {
        let json = #"""
        {"command": "cad-repair-body", "data": {"output": "car_repaired.step", "limit_mm": 0.5,
          "auto": {"parts": 12, "parts_sewn": 3, "small_edges_removed": 4, "small_faces_removed": 1, "max_sew_mm": 0.2},
          "items": [
            {"id": "gap:Floor:1.0,2.0,3.0", "kind": "gap", "part": "Floor", "size_mm": 2.4, "centre": [0.001, 0.002, 0.003],
             "centre_mm": [1.0, 2.0, 3.0], "lines": [[[0, 0, 0], [0.1, 0, 0]], [[0, 0, 0.002], [0.1, 0, 0.002]]],
             "fix": "bridge", "decision": null},
            {"id": "wide_gap:Floor:5.0,0.0,0.0", "kind": "wide_gap", "part": "Floor", "size_mm": 12.0, "centre": [0.005, 0, 0],
             "centre_mm": [5.0, 0.0, 0.0], "lines": [], "fix": null, "decision": null}],
          "result": {"solids": 3, "open_shells": 1, "open_parts": ["Floor"], "fused": true, "free_edges": 8,
                     "nonmanifold_edges": 0, "valid": true, "closed": false}}}
        """#
        let r = try BodyRepairResult.decode(resultFile: Data(json.utf8))
        XCTAssertEqual(r.items.count, 2)
        XCTAssertTrue(r.items[0].reviewable)
        XCTAssertFalse(r.items[1].reviewable)
        XCTAssertEqual(r.items[0].lines[0].count, 2)
        XCTAssertNil(r.items[0].decision)
        XCTAssertEqual(r.items[0].centreMM, [1, 2, 3])
        XCTAssertFalse(r.result.closed)
        XCTAssertEqual(r.result.openParts, ["Floor"])
        XCTAssertEqual(r.auto.maxSewMM, 0.2)
        XCTAssertEqual(r.limitMM, 0.5)
    }
}
