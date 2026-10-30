import XCTest
@testable import AeroBenchKit

final class WarmEngineTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("aerobench-warm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// A stand-in server: ready, then a reply per line, an error for "fail",
    /// and it exits on "quit".
    private func fakeEngine() throws -> URL {
        let url = dir.appendingPathComponent("aeroengine")
        let script = """
        #!/bin/sh
        echo '{"type":"ready"}'
        n=0
        while read -r line; do
          case "$line" in
            *quit*) exit 3 ;;
            *fail*) echo "{\\"type\\":\\"reply\\",\\"id\\":$n,\\"error\\":\\"no good\\"}" ;;
            *) echo "{\\"type\\":\\"log\\",\\"msg\\":\\"working\\"}"; echo "{\\"type\\":\\"reply\\",\\"id\\":$n,\\"data\\":{\\"n\\":$n}}" ;;
          esac
          n=$((n+1))
        done
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private struct Answer: Decodable { var data: [String: Int] }

    func testRepliesInOrderErrorsAndARestart() async throws {
        let engine = WarmEngine(executableURL: try fakeEngine())
        defer { engine.stop() }
        for i in 0..<3 {
            let data = try await engine.request("go", params: .object([:]))
            XCTAssertEqual(try JSONDecoder().decode(Answer.self, from: data).data["n"], i)
        }
        do {
            _ = try await engine.request("fail", params: .null)
            XCTFail("expected an error")
        } catch let e as WarmEngine.Failure {
            XCTAssertEqual(e.message, "no good")
        }
        do {
            _ = try await engine.request("quit", params: .null)
            XCTFail("expected the engine to stop")
        } catch let e as WarmEngine.Failure {
            XCTAssertTrue(e.message.contains("stopped"), e.message)
        }
        // The next request starts it again (a fresh server counts from 0).
        let data = try await engine.request("go", params: .null)
        XCTAssertEqual(try JSONDecoder().decode(Answer.self, from: data).data["n"], 0)
    }

    func testMissingEngine() async {
        let engine = WarmEngine(executableURL: dir.appendingPathComponent("nothing"))
        do {
            _ = try await engine.request("go", params: .null)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not found"))
        }
    }

    /// The real engine, when AEROBENCH_ENGINE points at it.
    func testRealEngineEstimates() async throws {
        guard let path = ProcessInfo.processInfo.environment["AEROBENCH_ENGINE"] else {
            throw XCTSkip("AEROBENCH_ENGINE not set")
        }
        let engine = WarmEngine(executableURL: EngineLocation.executable(inEngineDirectory: URL(fileURLWithPath: path)))
        defer { engine.stop() }
        let unit = (0...40).map { i -> JSONValue in
            let x = 0.5 * (1 + cos(Double.pi * Double(i) / 20)), t = 0.6 * (0.2969 * sqrt(x) - 0.126 * x - 0.3516 * x * x + 0.2843 * x * x * x - 0.1036 * x * x * x * x)
            return .array([.double(x), .double(i <= 20 ? t : -t)])
        }
        let element: JSONValue = .object(["coords": .array(unit.map { p in
            guard case .array(let xy) = p, case .double(let x) = xy[0], case .double(let y) = xy[1] else { return p }
            return .array([.double(x * 0.25), .double(y * 0.25)])
        }), "unit": .array(unit), "chord": .double(0.25), "angle": .double(0)])
        let params: JSONValue = .object(["elements": .array([element]), "alphas": .array([.double(0), .double(4)])])
        _ = try await engine.request("wing-estimate", params: params)  // loads NeuralFoil
        let start = Date()
        let estimate = try WingEstimate.decode(resultFile: try await engine.request("wing-estimate", params: params))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        XCTAssertEqual(estimate.rows.count, 2)
        XCTAssertGreaterThan(estimate.rows[1].cl, estimate.rows[0].cl)
    }
}
