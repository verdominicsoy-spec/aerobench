import Accelerate
import simd
import Foundation
import os

/// The inviscid preview's result at one angle of attack, per element.
public struct PanelSolution: Sendable {
    public let alphaDeg: Double
    /// Surface speed over freestream at each node (signed along the Selig order).
    public let speed: [[Double]]
    public let cp: [[Double]]
    public let cl: [Double]
    public let cd: [Double]
    public let cm: [Double]
    /// The elements (the solver's frame) and the ground the strengths belong to,
    /// so the velocity can be had anywhere; empty for a solution made by hand.
    public var elements: [[SIMD2<Double>]] = []
    public var ground: Double? = nil
    /// Each element's circulation was set to give the lift asked of it, in place
    /// of the Kutta condition: the flow is right away from the trailing edges, and
    /// singular right at them (see `PanelSolver.solve(alphaDeg:targetCl:)`).
    public var liftMatched = false

    public var clTotal: Double { cl.reduce(0, +) }
    public var cmTotal: Double { cm.reduce(0, +) }
}

/// Multi-element linear-vorticity panel method, the same formulation as the
/// engine's wing/panel.py (XFOIL's stream function with a constant psi and
/// a Kutta condition per element). The influence matrix is factorised once
/// per geometry; each angle of attack is then one back substitution.
///
/// Elements are point lists in Selig order (trailing edge, upper surface,
/// leading edge, lower surface, trailing edge) in one shared frame.
public final class PanelSolver: @unchecked Sendable {
    public let elements: [[SIMD2<Double>]]
    public let refChord: Double
    public let refPoint: SIMD2<Double>

    private let nodes: [SIMD2<Double>]  // all elements, about their centroid
    private let starts: [Int]
    private let sizes: [Int]
    private let sharp: [Bool]
    private let order: Int
    private var factors: [Double]
    private var pivots: [__CLPK_integer]
    /// The matrix before factorising, for the lift-matched system (built on first use).
    private let unfactorised: [Double]
    private let matched = OSAllocatedUnfairLock<(lu: [Double], piv: [__CLPK_integer])??>(initialState: nil)

    /// A trailing edge gap below this fraction of chord counts as closed.
    static let sharpFraction = 1e-4

    /// The height (y) of a ground plane along x, the flow's direction, or nil.
    public let ground: Double?

    /// Nil if an element has fewer than six points or the system is
    /// singular (elements on top of each other). With `ground` the flow must
    /// run along x (solve at alpha 0, turning the wing instead): the ground is
    /// an image wing of opposite vorticity mirrored in it, as in the engine.
    public init?(elements: [[SIMD2<Double>]], refChord: Double? = nil, refPoint: SIMD2<Double>? = nil, ground: Double? = nil) {
        guard !elements.isEmpty, elements.allSatisfy({ $0.count >= 6 }) else { return nil }
        self.elements = elements
        self.ground = ground
        let all = elements.flatMap { $0 }
        let centre = all.reduce(SIMD2<Double>(0, 0), +) / Double(all.count)
        nodes = all.map { $0 - centre }
        sizes = elements.map(\.count)
        var s: [Int] = []
        var acc = 0
        for n in sizes { s.append(acc); acc += n }
        starts = s
        let m = all.count, k = elements.count
        order = m + k
        let n = order

        var a = [Double](repeating: 0, count: n * n)  // column-major
        Self.fillPsi(&a, n: n, field: nodes, panels: nodes, starts: starts, sizes: sizes, sign: 1, selfTerms: true)
        if let ground {
            let g = ground - centre.y
            let images = nodes.map { SIMD2($0.x, 2 * g - $0.y) }
            Self.fillPsi(&a, n: n, field: nodes, panels: images, starts: starts, sizes: sizes, sign: -1, selfTerms: false)
        }
        var sharpFlags: [Bool] = []
        for e in 0..<k {
            let st = starts[e], sz = sizes[e]
            for i in st..<(st + sz) { a[i + (m + e) * n] = -1 }  // psi = psi_k on this element
            let pts = elements[e]
            let te = (pts[0] + pts[sz - 1]) / 2
            let chord = pts.map { simd_length($0 - te) }.max() ?? 1
            let isSharp = simd_length(pts[0] - pts[sz - 1]) < Self.sharpFraction * chord
            sharpFlags.append(isSharp)
            if isSharp {  // the last node repeats the first: extrapolate gamma there instead
                let row = st + sz - 1
                for c in 0..<n { a[row + c * n] = 0 }
                a[row + st * n] += 1
                a[row + (st + 1) * n] += -2
                a[row + (st + 2) * n] += 1
                a[row + (st + sz - 1) * n] += -1
                a[row + (st + sz - 2) * n] += 2
                a[row + (st + sz - 3) * n] += -1
            }
            a[(m + e) + st * n] = 1  // Kutta: gamma first + gamma last = 0
            a[(m + e) + (st + sz - 1) * n] = 1
        }
        sharp = sharpFlags
        unfactorised = a

        var rows = __CLPK_integer(n), cols = __CLPK_integer(n), lda = __CLPK_integer(n), info = __CLPK_integer(0)
        var piv = [__CLPK_integer](repeating: 0, count: n)
        dgetrf_(&rows, &cols, &a, &lda, &piv, &info)
        guard info == 0 else { return nil }
        factors = a
        pivots = piv

        let main = elements[0]
        let te = (main[0] + main[main.count - 1]) / 2
        var le = main[0]
        var far = 0.0
        for p in main where simd_length(p - te) > far { far = simd_length(p - te); le = p }
        self.refChord = refChord ?? far
        self.refPoint = refPoint ?? (le + 0.25 * (te - le))
    }

