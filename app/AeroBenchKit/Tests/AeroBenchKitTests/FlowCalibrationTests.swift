import CoreGraphics
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
        XCTAssertTrue(cal.problems.contains { $0.contains("Plane start and end") })  // until typed
        cal.planes.end = 1
        cal.crop = [0, 0, 10, 10]
        cal.spatial.frames = [.init(frame: 0, points: [.init(px: [0, 0], world: [0, 0]), .init(px: [5, 0], world: [0.1, 0])])]
        XCTAssertTrue(cal.problems.isEmpty, "\(cal.problems)")
        cal.spatial.frames.append(.init(frame: 0, points: []))
        XCTAssertTrue(cal.problems.contains { $0.contains("different frames") })
    }

    func testAxesGroundAndDetailRoundTrip() throws {
        var cal = FlowCalibration()
        cal.axes = .init(right: "+x", up: "+z")
        cal.ground = .init(track: true, level: 0.01)
        cal.detail = "high"
        let text = String(decoding: try FlowCalibration.encoder().encode(cal), as: UTF8.self)
        for key in ["\"axes\"", "\"right\" : \"+x\"", "\"track\" : true", "\"detail\" : \"high\""] {
            XCTAssertTrue(text.contains(key), "\(key) missing in \(text)")
        }
        XCTAssertEqual(try FlowCalibration.decoder().decode(FlowCalibration.self, from: Data(text.utf8)), cal)
        XCTAssertEqual(cal.axes.sweepLetter, "y")
        // Older files have none of these and get a rear view without tracking.
        let old = try FlowCalibration.decoder().decode(FlowCalibration.self, from: Data(#"{"crop": [0, 0, 10, 10]}"#.utf8))
        XCTAssertEqual(old.axes, .init(right: "+y", up: "+z"))
        XCTAssertFalse(old.ground.track)
        XCTAssertNil(old.detail)
    }

    func testCameraPlanesNeedTrackingAndAnAngle() throws {
        var cal = FlowCalibration()
        cal.crop = [0, 0, 10, 10]
        cal.spatial.mode = "size"
        cal.spatial.width = 1
        cal.planes.end = 1
        XCTAssertTrue(cal.problems.isEmpty, "\(cal.problems)")  // no height needed: pixels are square
        cal.planes.mode = "camera"
        XCTAssertTrue(cal.problems.contains { $0.contains("ground tracking") })
        XCTAssertTrue(cal.problems.contains { $0.contains("view angle") })
        cal.ground.track = true
        cal.planes.viewAngle = 30
        XCTAssertTrue(cal.problems.isEmpty, "\(cal.problems)")
        let text = String(decoding: try FlowCalibration.encoder().encode(cal), as: UTF8.self)
        XCTAssertTrue(text.contains("\"view_angle\" : 30"), text)
        XCTAssertEqual(try FlowCalibration.decoder().decode(FlowCalibration.self, from: Data(text.utf8)), cal)
    }

    func testAxisProblems() {
        var cal = FlowCalibration()
        cal.axes = .init(right: "+z", up: "-z")
        XCTAssertTrue(cal.problems.contains { $0.contains("different axes") })
        cal.axes = .init(right: "+x", up: "+y")
        cal.ground.track = true
        XCTAssertTrue(cal.problems.contains { $0.contains("+z pointing up") })
    }
}

final class FlowVolumeTests: XCTestCase {
    /// A side view: x to the right, z up, planes along y. The value is the
    /// x index plus 10 times the z index so the layout can be read back.
    private func sideVolume(right: String) -> FlowVolume {
        let x = [0.0, 0.1, 0.2], y = [-0.5, 0.0, 0.5], z = [0.0, 0.05]
        var values: [Float] = []
        for i in 0..<3 { for _ in 0..<3 { for k in 0..<2 { values.append(Float(i + 10 * k)) } } }
        return FlowVolume(x: x, y: y, z: z, sweepAxis: "y", right: right, up: "+z", frames: [4, 5, 6],
                          vmin: 0, vmax: 12, colormap: (0...12).map { SIMD3(Float($0) / 12, 0, 0) }, values: values)
    }

    /// The red byte the slice writes for a value, with the same Float rounding.
    private func expected(_ value: Int) -> Int { Int((Float(value) / 12 * 255).rounded()) }

    private func red(_ image: CGImage, _ col: Int, _ row: Int) -> Int {
        let data = image.dataProvider!.data! as Data
        return Int(data[(row * image.width + col) * 4])
    }

    func testSlicesFollowTheSweepAxis() throws {
        let v = sideVolume(right: "+x")
        XCTAssertEqual(v.planeCount, 3)
        XCTAssertEqual(v.sweepLetter, "y")
        XCTAssertEqual(v.planePosition(2), 0.5)
        XCTAssertEqual(v.cellSize, 0.1, accuracy: 1e-12)
        let image = try XCTUnwrap(v.sliceImage(plane: 1))
        XCTAssertEqual(image.width, 3)   // x across
        XCTAssertEqual(image.height, 2)  // z up
        // Top-left is x = 0, z = top: value 10. Bottom-right is x = 0.2, z = 0: value 2.
        XCTAssertEqual(red(image, 0, 0), expected(10))
        XCTAssertEqual(red(image, 2, 1), expected(2))
        let place = v.sliceFrame(plane: 2)
        XCTAssertEqual(place.center, SIMD3(0.1, 0.5, 0.025))
        XCTAssertEqual(place.right, SIMD3(0.2, 0, 0))
        XCTAssertEqual(place.up, SIMD3(0, 0, 0.05))
    }

    func testAMirroredRightAxisFlipsTheImage() throws {
        let v = sideVolume(right: "-x")
        let image = try XCTUnwrap(v.sliceImage(plane: 0))
        // Now the left edge is the far end of x.
        XCTAssertEqual(red(image, 0, 0), expected(12))
        XCTAssertEqual(v.sliceFrame(plane: 0).right, SIMD3(-0.2, 0, 0))
    }
}

final class FlowVolumeCutTests: XCTestCase {
    /// Sweep along x at uneven spacing (0, 0.1, 0.4 m), y across, z up; each
    /// voxel's value is its plane index, so a lengthways cut shows the planes.
    private func volume() -> FlowVolume {
        let x = [0.0, 0.1, 0.4], y = [-0.1, 0.0, 0.1, 0.2], z = [0.0, 0.05]
        var values: [Float] = []
        for i in 0..<3 { for _ in y { for _ in z { values.append(Float(i)) } } }
        return FlowVolume(x: x, y: y, z: z, sweepAxis: "x", right: "+y", up: "+z", frames: [0, 1, 2],
                          vmin: 0, vmax: 2, colormap: [SIMD3(0, 0, 0), SIMD3(0.5, 0.5, 0.5), SIMD3(1, 1, 1)], values: values)
    }

    func testCutAxesAndCounts() {
        let v = volume()
        XCTAssertEqual(v.axes(.captured).normal, 0)
        XCTAssertEqual(v.axes(.side).normal, 1)  // a side profile is cut across y
        XCTAssertEqual(v.axes(.top).normal, 2)
        XCTAssertEqual(v.sliceCount(.side), 4)
        XCTAssertEqual(v.slicePosition(.side, 1), 0.0)
        XCTAssertEqual(v.sliceFrame(.side, 1).center, SIMD3(0.2, 0.0, 0.025))
        XCTAssertEqual(v.sliceFrame(.side, 1).right, SIMD3(0.4, 0, 0))
    }

    func testSideProfileIsEvenAlongTheSweep() throws {
        let v = volume()
        let image = try XCTUnwrap(v.sliceImage(.side, 1))
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.width, 64)  // resampled evenly along the uneven sweep
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        func grey(_ col: Int) -> UInt8 { data[col * 4] }
        // Across 0..0.4 m: the first quarter is nearest the planes at 0 and 0.1,
        // the last stretch nearest the plane at 0.4.
        XCTAssertEqual(grey(0), 0)
        XCTAssertEqual(grey(20), 128)
        XCTAssertEqual(grey(63), 255)
    }
}
