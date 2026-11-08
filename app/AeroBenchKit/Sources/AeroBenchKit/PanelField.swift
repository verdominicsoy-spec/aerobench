import Foundation
import simd

/// The panel solution as a colour field for the canvas, quick enough to
/// follow every edit: Cp and speed from the inviscid flow, and Cp0 (total
/// pressure, zero in the free stream) from a wake behind each trailing edge
/// sized by that element's drag. Inviscid flow loses no total pressure, so
/// the wakes are all there is to Cp0: no boundary layer on the surface, no
/// separation, no slot effects.
extension PanelSolution {
    /// An element's own drag past which its flow is separated: the live field draws it as
    /// this much and says it cannot show it (the highest in six converged RANS runs was 0.142).
    public static let attachedCdLimit = 0.15

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
                            // Each layer and wake carries the total pressure it lost where it
                            // formed, Ue² (u² - 1) with u its speed over its own edge speed Ue (a
                            // layer stopped where the outer flow runs at 1.5 U∞ loses 2.25 q∞, as
                            // RANS shows); the speed follows from Bernoulli at the outer static pressure.
                            let loss = max(wakes.reduce(0.0) { $0 + $1.loss(at: p) }, -v2)
                            let k = j * nx + i
                            cpOut[k] = Float(1 - v2)
                            spOut[k] = Float((v2 + loss).squareRoot())
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

/// One element's loss: its boundary layers and its wake, from its drag.
///
/// The momentum deficit far downstream, θ = Cd c / 2, is smaller at the
/// trailing edge by Squire & Young's factor Ue^3.2 (Ue the outer speed there),
/// and that is split between the surfaces, the suction side (the faster one)
/// taking the larger share. Each surface's layer is a half Gaussian stopped at
/// the wall, u/Ue = 1 - exp(-y²/2σ²), which carries 0.367 σ of momentum, so its
/// σ at the trailing edge is that side's θ over 0.367, thinning towards the nose
/// as x^0.8. RANS draws layers and near wakes this way: a deep core that ends
/// within a few millimetres, no wide faint skirt.
///
/// The wake leaves along the inviscid streamline from the trailing edge. It
/// starts as the two layers side by side, stopped at the centre, and over a few
/// layer thicknesses becomes the Gaussian far wake, its θ following Squire &
/// Young down the outer flow, its width growing as the plane turbulent wake's
/// (Wygnanski, Champagne & Marasli 1986) from the narrowest Gaussian that carries
/// θ (1.13 θ, centre deficit 1/√2): against six RANS wakes behind high-lift
/// wings, mean width error 18% (see LiveFieldValidationTests). Layers and wake combine by the larger deficit: no plane hands
/// one to the other, so nothing is cut along a line.
struct Wake {
    private let line: [SIMD2<Double>]
    private let along: [Double]  // arc length to each point
    private let thetas: [Double]  // θ at each point of the line: θ∞ / Ue^3.2 (Squire & Young)
    private let ues: [Double]  // the outer speed at each point of the line
    private let surfaceUe: [Double]  // the outer speed at each body point
    private let theta: Double  // far downstream, from the drag
    private let reach: Double  // past this distance off the line the wake's deficit is nil
    private let segmentWidth: [Double]  // the widest σ drawn off each segment
    private let body: [SIMD2<Double>]
    private let near: (lo: SIMD2<Double>, hi: SIMD2<Double>)  // past this box the layers' deficit is nil
    private let upperSigma: Double, lowerSigma: Double  // each layer's σ at the trailing edge
    private let sigmas: [Double]  // the layer's σ at each body point
    private let cell: Double  // a layer thinner than this is drawn this thick and as much fainter
    private let outside: Double  // the sign of the outside's cross product with each segment (+1 left, -1 right)
    private let upperLeft: Bool  // the upper surface's side of the wake, looking downstream
    private let upperShare: Double  // the upper surface's share of θ
    private let chord: Double

    /// The suction side's share of the trailing edge's θ (RANS puts the wake's centre on
    /// that side by about this much); the near wake's handover to the far wake, in layer σ;
    /// Squire & Young's exponent (H + 5) / 2 with H = 1.4.
    static let suctionShare = 0.85, handover = 8.0, squireYoung = 3.2

    /// σ over θ for a half Gaussian stopped at the wall: ∫ u (1 - u) dy = (√2π - √π) σ / 2.
    static let sigmaOverTheta = 1 / 0.367

