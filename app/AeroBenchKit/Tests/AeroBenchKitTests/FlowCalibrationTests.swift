import XCTest
@testable import AeroBenchKit

final class FlowCalibrationTests: XCTestCase {
    func testWritesTheEngineKeys() throws {
        var cal = FlowCalibration()
        cal.crop = [0, 0, 100, 50]
        cal.planes.firstFrame = 3
        cal.colormap = .init(preset: nil, legend: .init(frame: 2, p0: [1, 2], p1: [30, 2], halfWidth: 3))
        let text = String(decoding: try FlowCalibration.encoder().encode(cal), as: UTF8.self)
        for key in ["\"value_range\"", "\"mask_colors\"", "\"working_width\"", "\"first_frame\"", "\"half_width\"", "\"p0\""] {
            XCTAssertTrue(text.contains(key), "\(key) missing in \(text)")
        }
        XCTAssertEqual(try FlowCalibration.decoder().decode(FlowCalibration.self, from: Data(text.utf8)), cal)
    }

    func testReadsAnEngineWrittenCalibrationWithMissingFields() throws {
        let json = #"{"crop": [1, 2, 300, 200], "planes": {"start": 0, "end": 2.5}, "spatial": {"mode": "size", "width": 1.2, "height": 0.7}}"#
        let cal = try FlowCalibration.decoder().decode(FlowCalibration.self, from: Data(json.utf8))
        XCTAssertEqual(cal.planes.end, 2.5)
        XCTAssertEqual(cal.planes.stride, 1)
        XCTAssertEqual(cal.threshold, 12)
        XCTAssertTrue(cal.problems.isEmpty, "\(cal.problems)")
    }

    func testProblemsListWhatIsMissing() {
        var cal = FlowCalibration()
        XCTAssertTrue(cal.problems.contains { $0.contains("crop") })
        XCTAssertTrue(cal.problems.contains { $0.contains("two points") })
        cal.crop = [0, 0, 10, 10]
        cal.spatial.frames = [.init(frame: 0, points: [.init(px: [0, 0], world: [0, 0]), .init(px: [5, 0], world: [0.1, 0])])]
        XCTAssertTrue(cal.problems.isEmpty, "\(cal.problems)")
        cal.spatial.frames.append(.init(frame: 0, points: []))
        XCTAssertTrue(cal.problems.contains { $0.contains("different frames") })
    }
}
