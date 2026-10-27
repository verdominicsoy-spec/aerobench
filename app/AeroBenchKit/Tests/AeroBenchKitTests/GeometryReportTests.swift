import XCTest
@testable import AeroBenchKit

final class GeometryReportTests: XCTestCase {
    func testDecodesAMeshAndBrepReport() throws {
        let json = #"""
        {"command": "cad-check", "data": {"file": "/x/car.step", "problems": 3,
          "mesh": {"triangles": 1200, "vertices": 900, "bodies": 2, "closed": false, "weld_tolerance_mm": 0.001,
                   "problems": 3, "intersections_checked": true, "intersections_complete": true,
                   "issues": [{"kind": "open_edges", "title": "Open edges", "severity": "warning", "count": 3,
                               "detail": "d", "fixable": true, "points": [[0, 0, 0], [1, 0, 0], [0, 1, 0]]}]},
          "brep": {"parts": 4, "invalid_parts": [], "problems": 0,
                   "issues": [{"kind": "brep_free_edges", "title": "Free edges", "severity": "warning", "count": 0,
                               "detail": "d", "fixable": true, "points": []}]}}}
        """#
        let r = try GeometryReport.decode(resultFile: Data(json.utf8))
        XCTAssertEqual(r.problems, 3)
        XCTAssertEqual(r.allIssues.count, 2)
        XCTAssertEqual(r.mesh.issues[0].points.count, 3)
        XCTAssertTrue(r.anyFixable)
        XCTAssertEqual(r.brep?.parts, 4)
    }
}
