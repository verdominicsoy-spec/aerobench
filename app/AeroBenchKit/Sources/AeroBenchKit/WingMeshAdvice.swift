import Foundation

/// Whether more cells would make a RANS run more accurate or reliable, and why.
///
/// Two things say so. The wall cells: SU2 reports each wall point's y+, and
/// the SST model with its laminar zones (transition) needs the first cell at
/// y+ about 1, fully turbulent walls a little more leeway. And the mesh
/// levels: the same wing at the same angle on another level shows how far the
/// numbers still move when cells are added. One run on one level cannot show
/// the second, so its verdict is "can't tell yet" until a second level has run.
public struct MeshAdvice: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        case refine  // more cells would change the answer or make it more reliable
        case enough  // more cells would not change it by more than the tolerances
        case unknown  // not enough to tell: run the next level to find out
    }

    public var verdict: Verdict
    public var reasons: [String]
    /// The level to run next to check or improve it; nil on the finest.
    public var next: String?

    /// Lift within this, drag within `cdTolerance` (fractions) between levels counts as mesh-independent.
    public static let clTolerance = 0.01
    public static let cdTolerance = 0.02
    /// The 95th percentile of wall y+ above this asks for a thinner first cell.
    public static let yPlusLaminar = 1.5
    public static let yPlusTurbulent = 3.0

    /// Levels from coarse to fine; quick and coarse share a spacing.
    public static let levels = ["quick", "coarse", "medium", "fine"]

    static func rank(_ level: String) -> Int {
        switch level {
        case "quick", "coarse": 0
        case "medium": 1
        case "fine": 2
        default: 1
        }
    }

    static func nextLevel(after level: String) -> String? {
        switch rank(level) {
        case 0: "medium"
        case 1: "fine"
        default: nil
        }
    }
}

extension WingRansResult {
    /// Laminar zones in the run (transition predicted): some surface starts laminar.
    var hasLaminarZones: Bool { transition.contains { $0.contains { $0 > 0 } } }

    /// The same case as `other`: same model, angle within 0.05°, Reynolds number within 1%,
    /// over a ground or not alike, and the same outlines (`sameWing`).
    public func sameCase(as other: WingRansResult, sameWing: Bool) -> Bool {
        sameWing && model == other.model && abs((alpha ?? 0) - (other.alpha ?? 0)) < 0.05
            && abs(re - other.re) <= 0.01 * max(re, 1)
            && ((frameTurn ?? 0) != 0) == ((other.frameTurn ?? 0) != 0)
    }

    /// The mesh verdict for this run, given this wing's runs at the same angle on other levels
    /// (`others`, already matched to this case; any order).
    public func meshAdvice(others: [WingRansResult]) -> MeshAdvice {
        var reasons: [String] = []
        var refine = false, wallsOK: Bool?
        if let y = yPlus {
            let limit = hasLaminarZones ? MeshAdvice.yPlusLaminar : MeshAdvice.yPlusTurbulent
            if y.p95 > limit {
                refine = true
                wallsOK = false
                reasons.append(String(format: "Wall cells too tall: y+ up to %.1f, 95%% under %.1f; %@ needs about 1 (under %.1f). "
                                      + "Every level has the same wall cells, so a finer level will not fix this: run it again "
                                      + "on this one (the mesher now aims them thinner)",
                                      y.max, y.p95, hasLaminarZones ? "SST with laminar zones" : "SST", limit))
            } else {
                wallsOK = true
                reasons.append(String(format: "Wall cells fine: y+ 95%% under %.1f, up to %.1f", y.p95, y.max))
            }
        }
        var levelsOK: Bool?
        let rank = MeshAdvice.rank(meshLevel)
        // The nearest other level: the step that says most about this one.
        if let o = others.filter({ MeshAdvice.rank($0.meshLevel) != rank })
            .min(by: { abs(MeshAdvice.rank($0.meshLevel) - rank) < abs(MeshAdvice.rank($1.meshLevel) - rank) }) {
            let dcl = abs(cl - o.cl) / max(abs(o.cl), 1e-9), dcd = abs(cd - o.cd) / max(abs(o.cd), 1e-9)
            let moved = String(format: "Cl %.1f%%, Cd %.1f%% between the %@ and %@ meshes", 100 * dcl, 100 * dcd,
                               rank < MeshAdvice.rank(o.meshLevel) ? meshLevel : o.meshLevel,
                               rank < MeshAdvice.rank(o.meshLevel) ? o.meshLevel : meshLevel)
            if dcl <= MeshAdvice.clTolerance && dcd <= MeshAdvice.cdTolerance {
                levelsOK = true
                reasons.append("Mesh-independent enough: " + moved)
            } else {
                levelsOK = false
                refine = true
                reasons.append(rank > MeshAdvice.rank(o.meshLevel)
                    ? "Adding cells still moves it: " + moved
                    : "The finer mesh differs: " + moved + "; trust the finer run")
            }
        }
        if !converged {
            reasons.append("Not converged: more cells will not fix that; it is the flow or the solver settings")
        }
        let verdict: MeshAdvice.Verdict = refine ? .refine : (levelsOK == true && wallsOK != false) ? .enough : .unknown
        if verdict == .unknown, levelsOK == nil {
            reasons.append(MeshAdvice.nextLevel(after: meshLevel).map { "One mesh level so far: run on \($0) to see if more cells change it" }
                ?? "One mesh level so far: run on medium to compare")
        }
        // Tall wall cells are fixed by meshing again at the same level; the levels by a finer one.
        let next = wallsOK == false && levelsOK != false ? meshLevel
            : MeshAdvice.nextLevel(after: meshLevel) ?? (verdict == .unknown && levelsOK == nil ? "medium" : nil)
        return MeshAdvice(verdict: verdict, reasons: reasons, next: next)
    }
}
