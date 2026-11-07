import Foundation
import simd

/// The panel solution as a colour field for the canvas, quick enough to
/// follow every edit: Cp and speed from the inviscid flow, and Cp0 (total
/// pressure, zero in the free stream) from a wake behind each trailing edge
/// sized by that element's drag. Inviscid flow loses no total pressure, so
/// the wakes are all there is to Cp0: no boundary layer on the surface, no
/// separation, no slot effects.
extension PanelSolution {
    /// The field over a window round the elements (in the solver's frame), `nx` cells across; below the ground and inside
    /// the elements there is no flow. `wakeCd` is each element's drag on its
    /// own chord (the live estimate's); without it there is no Cp0. Nil if
    /// there are no elements or `isCancelled` turned true.
    public func field(nx: Int = 400, wakeCd: [Double]? = nil, isCancelled: @escaping () -> Bool = { false }) -> WingField? {
        let panels = VortexPanels(self)
        let flows = zip(elements, speed).filter { $0.count == $1.count && $0.count > 2 }
        let bodies = flows.map(\.0)
        guard !bodies.isEmpty, nx > 1 else { return nil }
        let all = bodies.joined()
        let lo = all.reduce(SIMD2(Double.infinity, .infinity)) { simd_min($0, $1) }
        let hi = all.reduce(SIMD2(-Double.infinity, -.infinity)) { simd_max($0, $1) }
        let span = max(hi.x - lo.x, hi.y - lo.y, 1e-6)
        // Wider than the RANS field's window, so a zoomed-out canvas stays covered.
        let x0 = lo.x - 1.0 * span, x1 = hi.x + 2.0 * span, y1 = hi.y + 0.8 * span
        let y0 = max(lo.y - 0.8 * span, ground ?? -.infinity)
        let ny = max(Int((Double(nx) * (y1 - y0) / (x1 - x0)).rounded()), 8)
        let dx = (x1 - x0) / Double(nx), dy = (y1 - y0) / Double(ny)
        let box = (x0: x0, y0: y0, x1: x1, y1: y1)
        let wakes: [Wake] = wakeCd.map { cds in
            zip(flows, cds).compactMap { Wake(body: $0.0, cd: $1, panels: panels, box: box, speed: $0.1, cell: min(dx, dy)) }
        } ?? []

        let n = nx * ny
        var cp = [Float](repeating: .nan, count: n), sp = cp, cp0 = cp
        cp.withUnsafeMutableBufferPointer { cpOut in
            sp.withUnsafeMutableBufferPointer { spOut in
                cp0.withUnsafeMutableBufferPointer { cp0Out in
                    DispatchQueue.concurrentPerform(iterations: ny) { j in
                        if isCancelled() { return }
                        let y = y0 + (Double(j) + 0.5) * dy
                        for i in 0..<nx {
                            let p = SIMD2(x0 + (Double(i) + 0.5) * dx, y)
                            if panels.inside(p) { continue }
                            let v2 = simd_length_squared(panels.velocity(at: p))
                            // Each wake's loss is set where it formed and carried down its
                            // streamline unchanged; the static pressure is the outer flow's,
                            // so the speed follows from Bernoulli on the lower total pressure.
                            let f = wakes.reduce(1.0) { $0 * (1 - $1.deficit(at: p)) }
                            let loss = f * f - 1
                            let k = j * nx + i
                            cpOut[k] = Float(1 - v2)
                            spOut[k] = Float(max(v2 + loss, 0).squareRoot())
                            cp0Out[k] = Float(loss)
                        }
                    }
                }
            }
        }
        if isCancelled() { return nil }

        // Colour ranges from the flow near the elements (the RANS field's window), not the far field's calm.
        let iLo = max(Int((lo.x - 0.3 * span - x0) / dx), 0), iHi = min(Int((hi.x + 0.8 * span - x0) / dx), nx - 1)
        let jLo = max(Int((lo.y - 0.4 * span - y0) / dy), 0), jHi = min(Int((hi.y + 0.4 * span - y0) / dy), ny - 1)
        func scalar(_ key: String, _ name: String, _ values: [Float], _ kind: Colormap) -> WingField.Scalar {
            var near: [Double] = []
            for j in jLo...jHi { for i in iLo...iHi where values[j * nx + i].isFinite { near.append(Double(values[j * nx + i])) } }
            let finite = near.sorted()
            let p1 = finite.isEmpty ? 0 : finite[Int(Double(finite.count - 1) * 0.01)]
            let p99 = finite.isEmpty ? 1 : finite[Int(Double(finite.count - 1) * 0.99)]
            var range = [p1, p99]
            if key == "cp" { let m = max(abs(p1), abs(p99), 1e-3); range = [-m, m] }  // zero in the middle, as RANS
            if key == "cp0" { range = [min(p1, -0.05), 0] }  // losses only; a floor so a clean field reads as free stream
            return .init(key: key, name: name, min: finite.first ?? 0, max: finite.last ?? 0, range: range, colormap: kind.stops)
        }
        var scalars = [scalar("cp", "Pressure coefficient Cp", cp, .diverging), scalar("speed", "Speed V/V∞", sp, .sequential)]
        var values = [cp, sp]
        if !wakes.isEmpty {
            scalars.append(scalar("cp0", "Total pressure Cp0", cp0, .sequential))
            values.append(cp0)
        }
        // Carry the flow two cells into the elements, under their solid fill, so
        // the cells cut by a surface do not show as notches along it.
        let blank = cp.map { !$0.isFinite }
        for _ in 0..<2 {
            let edge = (0..<n).filter { k in
                guard blank[k], !values[0][k].isFinite else { return false }
                let i = k % nx
                return (i > 0 && values[0][k - 1].isFinite) || (i < nx - 1 && values[0][k + 1].isFinite)
                    || (k >= nx && values[0][k - nx].isFinite) || (k + nx < n && values[0][k + nx].isFinite)
            }
            for b in values.indices {
                let old = values[b]
                for k in edge {
                    let i = k % nx
                    let around = [i > 0 ? k - 1 : -1, i < nx - 1 ? k + 1 : -1, k - nx, k + nx]
                        .filter { $0 >= 0 && $0 < n && old[$0].isFinite }.map { old[$0] }
                    values[b][k] = around.reduce(0, +) / Float(around.count)
                }
            }
        }
        return WingField(nx: nx, ny: ny, window: box, scalars: scalars, values: values)
    }
}

