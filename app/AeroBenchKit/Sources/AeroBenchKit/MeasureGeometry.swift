import Foundation
import simd

/// The edges a measure can snap to on a mesh: where faces meet at a sharp
/// angle, and open edges. Vertices are welded by position first, since
/// STEP tessellations and STL do not share vertices between faces.
public struct FeatureEdges: Sendable {
    public struct Circle: Equatable, Sendable {
        public var centre: SIMD3<Double>
        public var radius: Double
        public var normal: SIMD3<Double>

        public init(centre: SIMD3<Double>, radius: Double, normal: SIMD3<Double>) {
            self.centre = centre
            self.radius = radius
            self.normal = normal
        }

        public func transformed(_ m: simd_float4x4) -> Circle {
            let c = m * SIMD4<Float>(SIMD3<Float>(centre), 1), n = m * SIMD4<Float>(SIMD3<Float>(normal), 0)
            let r = m * SIMD4<Float>(Float(radius), 0, 0, 0)  // scale only; CAD transforms are rigid
            return Circle(centre: SIMD3(Double(c.x), Double(c.y), Double(c.z)),
                          radius: Double(simd_length(SIMD3(r.x, r.y, r.z))),
                          normal: simd_normalize(SIMD3(Double(n.x), Double(n.y), Double(n.z))))
        }
    }

    /// Polylines in the mesh's own frame, split at corners; a closed one ends where it starts.
    public let chains: [[SIMD3<Double>]]
    /// Per chain, the circle it lies on, when it is an arc or a full circle.
    public let circles: [Circle?]

    public init(mesh: TriangleMesh, angleDegrees: Double = 25, cornerDegrees: Double = 35) {
        let pos = mesh.positions.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
        guard !pos.isEmpty else { chains = []; circles = []; return }
        let lo = pos.reduce(pos[0]) { simd_min($0, $1) }, hi = pos.reduce(pos[0]) { simd_max($0, $1) }
        let q = max(simd_length(hi - lo), 1e-9) * 1e-6
        var weld = [SIMD3<Int64>: Int](), pts: [SIMD3<Double>] = []
        let id = pos.map { p -> Int in
            let k = SIMD3<Int64>(Int64((p.x / q).rounded()), Int64((p.y / q).rounded()), Int64((p.z / q).rounded()))
            if let i = weld[k] { return i }
            weld[k] = pts.count
            pts.append(p)
            return pts.count - 1
        }
        // Each edge's triangles' normals.
        var faces: [SIMD2<Int>: [SIMD3<Double>]] = [:]
        var t = 0
        while t + 2 < mesh.indices.count {
            let a = id[Int(mesh.indices[t])], b = id[Int(mesh.indices[t + 1])], c = id[Int(mesh.indices[t + 2])]
            t += 3
            guard a != b, b != c, a != c else { continue }
            let n = simd_cross(pts[b] - pts[a], pts[c] - pts[a])
            guard simd_length(n) > 0 else { continue }
            for (u, v) in [(a, b), (b, c), (c, a)] { faces[SIMD2(min(u, v), max(u, v)), default: []].append(simd_normalize(n)) }
        }
        let cosSharp = cos(angleDegrees * .pi / 180)
        var next: [Int: [Int]] = [:]
        for (e, ns) in faces where ns.count != 2 || simd_dot(ns[0], ns[1]) < cosSharp {
            next[e.x, default: []].append(e.y)
            next[e.y, default: []].append(e.x)
        }
        // Walk the edge graph into polylines, from ends and branches first, then the loops left.
        var used = Set<SIMD2<Int>>()
        func key(_ a: Int, _ b: Int) -> SIMD2<Int> { SIMD2(min(a, b), max(a, b)) }
        var walks: [[Int]] = []
        let starts = next.keys.filter { next[$0]!.count != 2 }.sorted() + next.keys.sorted()
        for s in starts {
            for first in next[s]! where !used.contains(key(s, first)) {
                var walk = [s, first]
                used.insert(key(s, first))
                while let at = walk.last, next[at]!.count == 2, at != s,
                      let n = next[at]!.first(where: { !used.contains(key(at, $0)) }) {
                    used.insert(key(at, n))
                    walk.append(n)
                }
                walks.append(walk)
            }
        }
        // Split at corners, so a face's outline is its straight sides.
        let cosCorner = cos(cornerDegrees * .pi / 180)
        var out: [[SIMD3<Double>]] = []
        for w in walks {
            let p = w.map { pts[$0] }
            let closed = w.count > 3 && w.first == w.last
            func corner(_ i: Int) -> Bool {
                let a = p[i] - p[i - 1], b = p[i + 1] - p[i]
                return simd_dot(simd_normalize(a), simd_normalize(b)) < cosCorner
            }
            var cuts = p.count > 2 ? (1..<(p.count - 1)).filter(corner) : []
            if closed, p.count > 3 {
                let a = p[p.count - 1] - p[p.count - 2], b = p[1] - p[0]
                if simd_dot(simd_normalize(a), simd_normalize(b)) >= cosCorner, let c = cuts.first {
                    // The loop's start is not a corner: start it at the first one instead.
                    let body = Array(p[c..<(p.count - 1)]) + Array(p[0...c])
                    cuts = cuts.dropFirst().map { $0 - c }
                    out += Self.split(body, at: cuts)
                    continue
                }
            }
            out += Self.split(p, at: cuts)
        }
        chains = out
        circles = out.map(Self.circle(through:))
    }

