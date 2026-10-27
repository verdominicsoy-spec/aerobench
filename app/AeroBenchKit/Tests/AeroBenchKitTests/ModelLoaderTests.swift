import XCTest
import simd
@testable import AeroBenchKit

/// Loader tests against small generated files and the committed samples
/// (samples/sample_car.*, built by engine/scripts/make_sample_cad.py).
final class ModelLoaderTests: XCTestCase {
    static let samples = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("samples")

    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func size(_ model: Model3D, hidden: Set<Int> = []) throws -> SIMD3<Double> {
        let b = try XCTUnwrap(model.bounds(hidden: hidden))
        return b.max - b.min
    }

    func testASCIISTLInMillimetres() throws {
        let url = dir.appendingPathComponent("tri.stl")
        try """
        solid t
          facet normal 0 0 1
            outer loop
              vertex 0 0 0
              vertex 100 0 0
              vertex 0 50 0
            endloop
          endfacet
        endsolid t
        """.write(to: url, atomically: true, encoding: .utf8)
        let model = try ModelLoader.load(url, units: .millimetre)
        XCTAssertEqual(model.triangleCount, 1)
        let s = try size(model)
        XCTAssertEqual(s.x, 0.1, accuracy: 1e-7)
        XCTAssertEqual(s.y, 0.05, accuracy: 1e-7)
    }

    func testBinarySampleSTL() throws {
        let model = try ModelLoader.load(Self.samples.appendingPathComponent("sample_car.stl"), units: .millimetre)
        XCTAssertGreaterThan(model.triangleCount, 1000)
        let s = try size(model)
        XCTAssertEqual(s.y * 1000, 1200, accuracy: 0.01)  // wheel outer faces
        XCTAssertEqual(model.meshes[0].normals.count, model.meshes[0].positions.count)
    }

    func testOBJGroupsBecomeParts() throws {
        let url = dir.appendingPathComponent("two.obj")
        try """
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        o Square
        f 1 2 3 4
        o Tri
        f -4/1/1 -3/2/2 -2/3/3
        """.write(to: url, atomically: true, encoding: .utf8)
        let model = try ModelLoader.load(url, units: .metre)
        XCTAssertEqual(model.roots.first?.children.map(\.name), ["Square", "Tri"])
        XCTAssertEqual(model.meshes.map(\.triangleCount), [2, 1])
    }

    func testSampleOBJKeepsPartNames() throws {
        let model = try ModelLoader.load(Self.samples.appendingPathComponent("sample_car.obj"), units: .millimetre)
        let names = Set(model.roots.flatMap { $0.children.map(\.name) })
        XCTAssertTrue(names.contains("Chassis"), "\(names)")
        XCTAssertTrue(names.contains("Wheel FL"), "\(names)")
    }

    func testBadFilesThrowInsteadOfCrashing() throws {
        let stl = dir.appendingPathComponent("bad.stl")
        try "solid x\n vertex 1 2\nendsolid".write(to: stl, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ModelLoader.load(stl))
        let obj = dir.appendingPathComponent("bad.obj")
        try "v 0 0 0\nf 1 2 3\n".write(to: obj, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ModelLoader.load(obj))
        let glb = dir.appendingPathComponent("bad.glb")
        try Data("glTFnope".utf8).write(to: glb)
        XCTAssertThrowsError(try ModelLoader.load(glb))
        XCTAssertThrowsError(try ModelLoader.load(dir.appendingPathComponent("x.fbx")))
    }

    func testHidingASubtreeShrinksTheBounds() throws {
        let model = try ModelLoader.load(Self.samples.appendingPathComponent("sample_car.obj"), units: .millimetre)
        let root = try XCTUnwrap(model.roots.first)
        let chassis = try XCTUnwrap(root.children.first { $0.name == "Chassis" })
        let others = Set(root.children.filter { $0.id != chassis.id }.map(\.id))
        let s = try size(model, hidden: others)
        XCTAssertEqual(s.x * 1000, 1500, accuracy: 0.01)
        XCTAssertEqual(s.y * 1000, 600, accuracy: 0.01)
        XCTAssertEqual(s.z * 1000, 300, accuracy: 0.01)
    }

    func testNearestCornerSnaps() {
        let corners: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
        XCTAssertEqual(Measure.nearestCorner(to: SIMD3(0.9, 0.1, 0), of: corners), SIMD3(1, 0, 0))
    }
}