/// The engine's colormaps (wing/field.py), so the live field reads as the RANS one.
enum Colormap {
    case diverging, sequential

    var stops: [[Double]] {
        (0..<64).map { k in
            let t = Double(k) / 63
            switch self {
            case .diverging:
                let blue = SIMD3(0.23, 0.30, 0.75), white = SIMD3(0.95, 0.95, 0.95), red = SIMD3(0.71, 0.02, 0.15)
                let c = t < 0.5 ? blue + (white - blue) * (2 * t) : white + (red - white) * (2 * t - 1)
                return [c.x, c.y, c.z]
            case .sequential:  // viridis-like, from its endpoints and midpoints
                let s: [SIMD3<Double>] = [SIMD3(0.27, 0.00, 0.33), SIMD3(0.23, 0.32, 0.55), SIMD3(0.13, 0.57, 0.55),
                                          SIMD3(0.37, 0.79, 0.38), SIMD3(0.99, 0.91, 0.14)]
                let x = t * Double(s.count - 1), i = min(Int(x), s.count - 2)
                let c = s[i] + (s[i + 1] - s[i]) * (x - Double(i))
                return [c.x, c.y, c.z]
            }
        }
    }
}

/// One element's wake: a Gaussian velocity deficit along the inviscid
/// streamline off its trailing edge, its momentum deficit θ = Cd c / 2 (the
/// element's drag), its width growing as the plane turbulent wake's,
/// half-width 0.3 √(θ s) (Wygnanski, Champagne & Marasli 1986), from a
/// virtual origin that starts it half θ wide and stopped at its centre, as the
/// boundary layers leave the trailing edge (one RANS boundary layer reached half
/// its loss 2 mm off the wall at 60% chord; a 22 θ origin drew 12 mm).
/// Ahead of the trailing edge the loss lies along both surfaces, its width
/// growing from nothing at the nose as a turbulent boundary layer's (x^0.8),
/// thicker on the suction side, and it blends into the wake across the
/// trailing edge, so the wake has no cut start. The wake starts as lopsided
/// as the surfaces and evens out over half a chord.
struct Wake {
    private let line: [SIMD2<Double>]
    private let along: [Double]  // arc length to each point
    private let theta: Double
    private let reach: Double  // past this distance off the line the deficit is nil
    private let body: [SIMD2<Double>]
    private let fromNose: [Double]  // each body point's share of its surface, 0 at the nose to 1 at the trailing edge
    private let near: (lo: SIMD2<Double>, hi: SIMD2<Double>)  // past this box the surface loss is nil
    private let nose: Int
    private let upperWidth: Double, lowerWidth: Double  // each surface's width at the trailing edge over the wake's
    private let blend: Double  // the surfaces hand over to the wake across this distance either side of the trailing edge
    private let minSigma: Double  // a cell, so a layer thinner than the grid does not show as beads
    private let widths: [Double]  // the surface layer's σ at each body point
    private let outside: Double  // the sign of the outside's cross product with each segment (+1 left, -1 right)
    private let upperLeft: Bool  // the upper surface's side of the wake, looking downstream
    private let chord: Double

