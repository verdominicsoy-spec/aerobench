import XCTest
@testable import AeroBenchKit

final class ProjectStoreTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("aerobench-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreateMakesTheFolderLayout() throws {
        let url = root.appendingPathComponent("Rear Wing 2027")
        let manifest = try ProjectStore.create(at: url, name: "Rear Wing 2027")
        XCTAssertEqual(manifest.name, "Rear Wing 2027")
        for name in ["project.json", "wing", "cad", "flow", "lapsim", "jobs"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path), name)
        }
    }

    func testRoundTripAndSave() throws {
        let url = root.appendingPathComponent("p")
        var manifest = try ProjectStore.create(at: url, name: "p")
        manifest.notes = "first try"
        manifest.tools["lapsim"] = .object(["cla": .double(3.2)])
        let saved = try ProjectStore.save(manifest, at: url)
        XCTAssertEqual(try ProjectStore.open(at: url), saved)
    }

    func testOpenRejectsAFolderWithoutManifest() {
        XCTAssertThrowsError(try ProjectStore.open(at: root)) { error in
            XCTAssertEqual(error as? ProjectError, .notAProject(root))
        }
    }

    func testCreateRefusesANonEmptyFolder() throws {
        try Data("x".utf8).write(to: root.appendingPathComponent("stuff.txt"))
        XCTAssertThrowsError(try ProjectStore.create(at: root, name: "x"))
    }
}
