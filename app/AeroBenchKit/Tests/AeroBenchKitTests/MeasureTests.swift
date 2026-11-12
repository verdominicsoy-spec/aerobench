import XCTest
import simd
@testable import AeroBenchKit

final class MeasureTests: XCTestCase {
    /// A box as faceted CAD gives it: each face its own vertices, as STEP
    /// tessellations and STL have them.
    private func box(_ size: SIMD3<Float>) -> TriangleMesh {
        let c = (0..<8).map { i in SIMD3<Float>(i & 1 == 0 ? 0 : size.x, i & 2 == 0 ? 0 : size.y, i & 4 == 0 ? 0 : size.z) }
        let quads = [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]
        var tris: [SIMD3<Float>] = []
        for q in quads { tris += [c[q[0]], c[q[1]], c[q[2]], c[q[0]], c[q[2]], c[q[3]]] }
        return .flatShaded(triangles: tris)
    }

    /// A disc's rim as the tessellator draws it, with a centre fan.
    private func disc(radius: Float, segments: Int, centre: SIMD3<Float> = .zero) -> TriangleMesh {
        var tris: [SIMD3<Float>] = []
        for i in 0..<segments {
            let a = Float(i) / Float(segments) * 2 * .pi, b = Float(i + 1) / Float(segments) * 2 * .pi
            tris += [centre, centre + radius * SIMD3(cos(a), sin(a), 0), centre + radius * SIMD3(cos(b), sin(b), 0)]
        }
        return TriangleMesh(positions: tris, normals: [], indices: (0..<UInt32(tris.count)).map { $0 })
    }

    func testABoxHasTwelveStraightEdges() {
        let edges = FeatureEdges(mesh: box([0.1, 0.2, 0.3]))
        XCTAssertEqual(edges.chains.count, 12, "the diagonals inside each face are not edges")
        let lengths = edges.chains.map { zip($0, $0.dropFirst()).map { simd_distance($0, $1) }.reduce(0, +) }.sorted()
        for (l, want) in zip(lengths, [0.1, 0.1, 0.1, 0.1, 0.2, 0.2, 0.2, 0.2, 0.3, 0.3, 0.3, 0.3]) {
            XCTAssertEqual(l, want, accuracy: 1e-6)
        }
        XCTAssertTrue(edges.circles.allSatisfy { $0 == nil })
    }

    func testARimIsOneClosedCircle() throws {
        let edges = FeatureEdges(mesh: disc(radius: 0.025, segments: 48, centre: [0.1, 0, 0]))
        XCTAssertEqual(edges.chains.count, 1)
        XCTAssertEqual(edges.chains[0].first, edges.chains[0].last, "closed")
        let c = try XCTUnwrap(edges.circles[0])
        XCTAssertEqual(c.radius, 0.025, accuracy: 1e-4)
        XCTAssertEqual(simd_distance(c.centre, [0.1, 0, 0]), 0, accuracy: 1e-6)
        XCTAssertEqual(abs(c.normal.z), 1, accuracy: 1e-9)
    }

    func testSnapPrefersCornersThenEdgesThenSurface() {
        // Screen = world x, y scaled by 1000 (1 mm per point); depth 0.5 everywhere.
        let project: (SIMD3<Double>) -> SIMD3<Double> = { SIMD3($0.x * 1000, $0.y * 1000, 0.5) }
        let chain: [SIMD3<Double>] = [[0, 0, 0], [0.1, 0, 0]]
        let circle = FeatureEdges.Circle(centre: [0.05, 0.05, 0], radius: 0.02, normal: [0, 0, 1])
        let ring = (0...24).map { i -> SIMD3<Double> in
            let a = Double(i % 24) / 24 * 2 * .pi
            return circle.centre + 0.02 * SIMD3(cos(a), sin(a), 0)
        }
        func snap(_ x: Double, _ y: Double) -> MeasureSnap {
            MeasureSnap.choose(cursor: SIMD2(x, y), surface: [x / 1000, y / 1000, 0], surfaceDepth: 0.5,
                               chains: [chain, ring], circles: [nil, circle], project: project)!
        }
        XCTAssertEqual(snap(3, 4).kind, .vertex)
        XCTAssertEqual(snap(3, 4).point, [0, 0, 0])
        XCTAssertEqual(snap(52, 3).kind, .midpoint)
        XCTAssertEqual(snap(52, 3).point, [0.05, 0, 0])
        XCTAssertEqual(snap(30, 4).kind, .edge)
        XCTAssertEqual(snap(30, 4).point.x, 0.03, accuracy: 1e-12)
        XCTAssertEqual(snap(30, 4).point.y, 0, accuracy: 1e-12)
        XCTAssertEqual(snap(48, 52).kind, .centre)
        XCTAssertEqual(snap(30, 30).kind, .surface)
    }

    func testAngleAndPointToPlane() {
        XCTAssertEqual(Measure.angle([1, 0, 0], [0, 0, 0], [0, 2, 0]), 90, accuracy: 1e-9)
        XCTAssertEqual(Measure.angle([1, 0, 0], [0, 0, 0], [1, 1, 0]), 45, accuracy: 1e-9)
        let (d, foot) = Measure.toPlane([1, 2, 5], point: [0, 0, 2], normal: [0, 0, 3])
        XCTAssertEqual(d, 3, accuracy: 1e-12)
        XCTAssertEqual(foot, [1, 2, 2])
    }
}