    init?(body: [SIMD2<Double>], cd: Double, panels: VortexPanels,
          box: (x0: Double, y0: Double, x1: Double, y1: Double), speed: [Double]? = nil, cell: Double = 0) {
        guard cd.isFinite, cd > 0, let first = body.first, let last = body.last else { return nil }
        let te = 0.5 * (first + last)
        guard let nose = body.indices.max(by: { simd_distance(body[$0], te) < simd_distance(body[$1], te) }) else { return nil }
        let le = body[nose]
        let chord = simd_distance(le, te)
        guard chord > 0 else { return nil }
        theta = 0.5 * cd * chord
        self.chord = chord
        // Selig order: upper trailing edge, round the nose, lower trailing edge.
        func share(_ pts: [SIMD2<Double>]) -> [Double] {
            var s = [0.0]
            for k in 1..<pts.count { s.append(s[k - 1] + simd_distance(pts[k], pts[k - 1])) }
            return s.map { $0 / max(s[s.count - 1], 1e-12) }
        }
        self.body = body
        fromNose = share(body[...nose].reversed()).reversed() + share(Array(body[nose...])).dropFirst()
        self.nose = nose
        // shortcut: the suction side (the faster one) gets the thicker layer by a fixed 1.4 : 0.6; a separation model would size it.
        if let v = speed, v.count == body.count {
            let mean = { (r: ArraySlice<Double>) in r.reduce(0) { $0 + abs($1) } / Double(max(r.count, 1)) }
            let upperFaster = mean(v[...nose]) > mean(v[nose...])
            (upperWidth, lowerWidth) = upperFaster ? (1.4, 0.6) : (0.6, 1.4)
        } else {
            (upperWidth, lowerWidth) = (1, 1)
        }
        minSigma = cell
        let sg0 = Self.sigma(theta, 0)
        let area = zip(body, body.dropFirst() + [body[0]]).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }
        outside = area > 0 ? -1 : 1  // counter-clockwise: the outside is on the right
        let (shares, up, low) = (fromNose, upperWidth, lowerWidth)
        widths = shares.indices.map { k in sg0 * (k <= nose ? up : low) * pow(shares[k], 0.8) }
        blend = max(Self.sigma(theta, 0), cell)
        let pad = SIMD2(repeating: 5 * max(Self.sigma(theta, 0) * 1.4, cell))
        near = (body.reduce(le, simd_min) - pad, body.reduce(le, simd_max) + pad)
        // Off the trailing edge along the chord, then down the inviscid flow,
        // in shorter steps past another element so it slides by, not into it.
        var p = te + 0.01 * chord * (te - le) / chord
        var pts = [te, p]
        let out = p - te
        upperLeft = out.x * (first.y - te.y) - out.y * (first.x - te.x) > 0
        march: for _ in 0..<2000 {
            var h = min(max(0.3 * panels.distance(p), 0.002 * chord), 0.02 * chord)
            for _ in 0..<3 {
                guard let d1 = panels.direction(p), let d2 = panels.direction(p + 0.5 * h * d1) else { break march }
                let q = p + h * d2
                if q.x < box.x0 || q.x > box.x1 || q.y < box.y0 || q.y > box.y1 { break march }
                if !panels.inside(q) {
                    pts.append(q)
                    p = q
                    continue march
                }
                h /= 4
            }
            break
        }
        line = pts
        var s = [0.0]
        for k in 1..<pts.count { s.append(s[k - 1] + simd_distance(pts[k], pts[k - 1])) }
        along = s
        reach = 5 * Self.sigma(theta, s.last ?? 0)
    }

    /// Where the traced wake ends.
    var end: SIMD2<Double> { line[line.count - 1] }

    /// σ of the Gaussian: half-width 0.3 √(θ (s + s0)) over √(2 ln 2), with s0 = 4 θ.
    private static func sigma(_ theta: Double, _ s: Double) -> Double {
        0.255 * (theta * (s + 4 * theta)).squareRoot()
    }

    /// The velocity deficit (0 none, 1 stopped) at a point: the surfaces' ahead of the
    /// trailing edge, the wake's past it, blended smoothly across it.
    func deficit(at p: SIMD2<Double>) -> Double {
        let d = line[1] - line[0]
        let x = simd_dot(p - line[0], d) / max(simd_length(d), 1e-12) / blend
        let w = x <= -1 ? 0 : x >= 1 ? 1 : 0.5 + 0.75 * x - 0.25 * x * x * x  // smoothstep over -1...1
        return (w < 1 ? (1 - w) * surfaceDeficit(at: p) : 0) + (w > 0 ? w * wakeDeficit(at: p) : 0)
    }

    /// Off the line traced from the trailing edge (ahead of it, off its start); 0 off the wake.
    private func wakeDeficit(at p: SIMD2<Double>) -> Double {
        var best = Double.infinity, s = 0.0, beyond = false, left = true
        for k in 1..<line.count {
            let a = line[k - 1], d = line[k] - a
            let l2 = simd_length_squared(d)
            guard l2 > 0 else { continue }
            let t = simd_dot(p - a, d) / l2
            let c = min(max(t, 0), 1)
            let gap = simd_distance(p, a + c * d)
            if gap < best {
                best = gap
                s = along[k - 1] + c * l2.squareRoot()
                beyond = k == line.count - 1 && t > 1  // past its end
                left = d.x * (p.y - a.y) - d.y * (p.x - a.x) > 0
            }
        }
        guard !beyond, best < reach else { return 0 }
        let sg = Self.sigma(theta, s)
        let side = left == upperLeft ? upperWidth : lowerWidth
        return Self.shown(Self.amplitude(theta, sg), sg * (1 + (side - 1) * exp(-s / (0.5 * chord))), best, minSigma)
    }

    /// Off the nearest surface, the wake's starting profile narrowed towards the nose.
    private func surfaceDeficit(at p: SIMD2<Double>) -> Double {
        guard p.x > near.lo.x, p.y > near.lo.y, p.x < near.hi.x, p.y < near.hi.y else { return 0 }
        // The strongest over every segment, each at its own width: the nearest point alone
        // jumps along a concave surface, and its width with it, which drew a step.
        var score = Double.infinity  // -ln(deficit / amplitude), least wins
        for k in 1...body.count {  // the last closes a blunt trailing edge, lower corner to upper
            let (i, n) = k < body.count ? (k - 1, k) : (body.count - 1, 0)
            let a = body[i], d = body[n] - a
            let l2 = simd_length_squared(d)
            guard l2 > 0 else { continue }
            // Only from its own side, or a thick layer at one trailing edge corner wraps round the other.
            guard outside * (d.x * (p.y - a.y) - d.y * (p.x - a.x)) >= 0 else { continue }
            let c = min(max(simd_dot(p - a, d) / l2, 0), 1)
            let sg = widths[i] + c * (widths[n] - widths[i])
            guard sg > 1e-12 else { continue }
            let w = max(sg, minSigma)
            let here = simd_distance_squared(p, a + c * d) / (2 * w * w) - (sg < w ? log(sg / w) : 0)
            score = min(score, here)
        }
        return score.isFinite ? Self.amplitude(theta, Self.sigma(theta, 0)) * exp(-score) : 0
    }

    /// A Gaussian of centre `amp` and width σ at distance n, drawn at least `least` wide
    /// and as much fainter, so a layer thinner than a cell neither beads nor rings.
    private static func shown(_ amp: Double, _ sg: Double, _ n: Double, _ least: Double) -> Double {
        let w = max(sg, least)
        guard w > 1e-12 else { return 0 }
        return amp * (sg / w) * exp(-n * n / (2 * w * w))
    }

    /// The centre deficit A carrying momentum θ at width σ: ∫ u (1 - u) dn = θ with
    /// u = 1 - A exp(-n²/2σ²), so A σ √(2π) - A² σ √π = θ.
    private static func amplitude(_ theta: Double, _ sg: Double) -> Double {
        let b = sg * (2 * Double.pi).squareRoot(), a2 = sg * Double.pi.squareRoot()
        let disc = b * b - 4 * a2 * theta
        return min(disc >= 0 ? (b - disc.squareRoot()) / (2 * a2) : 1, 1)
    }
}
