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

    func testDistanceFromEyeGap() {
        let hfov = 62.0 * .pi / 180
        let at55 = 6.3 / (2 * tan(hfov / 2) * 55)
        func d(_ gap: Double) -> Double {
            HeadGeometry.distance(HeadGeometry.Sample(eyeMid: [0.5, 0.5], separation: gap, time: 0), hfov: hfov)
        }
        XCTAssertEqual(d(at55), 55, accuracy: 1e-9)
        XCTAssertEqual(d(at55 / 2), 110, accuracy: 1e-9)
        XCTAssertTrue(d(0).isFinite)
    }

    func testThePeekNeedsNoEyeSpacing() {
        // One webcam can't tell wide-set eyes far away from narrow-set ones close up, and
        // the peek doesn't need to: two people at the same seats, moving the same way, get
        // the same eye even though their spacings (5.8 and 7.0 cm) differ from the 6.3 assumed.
        let hfov = 62.0 * .pi / 180, k = 2 * tan(hfov / 2)
        let layout = HeadGeometry.Layout(viewWidthCM: 30, viewHeightCM: 19, cameraCM: [0, 11])
        let rest = SIMD3<Double>(0, 0, 3)
        func eye(spacing: Double) -> SIMD3<Double> {
            // At 55 cm straight on at the press, then 40 cm and 8 cm to the right.
            func at(_ x: Double, _ z: Double) -> SIMD3<Double> {
                let s = HeadGeometry.Sample(eyeMid: [0.5 - x / (k * z), 0.5], separation: spacing / (k * z), time: 0)
                return HeadGeometry.head(s, hfov: hfov, imageAspect: 16.0 / 9, distanceCM: HeadGeometry.distance(s, hfov: hfov),
                                         layout: layout, mirrored: false)
            }
            let press = at(0, 55), now = at(8, 40)
            return PeekWindow.eye(rest: rest, offsetCM: now - press, distanceCM: press.z, blend: 1)
        }
        let a = eye(spacing: 5.8), b = eye(spacing: 7.0)
        XCTAssertEqual(simd_distance(a, b), 0, accuracy: 1e-9)
        XCTAssertEqual(a.z, 3 * 40 / 55, accuracy: 1e-9)
    }
}
