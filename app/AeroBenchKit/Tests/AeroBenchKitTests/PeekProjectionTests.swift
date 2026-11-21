import XCTest
import SceneKit
import simd
@testable import AeroBench3D

final class PeekProjectionTests: XCTestCase {
    let aspect = 1.6

    private func camera(ortho: Bool = false) -> OrbitCamera {
        var c = OrbitCamera(orthographic: ortho)
        c.frame(center: [0.5, 0.2, 0.3], radius: 1.2, direction: [-1, -1, 0.8], up: [0, 0, 1], aspect: aspect)
        return c
    }

    /// NDC of a world point seen from `position` with the camera's orientation and `projection`.
    private func ndc(_ p: SIMD3<Double>, _ c: OrbitCamera, _ position: SIMD3<Double>, _ projection: simd_double4x4) -> SIMD2<Double> {
        let d = p - position
        let clip = projection * SIMD4(simd_dot(d, c.right), simd_dot(d, c.up), -simd_dot(d, c.forward), 1)
        return SIMD2(clip.x / clip.w, clip.y / clip.w)
    }

    func testWindowCornersStayPinned() {
        for ortho in [false, true] {
            let c = camera(ortho: ortho)
            let d = c.distance * 0.7
            let w = c.peekWindow(depth: d, aspect: aspect)
            for e in [SIMD3(0, 0, d), SIMD3(0.3 * d, -0.2 * d, 0.8 * d), SIMD3(-0.5 * d, 0.4 * d, 1.5 * d)] {
                let (position, projection) = c.peekCamera(window: w, eye: e, near: 0.01, far: 100)
                for sx in [-1.0, 1.0] {
                    for sy in [-1.0, 1.0] {
                        let corner = w.center + c.right * sx * w.halfWidth + c.up * sy * w.halfHeight
                        let n = ndc(corner, c, position, projection)
                        XCTAssertEqual(n.x, sx, accuracy: 1e-9, "ortho \(ortho) eye \(e)")
                        XCTAssertEqual(n.y, sy, accuracy: 1e-9, "ortho \(ortho) eye \(e)")
                    }
                }
            }
        }
    }

    func testRestEyeMatchesTheNormalView() {
        let c = camera()
        let d = c.distance * 0.6
        let w = c.peekWindow(depth: d, aspect: aspect)
        let (position, projection) = c.peekCamera(window: w, eye: c.restEye(window: w, depth: d, boundsRadius: 1.2), near: 0.01, far: 100)
        XCTAssertLessThan(simd_distance(position, c.position), 1e-9)
        for p: SIMD3<Double> in [[0.5, 0.2, 0.3], [1.1, -0.4, 0.9], [-0.3, 0.6, -0.2]] {
            let n = ndc(p, c, position, projection), expected = c.project(p, aspect: aspect)
            XCTAssertEqual(n.x, expected.x, accuracy: 1e-9)
            XCTAssertEqual(n.y, expected.y, accuracy: 1e-9)
        }
    }

    func testOrthoRestEyeMatchesTheOrthoView() {
        // Zoomed in to inspect a gap: the window is small next to the model's depth.
        var c = camera(ortho: true)
        c.orthoHalfHeight = 0.06
        let d = c.distance * 0.7
        let w = c.peekWindow(depth: d, aspect: aspect)
        let (position, projection) = c.peekCamera(window: w, eye: c.restEye(window: w, depth: d, boundsRadius: 1.2),
                                                  near: 0.01, far: 1e5)
        // A point near the back of the model, off the window's centre.
        let p = w.center + c.forward * 2.4 + c.right * 0.04 + c.up * 0.03
        let n = ndc(p, c, position, projection), expected = c.project(p, aspect: aspect)
        XCTAssertEqual(n.x, expected.x, accuracy: 5e-3)
        XCTAssertEqual(n.y, expected.y, accuracy: 5e-3)
    }

