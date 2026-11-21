import XCTest
import simd
@testable import AeroBench3D

final class HeadGeometryTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let screenMM = CGSize(width: 302.4, height: 196.4)  // 0.02 cm per point

    func testLayoutFullScreenView() {
        let l = HeadGeometry.layout(viewRect: screen, screenFrame: screen, screenSizeMM: screenMM)
        XCTAssertEqual(l.viewWidthCM, 30.24, accuracy: 1e-9)
        XCTAssertEqual(l.viewHeightCM, 19.64, accuracy: 1e-9)
        XCTAssertEqual(l.cameraCM.x, 0, accuracy: 1e-9)
        XCTAssertEqual(l.cameraCM.y, 9.82 + 0.8, accuracy: 1e-9)
    }

    func testLayoutOffCentreView() {
        // 600 x 400 view, centre 200 pt left of and 100 pt below the screen centre.
        let view = CGRect(x: 256, y: 191, width: 600, height: 400)
        let l = HeadGeometry.layout(viewRect: view, screenFrame: screen, screenSizeMM: screenMM)
        XCTAssertEqual(l.viewWidthCM, 12, accuracy: 1e-9)
        XCTAssertEqual(l.viewHeightCM, 8, accuracy: 1e-9)
        XCTAssertEqual(l.cameraCM.x, 200 * 0.02, accuracy: 1e-9)
        XCTAssertEqual(l.cameraCM.y, (491 + 100) * 0.02 + 0.8, accuracy: 1e-9)
    }

    private var layout: HeadGeometry.Layout {
        HeadGeometry.layout(viewRect: screen, screenFrame: screen, screenSizeMM: screenMM)
    }

    private func head(_ x: Double, _ y: Double, mirrored: Bool = false) -> SIMD3<Double> {
        HeadGeometry.head(HeadGeometry.Sample(eyeMid: [x, y], separation: 0.1, time: 0), hfov: 62 * .pi / 180,
                          imageAspect: 16.0 / 9, distanceCM: 55, layout: layout, mirrored: mirrored)
    }

    func testHeadCentredOnCamera() {
        let h = head(0.5, 0.5)
        XCTAssertEqual(h.x, layout.cameraCM.x, accuracy: 1e-9)
        XCTAssertEqual(h.y, layout.cameraCM.y, accuracy: 1e-9)
        XCTAssertEqual(h.z, 55)
    }

    func testHeadSign() {
        // The webcam faces you, so your right is the image's left (unless mirrored).
        XCTAssertGreaterThan(head(0.3, 0.5).x, layout.cameraCM.x)
        XCTAssertLessThan(head(0.3, 0.5, mirrored: true).x, layout.cameraCM.x)
        // Vision's y is up.
        XCTAssertGreaterThan(head(0.5, 0.7).y, layout.cameraCM.y)
        // 31° off axis horizontally at 55 cm.
        XCTAssertEqual(head(0, 0.5).x - layout.cameraCM.x, 55 * tan(31 * Double.pi / 180), accuracy: 1e-9)
    }
    func testEyeAngleOrdersByX() {
        // From the image-left eye to the image-right one, whichever Vision lists first.
        XCTAssertEqual(HeadGeometry.eyeAngle([0, 0], [1, 1]), .pi / 4, accuracy: 1e-12)
        XCTAssertEqual(HeadGeometry.eyeAngle([1, 1], [0, 0]), .pi / 4, accuracy: 1e-12)
        XCTAssertEqual(HeadGeometry.eyeAngle([0, 3], [2, 3]), 0, accuracy: 1e-12)
        XCTAssertTrue(HeadGeometry.eyeAngle([0, 0], [1e-9, 1]).isFinite)  // head on its side
    }

    func testTiltSign() {
        // Unmirrored, the camera faces you: your right ear down puts your right eye, on the
        // image's left, lower, and the eye line turns anticlockwise in the image. That is a
        // clockwise tilt as you see it. Mirrored frames flip it.
        let s = HeadGeometry.Sample(eyeMid: [0.5, 0.5], separation: 0.1, eyeAngle: 0.2, time: 0)
        XCTAssertEqual(HeadGeometry.tilt(s, mirrored: false), 0.2, accuracy: 1e-12)
        XCTAssertEqual(HeadGeometry.tilt(s, mirrored: true), -0.2, accuracy: 1e-12)
    }
}