    init?(body: [SIMD2<Double>], cd: Double, panels: VortexPanels,
          box: (x0: Double, y0: Double, x1: Double, y1: Double), speed: [Double]? = nil, cell: Double = 0) {
        guard cd.isFinite, cd > 0, let first = body.first, let last = body.last else { return nil }
        let te = 0.5 * (first + last)
        guard let nose = body.indices.max(by: { simd_distance(body[$0], te) < simd_distance(body[$1], te) }) else { return nil }
        let le = body[nose]
        let chord = simd_distance(le, te)
        guard chord > 0 else { return nil }
        // Past an attached element's drag (the highest in six converged RANS runs was 0.142)
        // it separates, which this model cannot draw: drawn as the most an attached one carries.
        theta = 0.5 * min(cd, PanelSolution.attachedCdLimit) * chord
        self.chord = chord
        self.cell = cell
        self.body = body
        // Selig order: upper trailing edge, round the nose, lower trailing edge.
        func share(_ pts: [SIMD2<Double>]) -> [Double] {
            var s = [0.0]
            for k in 1..<pts.count { s.append(s[k - 1] + simd_distance(pts[k], pts[k - 1])) }
            return s.map { $0 / max(s[s.count - 1], 1e-12) }
        }
        let fromNose = share(body[...nose].reversed()).reversed() + share(Array(body[nose...])).dropFirst()
        // shortcut: the suction side (the faster one) takes up to 85% of θ; a boundary-layer solve would split it.
        var up = 0.5
        if let v = speed, v.count == body.count {
            let mean = { (r: ArraySlice<Double>) in r.reduce(0) { $0 + abs($1) } / Double(max(r.count, 1)) }
            // Even on a symmetric section at no lift, the full share once one side runs a
            // quarter faster than the mean; continuous between, so nothing jumps as lift passes zero.
            let (mu, ml) = (mean(v[...nose]), mean(v[nose...]))
            let lean = min(max((mu - ml) / max(0.25 * (mu + ml), 1e-9), -1), 1)
            up = 0.5 + (Self.suctionShare - 0.5) * lean
        }
        upperShare = up
        let area = zip(body, body.dropFirst() + [body[0]]).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }
        outside = area > 0 ? -1 : 1  // counter-clockwise: the outside is on the right
        // Off the trailing edge down the inviscid flow there (along the chord if it stalls),
        // in shorter steps past another element so it slides by, not into it.
        let probe = te + 0.002 * (te - le)
        var p = te + 0.01 * chord * (panels.direction(probe) ?? (te - le) / chord)
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
        // Thinned where it runs straight (each point costs every cell a distance): a point is kept
        // where the line has turned 2° since the last kept one, or every 5% of a chord.
        var kept = [pts[0]]
        for k in 1..<pts.count {
            let last = kept[kept.count - 1]
            guard k < pts.count - 1, kept.count > 1 else { kept.append(pts[k]); continue }
            let before = simd_normalize(last - kept[kept.count - 2]), next = simd_normalize(pts[k + 1] - last)
            if simd_distance(pts[k + 1], last) > 0.05 * chord || simd_dot(before, next) < cos(2 * Double.pi / 180) { kept.append(pts[k]) }
        }
        pts = kept
        line = pts
        var s = [0.0]
        for k in 1..<pts.count { s.append(s[k - 1] + simd_distance(pts[k], pts[k - 1])) }
        along = s
        // Ue down the wake from the inviscid flow; over the first 5% of a chord it is held at
        // its value there (the flow right at a trailing edge is singular when its lift is
        // prescribed). The layers at the trailing edge are thinner than the far wake by
        // Squire & Young's factor, Ue^3.2.
        let settle = 0.05 * chord
        let k0 = s.firstIndex { $0 >= settle } ?? (s.count - 1)
        let ue0 = simd_length(panels.velocity(at: pts[k0]))
        let th = theta, sy = Self.squireYoung
        let thetaAt = { (u: Double) in min(th / pow(min(max(u, 0.5), 3), sy), 2 * th) }
        let speeds = s.indices.map { k in k >= k0 ? simd_length(panels.velocity(at: pts[k])) : ue0 }
        ues = speeds
        thetas = speeds.map(thetaAt)
        // The outer speed along each surface, smoothed over five nodes and held over the last 5%
        // of chord at its value there (the speed spikes at the trailing edge node).
        if let v = speed, v.count == body.count {
            let held = { (k: Int) -> Int in
                guard fromNose[k] > 0.95 else { return k }
                return k <= nose ? (k...nose).first { fromNose[$0] <= 0.95 } ?? k : (nose...k).last { fromNose[$0] <= 0.95 } ?? k
            }
            let raw = v.indices.map { abs(v[held($0)]) }
            surfaceUe = raw.indices.map { k in
                let w = raw[max(k - 2, 0)...min(k + 2, raw.count - 1)]
                return w.reduce(0, +) / Double(w.count)
            }
        } else {
            surfaceUe = Array(repeating: 1, count: body.count)
        }
        let thetaTE = thetaAt(ue0)
        upperSigma = Self.sigmaOverTheta * up * thetaTE
        lowerSigma = Self.sigmaOverTheta * (1 - up) * thetaTE
        let (ud, ld) = (upperSigma, lowerSigma)
        // An attached layer's θ grows as x^0.8 from the nose; drag past an attached
        // section's (Cd 0.012 for the whole section) comes from separation, so that
        // excess thickens only the aft part (x^4), not the nose.
        let attached = min(1, 0.012 / min(cd, PanelSolution.attachedCdLimit))
        sigmas = fromNose.indices.map { k in
            let x = fromNose[k]
            return (k <= nose ? ud : ld) * (attached * pow(x, 0.8) + (1 - attached) * pow(x, 4))
        }
        let pad = SIMD2(repeating: 5 * max(ud, ld, cell))
        near = (body.reduce(le, simd_min) - pad, body.reduce(le, simd_max) + pad)
        let ths = thetas, minWidth = max(ud, ld, cell)
        let widths = s.indices.map { k in max(2 * Self.farSigma(ths[k], s[k]), minWidth) }
        segmentWidth = widths
        reach = 5 * (widths.max() ?? cell)
    }

