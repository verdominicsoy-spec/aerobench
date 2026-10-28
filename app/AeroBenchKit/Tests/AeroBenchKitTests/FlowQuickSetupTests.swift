import XCTest
@testable import AeroBenchKit

final class FlowQuickSetupTests: XCTestCase {
    /// A flow-detect result file, as the engine writes it.
    private let resultFile = #"""
    {"status": "ok", "data": {"found": true, "crop": [0, 0, 1920, 1032], "exclude": [[98, 869, 218, 983], [1366, 676, 1790, 784]],
     "legend": {"p0": [1401.5, 766.5], "p1": [1784.5, 766.5], "half_width": 6, "box": [1366, 676, 1790, 784], "frame": 450},
     "ground_visible": true, "axes": {"right": "+y", "up": "+z"}, "triad_box": [98, 869, 218, 983],
     "frames_sampled": 24, "source_size": [1920, 1080]}}
    """#

    func testDetectionFillsTheCalibration() throws {
        let found = try FlowDetection.decode(resultFile: Data(resultFile.utf8))
        XCTAssertEqual(found.triadBox, [98, 869, 218, 983])
        var cal = FlowCalibration()
        cal.axes = .init(right: "-x", up: "+y")  // whatever was there before
        let notes = cal.apply(found)
        XCTAssertEqual(cal.crop, [0, 0, 1920, 1032])
        XCTAssertEqual(cal.exclude.count, 2)
        XCTAssertEqual(cal.colormap.legend?.frame, 450)
        XCTAssertNil(cal.colormap.preset)
        XCTAssertEqual(cal.axes, .init(right: "+y", up: "+z"))
        XCTAssertTrue(cal.ground.track)
        XCTAssertEqual(cal.detail, "medium")
        XCTAssertEqual(cal.extent, "auto")
        XCTAssertEqual(notes.count, 4)
        // Nothing measured yet: only the size and the planes are left.
        XCTAssertEqual(cal.quickSteps.filter { !$0.done }.map(\.id), ["size", "planes"])
    }

    func testANothingFoundDetectionChangesNothing() throws {
        let file = #"{"data": {"found": false, "exclude": [], "message": "no colour-map colours found"}}"#
        var cal = FlowCalibration()
        let notes = cal.apply(try FlowDetection.decode(resultFile: Data(file.utf8)))
        XCTAssertNil(cal.crop)
        XCTAssertEqual(notes, ["no colour-map colours found"])
    }

    func testAMeasurementBecomesTheScale() {
        var cal = FlowCalibration()
        cal.crop = [0, 0, 100, 100]
        cal.ground.track = true
        // Dragged right to left, a little crooked: the line is levelled at its start.
        cal.measure = .init(frame: 12, p0: [700, 400], p1: [300, 404], width: 1.2, centre: 0)
        cal.applyMeasure()
        XCTAssertEqual(cal.spatial.frames.count, 1)
        let f = cal.spatial.frames[0]
        XCTAssertEqual(f.frame, 12)
        XCTAssertEqual(f.points[0].px, [300, 402])
        XCTAssertEqual(f.points[1].px, [700, 402])
        XCTAssertEqual(f.points[0].world, [-0.6, 0])
        XCTAssertEqual(f.points[1].world, [0.6, 0])
        // With -y to the right the left end is at +y.
        cal.axes = .init(right: "-y", up: "+z")
        cal.applyMeasure()
        XCTAssertEqual(cal.spatial.frames[0].points[0].world, [0.6, 0])
        // A side view: its middle is wherever the user says along x.
        cal.axes = .init(right: "+x", up: "+z")
        cal.measure?.centre = 1.0
        cal.applyMeasure()
        XCTAssertEqual(cal.spatial.frames[0].points[0].world, [0.4, 0])
        XCTAssertTrue(cal.scaleProblems.isEmpty, "\(cal.scaleProblems)")
    }

    func testNoWidthOrNoLineLeavesTheSizeStepOpen() {
        var cal = FlowCalibration()
        cal.measure = .init(frame: 0, p0: [], p1: [], width: 1.2)  // width typed, nothing drawn
        cal.applyMeasure()
        XCTAssertFalse(cal.quickSteps.first { $0.id == "size" }!.done)
        cal.measure = .init(frame: 0, p0: [10, 10], p1: [200, 10], width: 0)  // drawn, no width
        cal.applyMeasure()
        XCTAssertFalse(cal.quickSteps.first { $0.id == "size" }!.done)
    }

    func testUnclickedPointsAreAProblem() {
        var cal = FlowCalibration()
        cal.spatial.frames = [.init(frame: 0, points: [.init(px: [], world: [0, 0]), .init(px: [5, 5], world: [1, 0])])]
        XCTAssertTrue(cal.scaleProblems.contains { $0.contains("Click both points") })
    }

    func testTheThirdAxisDirection() {
        var cal = FlowCalibration()
        cal.axes = .init(right: "+y", up: "+z")
        XCTAssertEqual(cal.sweepTowardViewer, true)   // x out of the screen, as in the STAR video
        cal.axes = .init(right: "-y", up: "+z")
        XCTAssertEqual(cal.sweepTowardViewer, false)  // looking along +x
        cal.axes = .init(right: "+x", up: "+z")
        XCTAssertEqual(cal.sweepTowardViewer, false)  // x cross z = -y: +y goes away
    }
}
