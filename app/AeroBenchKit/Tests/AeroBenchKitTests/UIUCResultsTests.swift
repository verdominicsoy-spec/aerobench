import XCTest
@testable import AeroBenchKit

final class UIUCResultsTests: XCTestCase {
    private let sample = #"""
    {"data": {
      "runs": [{
        "date": "2026-11-05T12:00:00", "cores": 12, "seconds": 3600.0,
        "settings": {"model": "sst", "mesh": "fine", "turbulence_intensity": 0.01, "commit": "abc1234"},
        "summary": {"estimate": {"lift": 0.15, "drag": 0.12}, "rans": {"lift": null, "drag": null}, "converged": 0.5},
        "cases": [{
          "key": "s1223", "name": "S1223 at Re 299,100", "volume": 1, "re": 299100.0,
          "estimate": [[0.0, 1.2, 0.018]],
          "rans": [[0.0, 1.1, 0.021, true], [2.0, 1.3, 0.024, false]], "rans_error": "gmsh produced no cells", "planned": 2,
          "errors": {"estimate": {"lift": 0.15, "drag": 0.12, "lift_signed": 0.15},
                     "rans": {"lift": null, "drag": null, "lift_signed": null}}
        }]
      }],
      "current": {"model": "sst", "mesh": "fine", "turbulence_intensity": 0.01, "commit": "abc1234"},
      "tunnel": {"s1223": {"name": "S1223 at Re 299,100", "re": 299100.0, "rows": [[-0.02, 1.07, 0.0211]]}},
      "tunnel_error": null
    }}
    """#

    func testDecodesARunWithNullRansErrors() throws {
        let r = try UIUCResults.decode(resultFile: Data(sample.utf8))
        let run = try XCTUnwrap(r.runs.first)
        XCTAssertEqual(run.cases.first?.rans.map(\.converged), [true, false])
        XCTAssertNil(run.cases.first?.errors.rans.lift)
        XCTAssertEqual(run.cases.first?.ransError, "gmsh produced no cells")
        XCTAssertEqual(run.summary.converged, 0.5)
        XCTAssertEqual(r.tunnel["s1223"]?.rows.first?.cl, 1.07)
        XCTAssertNil(r.tunnelError)
        XCTAssertFalse(r.isStale(run))
    }

    func testStaleWhenTheModelChangesButNotTheCores() throws {
        let other = sample.replacingOccurrences(of: #""current": {"model": "sst""#, with: #""current": {"model": "sst-lm""#)
        let r = try UIUCResults.decode(resultFile: Data(other.utf8))
        XCTAssertTrue(r.isStale(try XCTUnwrap(r.runs.first)))
        let cores = sample.replacingOccurrences(of: #""cores": 12"#, with: #""cores": 4"#)
        let s = try UIUCResults.decode(resultFile: Data(cores.utf8))
        XCTAssertFalse(s.isStale(try XCTUnwrap(s.runs.first)))
    }
}