    /// Where the traced wake ends.
    var end: SIMD2<Double> { line[line.count - 1] }

    /// The plane turbulent wake's growth in σ: half-width 0.3 √(θ s) over √(2 ln 2).
    private static func lawSigma(_ theta: Double, _ s: Double) -> Double {
        0.255 * (theta * s).squareRoot()
    }

    /// The far wake's σ: from the narrowest Gaussian that carries θ, growing by the law.
    static func farSigma(_ theta: Double, _ s: Double) -> Double {
        theta / 0.886 + lawSigma(theta, s)
    }

    /// The velocity deficit (0 none, 1 stopped) at a point: the larger of the
    /// layers' and the wake's.
    func deficit(at p: SIMD2<Double>) -> Double {
        max(surfaceDeficit(at: p).d, wakeDeficit(at: p).d)
    }

    /// Its total-pressure loss at a point, as Cp0 (≤ 0): the larger of the layers' and the wake's,
    /// each the largest over its segments of Ue² (u² - 1) at that segment's own Ue.
    func loss(at p: SIMD2<Double>) -> Double {
        min(surfaceDeficit(at: p).loss, wakeDeficit(at: p).loss)
    }

    /// Ue² (u² - 1) for a deficit d at outer speed ue.
    private static func lossOf(_ d: Double, _ ue: Double) -> Double { ue * ue * ((1 - d) * (1 - d) - 1) }

    /// A Gaussian deficit of centre `amp` and width σ at distance n, drawn at least
    /// a cell wide and as much fainter (a layer thinner than the grid would bead).
    private func gauss(_ n: Double, _ amp: Double, _ sg: Double) -> Double {
        let w = max(sg, cell)
        guard w > 1e-12 else { return 0 }
        return amp * (sg / w) * exp(-n * n / (2 * w * w))
    }