    /// d psi / d gamma at every field node from every element's linear vortex
    /// panels (XFOIL's PSILIN), added into the top-left m x m block times
    /// `sign`. Images (sign -1) never sit on a field node, so no self terms.
    private static func fillPsi(_ a: inout [Double], n: Int, field: [SIMD2<Double>], panels: [SIMD2<Double>],
                                starts: [Int], sizes: [Int], sign: Double, selfTerms: Bool) {
        let q = sign / (4 * Double.pi)
        for i in 0..<field.count {
            let p = field[i]
            for (st, sz) in zip(starts, sizes) {
                for j in 0..<(sz - 1) {
                    let ja = st + j, jb = st + j + 1
                    let pa = panels[ja], pb = panels[jb]
                    let d = pb - pa
                    let len = simd_length(d)
                    let sx = d.x / len, sy = d.y / len
                    let r1 = p - pa, r2 = p - pb
                    let x1 = sx * r1.x + sy * r1.y
                    let x2 = sx * r2.x + sy * r2.y
                    let yy = sx * r1.y - sy * r1.x
                    let rs1 = x1 * x1 + yy * yy, rs2 = x2 * x2 + yy * yy
                    let sgn: Double = yy >= 0 ? 1 : -1
                    var g1 = 0.0, t1 = 0.0, g2 = 0.0, t2 = 0.0
                    if !(selfTerms && i == ja) && rs1 > 0 {
                        g1 = log(rs1)
                        t1 = atan2(sgn * x1, sgn * yy) + (0.5 - 0.5 * sgn) * Double.pi
                    }
                    if !(selfTerms && i == jb) && rs2 > 0 {
                        g2 = log(rs2)
                        t2 = atan2(sgn * x2, sgn * yy) + (0.5 - 0.5 * sgn) * Double.pi
                    }
                    let psis = 0.5 * x1 * g1 - 0.5 * x2 * g2 + x2 - x1 + yy * (t1 - t2)
                    let psid = ((x1 + x2) * psis + 0.5 * (rs2 * g2 - rs1 * g1 + x1 * x1 - x2 * x2)) / (x1 - x2)
                    a[i + ja * n] += q * (psis - psid)
                    a[i + jb * n] += q * (psis + psid)
                }
            }
        }
    }

    public func solve(alphaDeg: Double) -> PanelSolution {
        forces(backSolve(alphaDeg: alphaDeg, lu: factors, piv: pivots, circulation: nil), alphaDeg: alphaDeg)
    }

    /// The flow with each element's lift set to `targetCl` instead of by the
    /// Kutta condition: each element's circulation is prescribed, started from
    /// the Kutta solution's and scaled three times by target / achieved lift
    /// (clamped to 0.3...1.5), leaving alone an element whose achieved or target
    /// lift is within 0.02 of zero (the ratio means nothing there). The Kutta
    /// solution when the targets do not fit (count, NaN) or the system is singular.
    public func solve(alphaDeg: Double, targetCl: [Double]) -> PanelSolution {
        let kutta = solve(alphaDeg: alphaDeg)
        guard targetCl.count == elements.count, targetCl.allSatisfy(\.isFinite), let f = matchedFactors() else { return kutta }
        var circulation = (0..<elements.count).map { e in
            let pts = elements[e], g = kutta.speed[e]
            return (0..<(pts.count - 1)).reduce(0.0) { $0 + 0.5 * (g[$1] + g[$1 + 1]) * simd_distance(pts[$1], pts[$1 + 1]) }
        }
        var out = kutta
        for _ in 0..<3 {
            for e in circulation.indices where abs(out.cl[e]) > 0.02 && abs(targetCl[e]) > 0.02 {
                circulation[e] *= min(max(targetCl[e] / out.cl[e], 0.3), 1.5)
            }
            out = forces(backSolve(alphaDeg: alphaDeg, lu: f.lu, piv: f.piv, circulation: circulation), alphaDeg: alphaDeg)
        }
        guard out.cl.allSatisfy(\.isFinite), out.cp.allSatisfy({ $0.allSatisfy(\.isFinite) }) else { return kutta }
        out.liftMatched = true
        return out
    }

