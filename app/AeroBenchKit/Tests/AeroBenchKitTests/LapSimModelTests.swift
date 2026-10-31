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
        XCTAssertEqual(setup.cars.count, 2)  // compare on: A and B, B a copy of A when none was saved
        XCTAssertEqual(setup.cars[1], setup.carA)
        XCTAssertEqual(setup.track.kind, .endurance)  // no track saved at all: a new project's default
        // A saved track from before generated layouts keeps what it was.
        let old = try AeroJSON.decoder().decode(LapSimTrack.self, from: Data(#"{"skidpadRadius": 9}"#.utf8))
        XCTAssertEqual(old.kind, .testTrack)
    }

    func testGeneratedTracksAskTheEngineByNumber() {
        var track = LapSimTrack()
        XCTAssertEqual(track.kind, .endurance)
        track.seed = 7
        XCTAssertEqual(track.jobValue(lapsimFolder: nil), .object(["generated": .int(7), "event": .string("endurance")]))
        track.kind = .autocross
        XCTAssertEqual(track.jobValue(lapsimFolder: nil), .object(["generated": .int(7), "event": .string("autocross")]))
    }

    func testJobParamsSendEveryCar() throws {
        var setup = LapSimSetup()
        guard case .array(let one) = try setup.jobParams(lapsimFolder: nil)["cars"] else { return XCTFail() }
        XCTAssertEqual(one.count, 1)
        setup.cars += [setup.carA, setup.carA]
        guard case .array(let three) = try setup.jobParams(lapsimFolder: nil)["cars"] else { return XCTFail() }
        XCTAssertEqual(three.count, 3)
        XCTAssertNotNil(try setup.jobParams(lapsimFolder: nil)["car"])  // A, for the wing optimiser's lap objective
    }

    func testNewSetupFilesKeepEveryCar() throws {
        var setup = LapSimSetup()
        setup.cars = [.placeholder, .placeholder, .placeholder]
        setup.cars[2].mass = 310
        let back = try AeroJSON.decoder().decode(LapSimSetup.self, from: AeroJSON.encoder().encode(setup))
        XCTAssertEqual(back, setup)
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