    /// Off the line traced from the trailing edge: the two layers side by side,
    /// becoming the Gaussian far wake. Ahead of the trailing edge it fades out
    /// within a cell, under the layers.
    private func wakeDeficit(at p: SIMD2<Double>) -> (d: Double, loss: Double) {
        // The strongest over every segment near the nearest, each at its own s, θ and Ue:
        // the nearest alone jumps across the inside of a bend, and drew rays.
        withUnsafeTemporaryAllocation(of: (gap: Double, t: Double).self, capacity: line.count) { gaps in
        var best = Double.infinity
        for k in 1..<line.count {
            gaps[k] = Self.gap(p, line[k - 1], line[k])
            best = min(best, gaps[k].gap)
        }
        guard best < reach else { return (0, 0) }
        var most = 0.0, least = 0.0
        for k in 1..<line.count {
            let a = line[k - 1], d = line[k] - a
            let g = gaps[k]
            // Past 3 of its own widths a segment adds under 1%; nothing past the wake's end.
            guard g.gap <= best + 3 * segmentWidth[k], !(k == line.count - 1 && g.t > 1) else { continue }
            let c = min(max(g.t, 0), 1), len = simd_length(d)
            let s = along[k - 1] + c * len
            let th = thetas[k - 1] + c * (thetas[k] - thetas[k - 1])
            // Which side: ±1 beside the segment, blending through 0 off its ends, so the
            // two sides' widths meet without a step along the segment's extended line.
            let v = p - (a + c * d)
            let sine = (d.x * v.y - d.y * v.x) / max(len * simd_length(v), 1e-12)
            let w = 0.5 + 0.5 * (upperLeft ? sine : -sine)  // the upper side's weight
            // Near: the layers as they left the trailing edge, stopped at the centre (ahead of it,
            // a round cap). Far: the Gaussian carrying θ, as lopsided as the layers at first.
            let side = 2 * (w * upperShare + (1 - w) * (1 - upperShare))
            let farSg = Self.farSigma(th, s) * (1 + (side - 1) * exp(-s / (0.5 * chord)))
            let nearSg = w * upperSigma + (1 - w) * lowerSigma
            let lam = 1 - exp(-s / max(Self.handover * 0.5 * (upperSigma + lowerSigma), cell))
            let here = gauss(g.gap, (1 - lam) + lam * Self.amplitude(th, Self.farSigma(th, s)), (1 - lam) * nearSg + lam * farSg)
            most = max(most, here)
            least = min(least, Self.lossOf(here, ues[k - 1] + c * (ues[k] - ues[k - 1])))
        }
        return (most, least)
        }
    }

    /// Distance from p to the segment a-b, and where along it (t, 0 at a, 1 at b) p projects.
    private static func gap(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> (gap: Double, t: Double) {
        let d = b - a, l2 = simd_length_squared(d)
        guard l2 > 0 else { return (simd_distance(p, a), 0) }
        let t = simd_dot(p - a, d) / l2
        return (simd_distance(p, a + min(max(t, 0), 1) * d), t)
    }

    /// Off the nearest surface, on its outer side: the 1/7-power layer at that point's δ.
    private func surfaceDeficit(at p: SIMD2<Double>) -> (d: Double, loss: Double) {
        guard p.x > near.lo.x, p.y > near.lo.y, p.x < near.hi.x, p.y < near.hi.y else { return (0, 0) }
        var most = 0.0, least = 0.0
        for k in 1..<body.count {  // a blunt trailing edge's face is the wake's: its cap covers it
            let (i, n) = (k - 1, k)
            let a = body[i], d = body[n] - a
            let l2 = simd_length_squared(d)
            guard l2 > 0 else { continue }
            // From its own side; behind it (inside, or through a thin trailing edge to the other
            // side) it fades out within a cell, so a thick layer neither wraps round nor cuts off.
            let outward = outside * (d.x * (p.y - a.y) - d.y * (p.x - a.x)) / l2.squareRoot()
            let soft = max(cell, 0.001)
            let behind = outward < 0 ? exp(-outward * outward / (2 * soft * soft)) : 1
            guard behind > 1e-4 else { continue }
            let t = simd_dot(p - a, d) / l2
            let c = min(max(t, 0), 1)
            let sg = sigmas[i] + c * (sigmas[n] - sigmas[i])
            // Past the trailing edge the loss is the wake's: the layer tapers out over its own width.
            let over = i == 0 && t < 0 ? -t : n == body.count - 1 && t > 1 ? t - 1 : 0
            let taper = over > 0 ? exp(-over * over * l2 / (2 * pow(max(sg, cell, 1e-12), 2) / 4)) : 1
            let off = simd_distance(p, a + c * d)
            guard off < 5 * max(sg, cell) else { continue }  // under e^-12 of it
            let here = behind * taper * gauss(off, 1, sg)
            most = max(most, here)
            least = min(least, Self.lossOf(here, surfaceUe[i] + c * (surfaceUe[n] - surfaceUe[i])))
        }
        return (most, least)
    }

    /// The centre deficit A carrying momentum θ at width σ: ∫ u (1 - u) dn = θ with
    /// u = 1 - A exp(-n²/2σ²), so A σ √(2π) - A² σ √π = θ (the smaller root; σ ≥ θ / 0.886).
    private static func amplitude(_ theta: Double, _ sg: Double) -> Double {
        let b = sg * (2 * Double.pi).squareRoot(), a2 = sg * Double.pi.squareRoot()
        let disc = max(b * b - 4 * a2 * theta, 0)
        return min((b - disc.squareRoot()) / (2 * a2), 1)
    }
}
