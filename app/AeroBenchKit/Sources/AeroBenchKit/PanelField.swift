import Foundation
import simd

/// The panel solution as a colour field for the canvas, quick enough to
/// follow every edit: Cp and speed from the inviscid flow, and Cp0 (total
/// pressure, zero in the free stream) from a wake behind each trailing edge
/// sized by that element's drag. Inviscid flow loses no total pressure, so
/// the wakes are all there is to Cp0: no boundary layer on the surface, no
/// separation, no slot effects.
extension PanelSolution {
    /// The field over a window round the elements (as the RANS field's, in
    /// the solver's frame), `nx` cells across; below the ground and inside
    /// the elements there is no flow. `wakeCd` is each element's drag on its
    /// own chord (the live estimate's); without it there is no Cp0. Nil if
    /// there are no elements or `isCancelled` turned true.
    public func field(nx: Int = 320, wakeCd: [Double]? = nil, isCancelled: @escaping () -> Bool = { false }) -> WingField? {
        let panels = VortexPanels(self)
        let bodies = zip(elements, speed).filter { $0.count == $1.count && $0.count > 2 }.map(\.0)
        guard !bodies.isEmpty, nx > 1 else { return nil }
        let all = bodies.joined()
        let lo = all.reduce(SIMD2(Double.infinity, .infinity)) { simd_min($0, $1) }
        let hi = all.reduce(SIMD2(-Double.infinity, -.infinity)) { simd_max($0, $1) }
        let span = max(hi.x - lo.x, hi.y - lo.y, 1e-6)
        let x0 = lo.x - 0.3 * span, x1 = hi.x + 0.8 * span, y1 = hi.y + 0.4 * span
        let y0 = max(lo.y - 0.4 * span, ground ?? -.infinity)
        let ny = max(Int((Double(nx) * (y1 - y0) / (x1 - x0)).rounded()), 8)
        let dx = (x1 - x0) / Double(nx), dy = (y1 - y0) / Double(ny)
        let box = (x0: x0, y0: y0, x1: x1, y1: y1)
        let wakes: [Wake] = wakeCd.map { cds in
            zip(bodies, cds).compactMap { Wake(body: $0, cd: $1, panels: panels, box: box) }
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
                            // The wakes slow the flow at the static pressure the outer flow sets.
                            let f = wakes.reduce(1.0) { $0 * (1 - $1.deficit(at: p)) }
                            let k = j * nx + i
                            cpOut[k] = Float(1 - v2)
                            spOut[k] = Float(v2.squareRoot() * f)
                            cp0Out[k] = Float(v2 * (f * f - 1))
                        }
                    }
                }
            }
        }
        if isCancelled() { return nil }

        func scalar(_ key: String, _ name: String, _ values: [Float], _ kind: Colormap) -> WingField.Scalar {
            let finite = values.filter(\.isFinite).map(Double.init).sorted()
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
/// virtual origin that starts it about θ wide with a deficit about 0.5.
struct Wake {
    private let line: [SIMD2<Double>]
    private let along: [Double]  // arc length to each point
    private let theta: Double
    private let reach: Double  // past this distance off the line the deficit is nil

    init?(body: [SIMD2<Double>], cd: Double, panels: VortexPanels,
          box: (x0: Double, y0: Double, x1: Double, y1: Double)) {
        guard cd.isFinite, cd > 0, let first = body.first, let last = body.last else { return nil }
        let te = 0.5 * (first + last)
        guard let le = body.max(by: { simd_distance($0, te) < simd_distance($1, te) }) else { return nil }
        let chord = simd_distance(le, te)
        guard chord > 0 else { return nil }
        theta = 0.5 * cd * chord
        // Off the trailing edge along the chord, then down the inviscid flow.
        var p = te + 0.01 * chord * (te - le) / chord
        var pts = [te, p]
        let h = 0.02 * chord
        for _ in 0..<2000 {
            guard let d1 = panels.direction(p), let d2 = panels.direction(p + 0.5 * h * d1) else { break }
            let q = p + h * d2
            if q.x < box.x0 || q.x > box.x1 || q.y < box.y0 || q.y > box.y1 || panels.inside(q) { break }
            pts.append(q)
            p = q
        }
        line = pts
        var s = [0.0]
        for k in 1..<pts.count { s.append(s[k - 1] + simd_distance(pts[k], pts[k - 1])) }
        along = s
        reach = 5 * Self.sigma(theta, s.last ?? 0)
    }

    /// σ of the Gaussian: half-width 0.3 √(θ (s + s0)) over √(2 ln 2), with s0 = 22 θ.
    private static func sigma(_ theta: Double, _ s: Double) -> Double {
        0.255 * (theta * (s + 22 * theta)).squareRoot()
    }

    /// The velocity deficit (0 none, 1 stopped) at a point, 0 off the wake or upstream of the trailing edge.
    func deficit(at p: SIMD2<Double>) -> Double {
        var best = Double.infinity, s = 0.0
        for k in 1..<line.count {
            let a = line[k - 1], d = line[k] - a
            let l2 = simd_length_squared(d)
            guard l2 > 0 else { continue }
            let t = simd_dot(p - a, d) / l2
            if k == 1, t < 0 { continue }  // ahead of the trailing edge
            let c = min(max(t, 0), 1)
            let gap = simd_distance(p, a + c * d)
            if gap < best { best = gap; s = along[k - 1] + c * l2.squareRoot() }
        }
        guard best < reach else { return 0 }
        let sg = Self.sigma(theta, s)
        // Momentum deficit ∫ u (1 - u) dn = θ with u = 1 - A exp(-n²/2σ²): A σ √(2π) - A² σ √π = θ.
        let b = sg * (2 * Double.pi).squareRoot(), a2 = sg * Double.pi.squareRoot()
        let disc = b * b - 4 * a2 * theta
        let amp = disc >= 0 ? (b - disc.squareRoot()) / (2 * a2) : 1
        return min(amp, 1) * exp(-best * best / (2 * sg * sg))
    }
}
