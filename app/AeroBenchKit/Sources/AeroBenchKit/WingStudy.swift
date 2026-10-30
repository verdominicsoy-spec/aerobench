import Foundation

/// An optimisation study as the engine exports it after every trial
/// (<study>.json beside the Optuna file), or as wing-optimise's result.
public struct WingStudy: Codable, Equatable, Sendable {
    public struct Variable: Codable, Equatable, Sendable {
        public var element: Int
        public var kind: String  // angle (degrees), gap or overlap (m)
        public var low: Double
        public var high: Double

        public init(element: Int, kind: String, low: Double, high: Double) {
            self.element = element
            self.kind = kind
            self.low = low
            self.high = high
        }

        public var name: String { "\(kind)_\(element)" }
    }

    public struct Spec: Codable, Equatable, Sendable {
        public var variables: [Variable]
        public var objective: String
        public var cdCap: Double?
        public var clTarget: Double?
        public var sampler: String

        enum CodingKeys: String, CodingKey {
            case variables, objective, sampler
            case cdCap = "cd_cap"
            case clTarget = "cl_target"
        }
    }

    public struct Placement: Codable, Equatable, Sendable {
        public var angle: Double
        public var leadingEdge: [Double]

        enum CodingKeys: String, CodingKey {
            case angle
            case leadingEdge = "leading_edge"
        }
    }

    public struct Trial: Codable, Equatable, Sendable, Identifiable {
        public var number: Int
        /// complete, fail, invalid (broke a constraint, never run), running or waiting
        public var state: String
        public var value: Double?
        public var params: [String: Double]
        public var cl: Double?
        public var cd: Double?
        public var cm: Double?
        /// Cl in the working direction: downforce for an inverted wing.
        public var load: Double?
        public var elementCl: [Double?]?
        public var feasible: Bool?
        public var converged: Bool?
        public var reason: String?
        public var placement: [Placement]?
        public var gaps: [Double]?
        public var overlaps: [Double]?
        public var seconds: Double?
        public var iterations: Int?
        public var cells: Int?

        public var id: Int { number }
        public var isResult: Bool { state == "complete" }

        enum CodingKeys: String, CodingKey {
            case number, state, value, params, cl, cd, cm, load, feasible, converged, reason, placement, gaps, overlaps,
                 seconds, iterations, cells
            case elementCl = "element_cl"
        }
    }

    public var study: String
    public var objective: String
    public var objectiveName: String
    public var direction: String  // maximize or minimize
    public var spec: Spec
    public var trials: [Trial]
    public var best: Int?
    public var complete: Int
    public var failed: Int
    public var invalid: Int?
    public var target: Int
    /// "estimate" (panel method and NeuralFoil) or "rans" (SU2); nil in studies from before the choice.
    public var solver: String?
    /// The best designs of an estimate study run again with RANS.
    public var checks: [Check]?

    public struct Check: Codable, Equatable, Sendable, Identifiable {
        public var number: Int
        public var estimateValue: Double?
        public var cl: Double?
        public var cd: Double?
        public var load: Double?
        public var value: Double?
        public var feasible: Bool?
        public var converged: Bool?
        public var reason: String?

        public var id: Int { number }

        enum CodingKeys: String, CodingKey {
            case number, cl, cd, load, value, feasible, converged, reason
            case estimateValue = "estimate_value"
        }
    }

    enum CodingKeys: String, CodingKey {
        case study, objective, direction, spec, trials, best, complete, failed, invalid, target, solver, checks
        case objectiveName = "objective_name"
    }

    /// The check RANS liked best, if any converged.
    public var bestCheck: Check? {
        let ok = (checks ?? []).filter { $0.value != nil && $0.feasible != false }
        return direction == "minimize" ? ok.min { $0.value! < $1.value! } : ok.max { $0.value! < $1.value! }
    }

    /// Dictionary keys like "angle_1" must not be touched, so no snake case
    /// strategy: the keys are spelled out above.
    public static func decode(exportFile data: Data) throws -> WingStudy {
        try JSONDecoder().decode(WingStudy.self, from: data)
    }

    public static func decode(resultFile data: Data) throws -> WingStudy {
        struct Wrapper: Decodable { var data: WingStudy }
        return try JSONDecoder().decode(Wrapper.self, from: data).data
    }

    public var bestTrial: Trial? { best.flatMap { b in trials.first { $0.number == b } } }

    /// Trials that ran and met the constraint, in order.
    public var results: [Trial] { trials.filter { $0.isResult && $0.feasible == true && $0.value != nil } }

    /// The best value after each result: the convergence plot.
    public var bestSoFar: [(trial: Int, value: Double)] {
        var out: [(trial: Int, value: Double)] = []
        var best: Double?
        for t in trials where t.isResult && t.feasible == true {
            guard let v = t.value else { continue }
            let b = best.map { direction == "minimize" ? min($0, v) : max($0, v) } ?? v
            best = b
            out.append((trial: t.number, value: b))
        }
        return out
    }

    /// Trials no other trial beats on both downforce (more) and drag (less).
    public var paretoFront: [Trial] {
        let ran = trials.filter { $0.isResult && $0.load != nil && $0.cd != nil }
        let front = ran.filter { t in
            !ran.contains { o in
                o.load! >= t.load! && o.cd! <= t.cd! && (o.load! > t.load! || o.cd! < t.cd!)
            }
        }
        return front.sorted { $0.cd! < $1.cd! }
    }
}

extension Wing {
    /// This wing with a trial's angles and leading edges: what the optimiser
    /// ran. Nil if the trial has no placement or the element count differs.
    public func applying(_ trial: WingStudy.Trial) -> Wing? {
        guard let placement = trial.placement, placement.count == elements.count else { return nil }
        var w = self
        for (i, p) in placement.enumerated() where p.leadingEdge.count == 2 {
            w.elements[i].angle = p.angle
            w.elements[i].leadingEdge = SIMD2(p.leadingEdge[0], p.leadingEdge[1])
        }
        return w
    }
}
