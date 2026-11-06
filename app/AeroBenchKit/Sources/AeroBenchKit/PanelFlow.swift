import Foundation
import simd

/// The flow of a panel solution off the surface: the velocity anywhere from
/// the linear vortex panels (and their image in the ground), and rough
/// streamlines traced through it. Inviscid: no boundary layer, wake or separation.
extension PanelSolution {
    /// Velocity over freestream at a point in the solver's frame.
    public func velocity(at p: SIMD2<Double>) -> SIMD2<Double> { VortexPanels(self).velocity(at: p) }

    /// Streamlines in the solver's frame, seeded upstream across the elements'
    /// height and half as much again above and below, each traced with
    /// midpoint RK2 until it leaves the box round the elements, meets the
    /// ground, a stagnation point or a body. `isCancelled` is checked per line.
    public func streamlines(count: Int = 24, isCancelled: () -> Bool = { false }) -> [[SIMD2<Double>]] {
        let panels = VortexPanels(self)
        guard !panels.nodes.isEmpty, count > 0 else { return [] }
        let lo0 = panels.nodes.reduce(SIMD2(Double.infinity, .infinity)) { simd_min($0, $1) }
        let hi0 = panels.nodes.reduce(SIMD2(-Double.infinity, -.infinity)) { simd_max($0, $1) }
        let size = max(hi0.x - lo0.x, hi0.y - lo0.y, 1e-6)
        var lo = lo0 - SIMD2(0.5, 0.5) * size
        let hi = hi0 + SIMD2(0.8, 0.5) * size
        if let g = ground { lo.y = max(lo.y, g) }
        let minStep = 0.003 * size, maxStep = 0.04 * size, near = 0.001 * size
        var lines: [[SIMD2<Double>]] = []
        for k in 0..<count {
            if isCancelled() { return [] }
            var p = SIMD2(lo.x, lo.y + (hi.y - lo.y) * (Double(k) + 0.5) / Double(count))
            var line = [p]
            for _ in 0..<3000 {
                let gap = panels.distance(p)
                if gap < near { break }
                let h = min(max(0.3 * gap, minStep), maxStep)
                guard let d1 = panels.direction(p), let d2 = panels.direction(p + 0.5 * h * d1) else { break }
                let q = p + h * d2
                if q.x < lo.x || q.x > hi.x || q.y < lo.y || q.y > hi.y || panels.inside(q) { break }
                line.append(q)
                p = q
            }
            if line.count > 1 { lines.append(line) }
        }
        return lines
    }
}

/// The solution's panels ready for velocity sums: each panel's start, its
/// run, the strengths at its ends and +1 (or -1 for the ground's image).
struct VortexPanels {
    private var start: [SIMD2<Double>] = [], run: [SIMD2<Double>] = []
    private var gammaA: [Double] = [], gammaB: [Double] = [], sign: [Double] = []
    private(set) var nodes: [SIMD2<Double>] = []
    private let bodies: [[SIMD2<Double>]]
    private let freestream: SIMD2<Double>

    init(_ s: PanelSolution) {
        let a = s.alphaDeg * Double.pi / 180
        freestream = SIMD2(cos(a), sin(a))
        bodies = zip(s.elements, s.speed).filter { $0.count == $1.count && $0.count > 2 }.map(\.0)
        for (pts, g) in zip(s.elements, s.speed) where pts.count == g.count && pts.count > 2 {
            nodes += pts
            for j in 0..<(pts.count - 1) {
                add(pts[j], pts[j + 1], g[j], g[j + 1], 1)
                if let y = s.ground {  // the image: mirrored, opposite vorticity
                    add(SIMD2(pts[j].x, 2 * y - pts[j].y), SIMD2(pts[j + 1].x, 2 * y - pts[j + 1].y), g[j], g[j + 1], -1)
                }
            }
        }
    }

    private mutating func add(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ ga: Double, _ gb: Double, _ s: Double) {
        guard simd_length_squared(b - a) > 0 else { return }
        start.append(a); run.append(b - a); gammaA.append(ga); gammaB.append(gb); sign.append(s)
    }

    /// Velocity over freestream: w = u - iv = (i / 2 pi) integral of gamma / (z - zeta) ds
    /// along each panel (the stream function the solver uses, psi = gamma ln r / 2 pi),
    /// in closed form near the panel and as a point vortex further than five panel lengths.
    func velocity(at z: SIMD2<Double>) -> SIMD2<Double> {
        var v = freestream
        for i in start.indices {
            let d = run[i], c = z - start[i], e = c - d
            let l2 = simd_length_squared(d)
            let mid = c - 0.5 * d
            let m2 = simd_length_squared(mid)
            if m2 > 25 * l2 {
                let circulation = sign[i] * sqrt(l2) * 0.5 * (gammaA[i] + gammaB[i])
                v += circulation / (2 * Double.pi * m2) * SIMD2(mid.y, -mid.x)
                continue
            }
            let c2 = simd_length_squared(c), e2 = simd_length_squared(e)
            guard c2 > 0, e2 > 0 else { continue }
            // ln((z - a) / (z - b)): the log of the distances and the angle the panel subtends.
            let ln = SIMD2(0.5 * log(c2 / e2), atan2(e.x * c.y - e.y * c.x, e.x * c.x + e.y * c.y))
            let dBar = SIMD2(d.x, -d.y)
            let cOverD = Self.mul(c, dBar) / l2
            var t = gammaA[i] * ln + (gammaB[i] - gammaA[i]) * (Self.mul(cOverD, ln) - SIMD2(1, 0))
            t = Self.mul(t, dBar) / sqrt(l2)  // times L / D
            // w = i t / 2 pi; (u, v) = (Re w, -Im w)
            v += sign[i] / (2 * Double.pi) * SIMD2(-t.y, -t.x)
        }
        return v
    }

    /// The flow's direction, or nil at a stagnation point.
    func direction(_ p: SIMD2<Double>) -> SIMD2<Double>? {
        let v = velocity(at: p)
        let n = simd_length(v)
        return n > 1e-3 ? v / n : nil
    }

    /// Distance to the nearest surface node.
    func distance(_ p: SIMD2<Double>) -> Double {
        nodes.reduce(Double.infinity) { min($0, simd_length_squared($1 - p)) }.squareRoot()
    }

    /// Whether a point is inside any element (even-odd rule).
    func inside(_ p: SIMD2<Double>) -> Bool {
        bodies.contains { pts in
            var inside = false
            var j = pts.count - 1
            for i in pts.indices {
                let a = pts[i], b = pts[j]
                if (a.y > p.y) != (b.y > p.y), p.x < a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y) { inside.toggle() }
                j = i
            }
            return inside
        }
    }

    private static func mul(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x)
    }
}
