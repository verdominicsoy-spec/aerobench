import XCTest
@testable import AeroBenchKit

final class BundledEngineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("aerobench-bundle-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, _ path: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testInstallsAndUpdatesWithoutLosingWhatWasMadeThere() throws {
        let source = root.appendingPathComponent("bundle"), home = root.appendingPathComponent("home")
        try write("[project]", "engine/pyproject.toml", in: source)
        try write("print(1)", "engine/src/aeroengine/x.py", in: source)
        try write("s,x,y", "data/tracks/fsg.csv", in: source)
        try write("abc123", "VERSION", in: source)
        XCTAssertTrue(BundledEngine.needsInstall(source: source, home: home))

        try BundledEngine.install(from: source, to: home)
        XCTAssertFalse(BundledEngine.needsInstall(source: source, home: home))
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("engine/src/aeroengine/x.py"), encoding: .utf8), "print(1)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("data/airfoils").path))

        // Made on the Mac since: the environment and the downloaded library.
        try write("venv", "engine/.venv/marker", in: home)
        try write("index", "data/airfoils/index.sqlite", in: home)
        try write("old", "engine/src/aeroengine/gone.py", in: home)
        try write("print(2)", "engine/src/aeroengine/x.py", in: source)
        try write("def456", "VERSION", in: source)
        XCTAssertTrue(BundledEngine.needsInstall(source: source, home: home))
        try BundledEngine.install(from: source, to: home)
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("engine/src/aeroengine/x.py"), encoding: .utf8), "print(2)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("engine/src/aeroengine/gone.py").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("engine/.venv/marker").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("data/airfoils/index.sqlite").path))
        XCTAssertEqual(BundledEngine.version(home), "def456")
    }

    func testADevelopmentBuildCarriesNoEngine() {
        XCTAssertNil(BundledEngine.source(in: Bundle(for: Self.self)))
    }
}
