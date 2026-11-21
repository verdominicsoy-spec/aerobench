import XCTest
@testable import AeroBenchKit

final class PartEditTests: XCTestCase {
    func testFeatureFileRoundTrips() throws {
        var edge = EditRef(src: "part", kind: "edge", i: 3)
        edge.tangent = EditRef(src: "part", kind: "face", i: 1)
        let fill = EditFeature(id: "f1", kind: .fill, refs: [edge, EditRef(src: "s1", kind: "curve")], values: [:])
        let file = FeatureFile(part: "Endplate", fingerprint: "1:2:abc", features: [fill])
        let back = try JSONDecoder().decode(FeatureFile.self, from: JSONEncoder().encode(file))
        XCTAssertEqual(back.features[0].refs[0].tangent?.i, 1)
        XCTAssertNil(back.features[0].refs[1].tangent)
        XCTAssertEqual(back.part, "Endplate")
        let json = String(decoding: try JSONEncoder().encode(edge), as: UTF8.self)
        XCTAssertTrue(json.contains(#""tangent":{"#))  // nested object, as the engine reads it
    }

    func testFeatureFileLivesBesideTheStep() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let step = dir.appendingPathComponent("endplate.step")
        XCTAssertEqual(FeatureFile.url(beside: step).lastPathComponent, "endplate.features.json")
        XCTAssertNil(try FeatureFile.load(beside: step))
        try FeatureFile(part: nil, fingerprint: nil, features: []).save(beside: step)
        XCTAssertNotNil(try FeatureFile.load(beside: step))
    }

    func testDecodesAPartEditReply() throws {
        let json = #"""
        {"type": "reply", "id": 1, "data": {"parts": ["Box"], "part": "Box", "fingerprint": "1:2:x", "part_valid": true,
          "glb": "/tmp/a.glb", "faces": [{"ref": {"src": "part", "kind": "face", "i": 0}, "start": 0, "count": 2},
                                         {"ref": null, "start": 2, "count": 4}],
          "edges": [{"ref": {"src": "f1", "kind": "edge", "i": 0}, "points": [[0, 0, 0], [0.1, 0, 0]]}],
          "points": [{"id": "p1", "position": [0, 0, 0.1]}], "planes": [{"id": "pl", "origin": [0, 0, 0], "normal": [0, 0, 1]}],
          "features": [{"id": "f1", "status": "failed", "message": "the 150 mm fillet could not be built"}],
          "valid": true, "closed": true}}
        """#
        let r = try PartEditReply.decode(Data(json.utf8))
        XCTAssertEqual(r.faces.count, 2)
        XCTAssertNil(r.faces[1].ref)
        XCTAssertEqual(r.face(atTriangle: 3)?.count, 4)
        XCTAssertEqual(r.features[0].status, "failed")
        XCTAssertTrue(r.partValid)
    }

    func testNearestEdgeWithinTolerance() {
        let lines: [[SIMD2<Double>]] = [[SIMD2(0, 0), SIMD2(100, 0)], [SIMD2(0, 50), SIMD2(100, 50)]]
        XCTAssertEqual(EdgePick.nearest(lines, to: SIMD2(40, 47), within: 6), 1)
        XCTAssertNil(EdgePick.nearest(lines, to: SIMD2(40, 47), within: 2))
        XCTAssertEqual(EdgePick.nearest(lines, to: SIMD2(-3, 1), within: 6), 0)  // past the end, near its corner
    }

    func testAHiddenEdgeIsNotPicked() {
        // Two edges a few points apart on screen; the nearer one is behind the surface under the pointer.
        let behind: [SIMD3<Double>] = [SIMD3(0, 0, 0.9), SIMD3(100, 0, 0.9)]
        let front: [SIMD3<Double>] = [SIMD3(0, 4, 0.4), SIMD3(100, 4, 0.4)]
        XCTAssertEqual(EdgePick.nearest([behind, front], to: SIMD2(50, 1), within: 6, surfaceDepth: 0.5), 1)
        XCTAssertEqual(EdgePick.nearest([behind, front], to: SIMD2(50, 1), within: 6, surfaceDepth: nil), 0)
    }

    func testLatestOnlyDropsSupersededInputs() async {
        // A gate holds the first run open, so the test does not depend on how
        // fast the machine is (10 ms sleeps failed on the CI runner).
        let ran = Recorder(), gate = Gate()
        let runner = LatestOnly<Int, Int> { n in
            await ran.add(n)
            if n == 1 { await gate.wait() }
            return n * 10
        }
        let first = Task { await runner.submit(1) }
        while await ran.values.isEmpty { await Task.yield() }  // 1 is running, held at the gate
        let second = Task { await runner.submit(2) }
        try? await Task.sleep(nanoseconds: 100_000_000)  // 2 waits behind 1
        let third = Task { await runner.submit(3) }  // and 3 replaces it
        try? await Task.sleep(nanoseconds: 100_000_000)
        await gate.release()
        let (a, b, c) = (await first.value, await second.value, await third.value)
        XCTAssertEqual(try a?.get(), 10)
        XCTAssertNil(b)
        XCTAssertEqual(try c?.get(), 30)
        let order = await ran.values
        XCTAssertEqual(order, [1, 3])
    }
}

private actor Gate {
    private var open = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        open = true
        waiter?.resume()
        waiter = nil
    }
}

private actor Recorder {
    var values: [Int] = []
    func add(_ v: Int) { values.append(v) }
}