    private static func split(_ p: [SIMD3<Double>], at cuts: [Int]) -> [[SIMD3<Double>]] {
        var out: [[SIMD3<Double>]] = [], from = 0
        for c in cuts + [p.count - 1] where c > from {
            out.append(Array(p[from...c]))
            from = c
        }
        return out
    }

    /// The circle a polyline lies on: plane by Newell's method, then a least-squares
    /// circle in it. Nil when the points are straight, too few, or not on a circle
    /// within 1% of its radius, or the arc turns less than 20°.
    public static func circle(through p: [SIMD3<Double>]) -> Circle? {
        let pts = p.count > 1 && p.first == p.last ? Array(p.dropLast()) : p
        guard pts.count >= 4 else { return nil }
        let c0 = pts.reduce(.zero, +) / Double(pts.count)
        var n = SIMD3<Double>.zero
        let loop = pts + [pts[0]]
        for (a, b) in zip(loop, loop.dropFirst()) { n += simd_cross(a - c0, b - c0) }
        guard simd_length(n) > 1e-12 else { return nil }
        n = simd_normalize(n)
        let u = simd_normalize(simd_cross(abs(n.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0), n)), v = simd_cross(n, u)
        // Kasa fit: x² + y² + D x + E y + F = 0.
        var m = simd_double3x3(), r = SIMD3<Double>.zero
        for p in pts {
            let x = simd_dot(p - c0, u), y = simd_dot(p - c0, v), row = SIMD3(x, y, 1)
            m += simd_double3x3(rows: [row * x, row * y, row])
            r -= row * (x * x + y * y)
        }
        guard abs(m.determinant) > 1e-30 else { return nil }
        let s = m.inverse * r
        let cx = -s.x / 2, cy = -s.y / 2, rad2 = cx * cx + cy * cy - s.z
        guard rad2 > 0 else { return nil }
        let radius = rad2.squareRoot(), centre = c0 + cx * u + cy * v
        guard pts.allSatisfy({ abs(simd_distance($0, centre) - radius) <= 0.01 * radius }) else { return nil }
        var turn = 0.0
        for (a, b) in zip(p, p.dropFirst()) {
            turn += acos(max(-1, min(1, simd_dot(simd_normalize(a - centre), simd_normalize(b - centre)))))
        }
        return turn >= 20 * .pi / 180 ? Circle(centre: centre, radius: radius, normal: n) : nil
    }
}

/// Where a measuring click lands: a feature point near the cursor, else a
/// point on an edge near it, else the surface under it.
public struct MeasureSnap: Equatable, Sendable {
    public enum Kind: String, Sendable { case vertex, midpoint, centre, edge, surface }
    public var kind: Kind
    public var point: SIMD3<Double>

    public init(kind: Kind, point: SIMD3<Double>) {
        self.kind = kind
        self.point = point
    }

    /// `chains` and `circles` in world space; `project` gives view points with depth (0 near, 1 far) in z,
    /// and `screen`, when given, is `chains` already projected.
    /// Feature points snap within `pointRadius`, edges within `edgeRadius`, both in view points.
    public static func choose(cursor: SIMD2<Double>, surface: SIMD3<Double>?, surfaceDepth: Double?,
                              chains: [[SIMD3<Double>]], circles: [FeatureEdges.Circle?],
                              project: (SIMD3<Double>) -> SIMD3<Double>, screen cached: [[SIMD3<Double>]]? = nil,
                              pointRadius: Double = 10, edgeRadius: Double = 7) -> MeasureSnap? {
        func visible(_ s: SIMD3<Double>) -> Bool { surfaceDepth.map { s.z <= $0 + 1e-3 } ?? true }
        var best: (MeasureSnap, Double)?
        let screen = cached ?? chains.map { $0.map(project) }
        func offer(_ kind: Kind, _ p: SIMD3<Double>, _ projected: SIMD3<Double>? = nil, mustBeVisible: Bool = true) {
            let s = projected ?? project(p)
            let d = simd_distance(SIMD2(s.x, s.y), cursor)
            guard d <= pointRadius, !mustBeVisible || visible(s), d < (best?.1 ?? .infinity) else { return }
            best = (MeasureSnap(kind: kind, point: p), d)
        }
        for (k, (chain, circle)) in zip(chains, circles).enumerated() {
            guard let first = chain.first, let last = chain.last else { continue }
            if first != last {
                offer(.vertex, first, screen[k].first)
                offer(.vertex, last, screen[k].last)
                if circle == nil {  // an arc's midpoint is not where the eye looks; its centre is offered instead
                    offer(.midpoint, 0.5 * (first + last))
                }
            }
            if let c = circle { offer(.centre, c.centre, mustBeVisible: false) }  // a hole's centre is in the air
        }
        if let b = best { return b.0 }
        if let k = EdgePick.nearest(screen, to: cursor, within: edgeRadius, surfaceDepth: surfaceDepth) {
            var pick: (SIMD3<Double>, Double)?
            for (i, (a, b)) in zip(screen[k], screen[k].dropFirst()).enumerated() {
                let a2 = SIMD2(a.x, a.y), ab = SIMD2(b.x - a.x, b.y - a.y)
                let t = simd_dot(ab, ab) > 0 ? min(max(simd_dot(cursor - a2, ab) / simd_dot(ab, ab), 0), 1) : 0
                let d = simd_length(cursor - (a2 + t * ab))
                if d < (pick?.1 ?? .infinity) { pick = (chains[k][i] + t * (chains[k][i + 1] - chains[k][i]), d) }
            }
            if let p = pick { return MeasureSnap(kind: .edge, point: p.0) }
        }
        return surface.map { MeasureSnap(kind: .surface, point: $0) }
    }
}