    func testEyeMovesOneToOne() {
        // The eye moves as the head does, seen from the window, in proportion to the
        // distance at the press: sideways through the same angle, leaning in included.
        let rest = SIMD3<Double>(0, 0, 200)
        XCTAssertEqual(PeekWindow.eye(rest: rest, offsetCM: [0, 0, 0], distanceCM: 50, blend: 1), rest)
        XCTAssertEqual(PeekWindow.eye(rest: rest, offsetCM: [10, -5, 0], distanceCM: 50, blend: 1), SIMD3(40, -20, 200))
        XCTAssertEqual(PeekWindow.eye(rest: rest, offsetCM: [0, 0, -25], distanceCM: 50, blend: 1), SIMD3(0, 0, 100))
        XCTAssertEqual(PeekWindow.eye(rest: rest, offsetCM: [10, -5, -25], distanceCM: 50, blend: 0.5), SIMD3(20, -10, 150))
        XCTAssertEqual(PeekWindow.eye(rest: rest, offsetCM: [10, -5, -25], distanceCM: 50, blend: 0), rest)
    }

    func testParallaxDirection() {
        let c = camera()
        let d = c.distance * 0.7
        let w = c.peekWindow(depth: d, aspect: aspect)
        let rest = c.restEye(window: w, depth: d, boundsRadius: 1.2)
        let moved = rest + SIMD3(0.2 * d, 0, 0)
        let behind = w.center + c.forward * 0.5 * d, inFront = w.center - c.forward * 0.3 * d
        let a = c.peekCamera(window: w, eye: rest, near: 0.01, far: 100)
        let b = c.peekCamera(window: w, eye: moved, near: 0.01, far: 100)
        // As through a real window: what is behind the glass shifts with the head,
        // what is in front of it shifts against the head.
        XCTAssertGreaterThan(ndc(behind, c, b.position, b.projection).x, ndc(behind, c, a.position, a.projection).x)
        XCTAssertLessThan(ndc(inFront, c, b.position, b.projection).x, ndc(inFront, c, a.position, a.projection).x)
    }

    /// SceneKit must read the custom projection in the convention peekCamera writes it.
    @MainActor
    func testSceneKitAgreesWithPeekProjection() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let c = camera()
        let d = c.distance * 0.7
        let w = c.peekWindow(depth: d, aspect: aspect)
        let (position, projection) = c.peekCamera(window: w, eye: SIMD3(0.3 * d, -0.2 * d, 0.8 * d), near: 0.01, far: 100)

        let view = SCNView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), options: nil)
        let scene = SCNScene()
        let node = SCNNode()
        node.camera = SCNCamera()
        node.camera?.projectionTransform = SCNMatrix4(projection)
        node.simdPosition = SIMD3<Float>(position)
        node.simdLook(at: SIMD3<Float>(position + c.forward), up: SIMD3<Float>(c.screenUp), localFront: SIMD3(0, 0, -1))
        scene.rootNode.addChildNode(node)
        view.scene = scene
        view.pointOfView = node

        for p: SIMD3<Double> in [[0.5, 0.2, 0.3], [1.1, -0.4, 0.9], [-0.3, 0.6, -0.2]] {
            let s = view.projectPoint(SCNVector3(p.x, p.y, p.z))
            let got = SIMD2(Double(s.x) / 800 * 2 - 1, Double(s.y) / 500 * 2 - 1)
            let expected = ndc(p, c, position, projection)
            XCTAssertEqual(got.x, expected.x, accuracy: 1e-4)
            XCTAssertEqual(got.y, expected.y, accuracy: 1e-4)
        }
    }

    func testTheOrbitTargetStaysPut() {
        // The user's concept: what you orbit around stays still and the head
        // reveals its sides, so the window plane goes through the target.
        let c = camera()
        let w = c.peekWindow(depth: c.distance, aspect: aspect)
        XCTAssertLessThan(simd_distance(w.center, c.target), 1e-9)
        for e in [SIMD3(0.3, -0.2, 1.0) * c.distance, SIMD3(-0.4, 0.3, 1.4) * c.distance] {
            let (position, projection) = c.peekCamera(window: w, eye: e, near: 0.01, far: 100)
            let n = ndc(c.target, c, position, projection)
            XCTAssertEqual(n.x, 0, accuracy: 1e-9)
            XCTAssertEqual(n.y, 0, accuracy: 1e-9)
        }
    }


    func testGlassAtTheModelsFront() {
        // The window sits where the model begins, so all of it is behind the glass.
        let c = camera()
        XCTAssertEqual(c.peekDepth(center: c.target, radius: 1.2), c.distance - 1.2, accuracy: 1e-9)
        // Zoomed right into a part, the glass stops a quarter of the way to the target.
        XCTAssertEqual(c.peekDepth(center: c.target, radius: c.distance), 0.25 * c.distance, accuracy: 1e-9)
    }
}
