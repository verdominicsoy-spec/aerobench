import XCTest
@testable import AeroBenchKit

final class JobFolderTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("aerobench-jobs-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testJobFileMatchesWhatTheEngineExpects() throws {
        let spec = JobSpec(command: "dummy", params: ["duration": .double(2.5)], options: .init(keepMesh: true, cores: 4))
        let (_, url) = try JobFolder.create(in: root, spec: spec)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("job.json"))) as! [String: Any]
        XCTAssertEqual(raw["command"] as? String, "dummy")
        let options = raw["options"] as! [String: Any]
        XCTAssertEqual(options["keep_mesh"] as? Bool, true)
        // The engine insists cores is an integer, not 4.0.
        let text = try String(contentsOf: url.appendingPathComponent("job.json"), encoding: .utf8)
        XCTAssertTrue(text.contains(#""cores" : 4"#), text)
        XCTAssertFalse(text.contains("4.0"), text)
    }

    func testStaleRunningJobsLoadAsFailed() throws {
        let (id, url) = try JobFolder.create(in: root, spec: JobSpec(command: "dummy"))
        var record = JobRecord(id: id, command: "dummy", status: .running, created: AeroJSON.now())
        record.started = record.created
        try JobFolder.write(record, to: url)

        let loaded = JobFolder.loadRecords(in: root)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].status, .failed)
        XCTAssertEqual(loaded[0].message, "Interrupted: AeroBench quit while this job was running")
    }
}