    /// The lift-matched system's factors: each Kutta row replaced by the
    /// element's circulation, the sum over its panels of half the end strengths
    /// times the panel's length. Nil if singular.
    private func matchedFactors() -> (lu: [Double], piv: [__CLPK_integer])? {
        matched.withLock { state in
            if let done = state { return done }
            var a = unfactorised
            let n = order, m = nodes.count
            for e in 0..<elements.count {
                let row = m + e, st = starts[e], pts = elements[e]
                for c in 0..<n { a[row + c * n] = 0 }
                for j in 0..<(sizes[e] - 1) {
                    let h = 0.5 * simd_distance(pts[j], pts[j + 1])
                    a[row + (st + j) * n] += h
                    a[row + (st + j + 1) * n] += h
                }
            }
            var rows = __CLPK_integer(n), cols = __CLPK_integer(n), lda = __CLPK_integer(n), info = __CLPK_integer(0)
            var piv = [__CLPK_integer](repeating: 0, count: n)
            dgetrf_(&rows, &cols, &a, &lda, &piv, &info)
            let done: (lu: [Double], piv: [__CLPK_integer])? = info == 0 ? (a, piv) : nil
            state = .some(done)
            return done
        }
    }

    /// Node strengths then each element's psi: the freestream psi rows, the
    /// sharp-edge rows, and in each element's last row its circulation (matched)
    /// or zero (Kutta).
    private func backSolve(alphaDeg: Double, lu: [Double], piv: [__CLPK_integer], circulation: [Double]?) -> [Double] {
        let al = alphaDeg * Double.pi / 180
        let ca = cos(al), sa = sin(al)
        let m = nodes.count
        var rhs = [Double](repeating: 0, count: order)
        for i in 0..<m { rhs[i] = -(ca * nodes[i].y - sa * nodes[i].x) }  // freestream psi, V = 1
        for (e, isSharp) in sharp.enumerated() where isSharp { rhs[starts[e] + sizes[e] - 1] = 0 }
        if let circulation { for (e, g) in circulation.enumerated() { rhs[m + e] = g } }
        var nn = __CLPK_integer(order), one = __CLPK_integer(1), lda = __CLPK_integer(order), ldb = __CLPK_integer(order)
        var info = __CLPK_integer(0)
        var trans = Int8(UInt8(ascii: "N"))
        var lu = lu
        var piv = piv
        dgetrs_(&trans, &nn, &one, &lu, &lda, &piv, &rhs, &ldb, &info)
        return rhs
    }

    /// Surface speed, Cp and the pressure forces from the solved strengths.
    private func forces(_ rhs: [Double], alphaDeg: Double) -> PanelSolution {
        let al = alphaDeg * Double.pi / 180
        let ca = cos(al), sa = sin(al)
        let wind = SIMD2(ca, sa), liftDir = SIMD2(-sa, ca)
        var speed: [[Double]] = [], cps: [[Double]] = [], cls: [Double] = [], cds: [Double] = [], cms: [Double] = []
        for e in 0..<elements.count {
            let st = starts[e], sz = sizes[e]
            let g = Array(rhs[st..<(st + sz)])
            let cp = g.map { 1 - $0 * $0 }
            let pts = elements[e]
            var force = SIMD2<Double>(0, 0)
            var moment = 0.0
            for j in 0..<(sz - 1) {
                let d = pts[j + 1] - pts[j]
                let cpm = 0.5 * (cp[j] + cp[j + 1])
                let f = -cpm * SIMD2(d.y, -d.x)  // outward normal (Selig order runs counter-clockwise)
                force += f
                let r = 0.5 * (pts[j] + pts[j + 1]) - refPoint
                moment += r.x * f.y - r.y * f.x
            }
            force /= refChord
            speed.append(g)
            cps.append(cp)
            cls.append(simd_dot(force, liftDir))
            cds.append(simd_dot(force, wind))
            cms.append(-moment / (refChord * refChord))  // nose up positive
        }
        return PanelSolution(alphaDeg: alphaDeg, speed: speed, cp: cps, cl: cls, cd: cds, cm: cms, elements: elements, ground: ground)
    }
}

/// The ground effect RANS holds, as the engine's estimate.ground_share: the
/// image method's lift gain over free air grows without limit as the gap
/// under the wing closes, while RANS's peaks near +70% and falls.
public enum GroundEffect {
    public static let share = 0.8, knee = 1.6

    /// The share of the image method's gain over free air that holds.
    public static func share(gain: Double) -> Double { share / (1 + pow(max(gain, 0) / knee, 3)) }
}

extension PanelSolution {
    /// This solution over a ground with each element's lift and moment kept to
    /// the share of the image's gain over `free` (the same wing in free air) that RANS holds.
    public func groundCorrected(free: PanelSolution) -> PanelSolution {
        guard free.cl.count == cl.count, abs(free.clTotal) > 0.05 else { return self }
        let s = GroundEffect.share(gain: clTotal / free.clTotal - 1)
        return PanelSolution(alphaDeg: alphaDeg, speed: speed, cp: cp,
                             cl: zip(cl, free.cl).map { $1 + s * ($0 - $1) }, cd: cd,
                             cm: zip(cm, free.cm).map { $1 + s * ($0 - $1) }, elements: elements, ground: ground)
    }
}
