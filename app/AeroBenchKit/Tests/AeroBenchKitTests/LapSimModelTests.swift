import XCTest
@testable import AeroBenchKit

final class LapSimModelTests: XCTestCase {
    func testCarEncodesWithTheEngineKeys() throws {
        let value = try JSONValue(encoding: CarParameters.placeholder)
        guard case .object(let obj) = value else { return XCTFail() }
        XCTAssertEqual(Set(obj.keys), ["mass", "cla", "cda", "mu_lat", "mu_long", "power", "driven_axle_fraction",
                                       "aero_balance_driven", "crr", "rho", "v_max", "cog_height", "wheelbase",
                                       "track_width", "tyre_load_sensitivity"])
    }

    func testOldSetupFilesFillInDefaults() throws {
        let json = #"{"carA": {"mass": 300}, "compare": true}"#
        let setup = try AeroJSON.decoder().decode(LapSimSetup.self, from: Data(json.utf8))
        XCTAssertEqual(setup.carA.mass, 300)
        XCTAssertEqual(setup.carA.cla, CarParameters.placeholder.cla)
        XCTAssertEqual(setup.carA.cogHeight, 0)  // an older file keeps the point mass it was run with
        XCTAssertEqual(setup.carA.tyreLoadSensitivity, 0)
        XCTAssertGreaterThan(CarParameters.placeholder.cogHeight, 0)  // a new car has load transfer on
        XCTAssertTrue(setup.compare)
        XCTAssertEqual(setup.track.kind, .testTrack)
    }

    func testJobParamsOnlyIncludeCarBWhenComparing() throws {
        var setup = LapSimSetup()
        XCTAssertNil(try setup.jobParams(lapsimFolder: nil)["car_b"])
        setup.compare = true
        XCTAssertNotNil(try setup.jobParams(lapsimFolder: nil)["car_b"])
    }

    func testRelativeCSVPathResolvesInsideTheProject() {
        var track = LapSimTrack()
        track.kind = .csv
        track.csvPath = "tracks/endurance.csv"
        let folder = URL(fileURLWithPath: "/p/lapsim")
        XCTAssertEqual(track.csvURL(lapsimFolder: folder)?.path, "/p/lapsim/tracks/endurance.csv")
        track.csvPath = "/elsewhere/t.csv"
        XCTAssertEqual(track.csvURL(lapsimFolder: folder)?.path, "/elsewhere/t.csv")
    }

    func testSetupRoundTripsThroughTheProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lapsim-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ProjectStore.create(at: root, name: "p")
        var setup = LapSimSetup()
        setup.carA.cla = 4.2
        setup.track.kind = .skidpad
        try setup.save(toProject: root)
        XCTAssertEqual(LapSimSetup.load(fromProject: root), setup)
    }
}
