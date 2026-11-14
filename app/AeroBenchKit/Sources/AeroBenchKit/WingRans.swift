import Foundation
import simd

/// An SU2 RANS run from the engine's wing-rans command.
public struct WingRansResult: Codable, Equatable, Sendable {
    public struct Mesh: Codable, Equatable, Sendable {
        public var cells: Int
        public var triangles: Int
        public var quads: Int
        public var layers: Int
        public var firstCellHeightM: Double
        public var layerThicknessM: Double
        public var minGapM: Double?
    }

    public struct Element: Codable, Equatable, Sendable {
        public var marker: String
        public var cl: Double?
        public var cd: Double?
        public var cmz: Double?
    }

    public struct Surface: Codable, Equatable, Sendable {
        public var x: [Double]
        public var y: [Double]
        public var cp: [Double]
        /// "upper" or "lower" for each point, in order around the element.
        public var side: [String]?
        /// Skin friction along the flow at each point, negative where it is reversed (rans_version 3).
        public var cf: [Double]?
    }

    public struct Attempt: Codable, Equatable, Sendable {
        public var cfl: Double
        public var scheme: String?
        public var outcome: String
    }

    public var re: Double
    public var mesh: Mesh
    public var meshLevel: String
    public var transition: [[Double]]
    public var model: String
    public var modelName: String
    public var iterations: Int
    public var converged: Bool
    /// Converged on average: it hit the iteration cap wobbling about a steady answer, so its
    /// numbers are the means of the last window (su2.settled); `reason` says how far Cl swings.
    public var averaged: Bool?
    /// No steady answer: the flow itself moves (separation or shedding that wanders). Not converged;
    /// Cl and Cd are the means of the run's last half and `reason` says how far Cl swings.
    public var unsteady: Bool?
    /// Numbers to use: converged, or the mean of an unsteady flow.
    public var usable: Bool { converged || unsteady == true }
    public var residualDrop: Double
    public var reason: String?
    public var cl: Double
    public var cd: Double
    /// Cd less the friction a fully turbulent model adds by having no laminar runs (flat-plate
    /// estimate, engine's laminar_saving): nearer a tunnel at low Reynolds number. Nil with a transition model.
    public var cdLaminar: Double?
    public var cm: Double?
    public var elements: [Element]
    public var surface: [Surface]
    public var field: String?
    /// field.json (with field.bin) in the run folder: the flow resampled for the app's field view.
    public var fieldView: String?
    /// The wing angle of the run (degrees); in a sweep, also its folder and how long it took.
    public var alpha: Double?
    /// Degrees the wing was turned before meshing (over a ground, minus its
    /// angle, so the ground lies along the flow). The surface and the field are
    /// in that turned frame; `toWing` and `toRun` map between it and the wing's.
    public var frameTurn: Double?
    public var folder: String?
    public var seconds: Double?
    public var cfl: Double?
    /// "jst" (the default) or "fds", the more dissipative fallback whose drag reads high.
    public var scheme: String?
    public var attempts: [Attempt]?
    /// The wall cells' y+ as SU2 reported it (max, 95th percentile, mean); nil before it was recorded.
    public struct YPlus: Codable, Equatable, Sendable {
        public var max: Double
        public var p95: Double
        public var mean: Double
    }
    public var yPlus: YPlus?

    /// One reversed-flow region (engine's rans.regions): which element and surface,
    /// whether that surface carries the suction or the pressure, its kind
    /// ("leading-edge bubble", "leading-edge stall", "bubble", "trailing-edge separation")
    /// and where it runs, as fractions of the element's chord.
    public struct Region: Codable, Equatable, Sendable {
        public var element: Int
        public var surface: String
        public var loaded: String
        public var kind: String
        public var start: Double
        public var end: Double
    }
    /// The run as the wing sits on the car (engine's rans.solve_finite): the section at the angle the
    /// flow meets it there, from a vortex lattice on span, endplates and the ground (lifting line before 14 Nov 2026).
    public struct Finite: Codable, Equatable, Sendable {
        public struct TwoD: Codable, Equatable, Sendable {
            public var cl: Double
            public var cd: Double
            public var separated: Bool?
            public var separation: String?
            public var converged: Bool?
        }
        public var alphaEffective: Double
        public var inducedAngle: Double
        public var aspectRatioEffective: Double
        public var groundFactor: Double
        public var solves: Int
        public var converged: Bool
        public var cdInduced: Double
        public var span: Double
        public var endplate: Double
        /// The 2D section at its full angle (runs before 13 Nov 2026 only: now the loop starts from the estimate).
        public var twoD: TwoD?
        /// Why the loop stopped early: a solve that did not converge (its Cl is not a result to steer by).
        public var stopped: String?
        /// The endplates' lower edge over the ground (m), as sent; nil, level with the wing's lowest point.
        public var endplateBottom: Double?
        /// What set the induced angle: "vortex lattice"; nil on runs before 14 Nov 2026 (lifting line).
        public var model: String?
        /// Two solves either side of the answer, 0.25° or less apart, that never settled: the section's
        /// Cl jumps between them (a stall), so no single angle is the answer on the car.
        public struct Cliff: Codable, Equatable, Sendable {
            public var low: Double
            public var high: Double
            public var clLow: Double
            public var clHigh: Double
            public init(low: Double, high: Double, clLow: Double, clHigh: Double) {
                self.low = low; self.high = high; self.clLow = clLow; self.clHigh = clHigh
            }
        }
        public var cliff: Cliff?
    }
    /// Whether RANS says the wing separates, and where in words; nil on runs from before the check was saved.
    public var separated: Bool?
    public var separation: String?
    public var regions: [Region]?
    /// Turbulence intensity half a chord ahead of the wing (fraction), and the engine's RANS setup version.
    public var tuAtWing: Double?
    public var ransVersion: Int?
    public var finite: Finite?
    /// The same wing fully turbulent (SST) beside a transition run, and whether the two disagree
    /// on separation or on lift by more than 5%: then the boundary layer decides the answer.
    public struct Bracket: Codable, Equatable, Sendable {
        public struct Run: Codable, Equatable, Sendable {
            public var cl: Double
            public var cd: Double
            public var converged: Bool?
            public var separated: Bool?
            public var separation: String?
            public var regions: [Region]?
        }
        public var sst: Run
    }
    public var bracket: Bracket?
    public var transitionDecides: Bool?

    /// Made before the far-field turbulence reached the wing (RANS version 3): SST decayed it about sevenfold.
    public var beforeTurbulenceFix: Bool { (ransVersion ?? 0) < 3 }

    /// The 2D-equivalent Cl and Cd for Wing.carContribution: a run as on the car already holds the 3D
    /// lift and induced drag, so they are carContribution undone, and the car gets them as they are.
    public func carCoefficients(on wing: Wing) -> (cl: Double, cd: Double) {
        guard finite != nil else { return (cl, cd) }
        let area = wing.span * wing.refChord
        return wing.sectionCoefficients(cla: -cl * area, cda: cd * area)
    }

    /// What the validation says about this run's drag, where it applies: SST-LM over a laminar
    /// bubble below Re 1.5 million read drag 5–34% high (mean 18%) on ten UIUC sections at Re 3e5,
    /// because the model's turbulent layer behind the bubble is too thin-walled and separates early
    /// (docs/validation/uiuc-transition); fully turbulent SST read 45% high there. Nil elsewhere
    /// (at Re 2.5–9 million NLR 7301 and NACA 0012 came within 6% and 15%).
    public var dragCaveat: String? {
        guard re < 1.5e6 else { return nil }
        if model == "sst" {
            return "Fully turbulent at low Reynolds number: drag read 45% high on average on ten UIUC sections at Re 300,000 (no laminar runs). SST with transition is closer."
        }
        let bubble = (regions ?? []).contains { $0.kind == "bubble" || $0.kind == "leading-edge bubble" }
        guard model == "sst-lm", bubble else { return nil }
        return "Drag over a laminar bubble reads high: 5–34% (mean 18%) on ten UIUC sections at Re 300,000. Behind the bubble the model's turbulent layer is too thin-walled, so a trailing-edge separation shows earlier than it should. Lift came within 4% on average there."
    }

    /// Each region in words, for the results panel.
    public func regionLines() -> [String] {
        (regions ?? []).map { r in
            let pct = { (x: Double) in "\(Int((x * 100).rounded()))%" }
            let span = r.end >= 0.999 ? "\(pct(r.start)) to the trailing edge" : "\(pct(r.start)) to \(pct(r.end)) of chord"
            return "\(WingIssue.label(r.element)), \(r.surface) (\(r.loaded)) surface: \(r.kind), \(span)"
        }
    }

    public static func decode(resultFile data: Data) throws -> WingRansResult {
        struct Wrapper: Decodable { var data: WingRansResult }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Wrapper.self, from: data).data
    }

    public var liftToDrag: Double { cd > 0 ? abs(cl) / cd : 0 }

    /// A project's last RANS run: wing/rans.json names its job folder under
    /// jobs/, so a reopened project shows the run again.
    public static func savedRunFile(project: URL) -> URL {
        ProjectStore.toolURL(for: project, tool: "wing").appendingPathComponent("rans.json")
    }

    public static func saveRun(folder: URL, project: URL) throws {
        let file = savedRunFile(project: project)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(["job": folder.lastPathComponent]).write(to: file, options: .atomic)
    }

    /// The saved run and its folder, or nil when there is none or its job folder is gone.
    public static func loadRun(project: URL) -> (result: WingRansResult, folder: URL)? {
        guard let data = try? Data(contentsOf: savedRunFile(project: project)),
              let job = (try? JSONDecoder().decode([String: String].self, from: data))?["job"] else { return nil }
        let folder = ProjectStore.jobsURL(for: project).appendingPathComponent(job)
        guard let result = (try? Data(contentsOf: folder.appendingPathComponent("result.json")))
            .flatMap({ try? decode(resultFile: $0) }) else { return nil }
        return (result, folder)
    }
}

/// The wing at several angles on the quick mesh (the engine's wing-sweep):
/// one RANS result per angle, each with its own folder in the job folder.
public struct WingSweep: Codable, Equatable, Sendable {
    public var rows: [WingRansResult]
    /// Angles not run because they would have gone past the time limit.
    public var skipped: [Double]
    public var seconds: Double
    public var timeLimit: Double

    public static func decode(resultFile data: Data) throws -> WingSweep {
        struct Wrapper: Decodable { var data: WingSweep }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Wrapper.self, from: data).data
    }

    /// Angles for a sweep from `from` to `to` in `step`s (either way round), at most `limit` of them.
    public static func angles(from: Double, to: Double, step: Double, limit: Int = 9) -> [Double] {
        let lo = Swift.min(from, to), hi = Swift.max(from, to), s = Swift.max(abs(step), 0.1)
        var out: [Double] = []
        var a = lo
        while a <= hi + 1e-9 && out.count < limit {
            out.append((a * 1000).rounded() / 1000)
            a += s
        }
        return out
    }
}

/// The quick multi-element estimate (the engine's wing-estimate): the panel
/// method for how the elements load each other, NeuralFoil per element.
/// Coefficients on the reference chord, in the wing frame (negative Cl is
/// downforce).
public struct WingEstimate: Codable, Equatable, Sendable {
    public struct Element: Codable, Equatable, Sendable {
        public var cl: Double
        public var cd: Double
        public var cm: Double
        public var clOwn: Double
        public var cdOwn: Double
        public var clInviscidOwn: Double
        /// The element's own angle of attack in place (its loading sense either way up).
        public var effectiveAngle: Double
        /// Degrees its neighbours turn the flow at it.
        public var upwash: Double
        public var transitionSuction: Double
        public var transitionPressure: Double
        public var confidence: Double
        public var trusted: Bool
        /// It has an element behind it, so it was held below its stall onset.
        public var heldBelowStall: Bool
        /// The angle of its maximum lift alone, and whether it separates here (see the row's `why`).
        public var stallAngle: Double?
        public var pastStall: Bool?
        /// Degrees it is turned past the element in front (nil for the first).
        public var deflection: Double?
    }

    public struct Row: Codable, Equatable, Sendable, Identifiable {
        public var alpha: Double
        public var cl: Double
        public var cd: Double
        public var trusted: Bool
        /// An element separates here, and the engine's words for which and why.
        public var separating: Bool?
        public var why: String?
        public var elements: [Element]

        public var id: Double { alpha }

        /// The live field cannot draw this row's flow: an element separates, by the
        /// estimate's word or by its own drag past an attached element's.
        public var liveFieldCannotShow: Bool {
            separating == true || elements.contains { $0.cdOwn > PanelSolution.attachedCdLimit }
        }
    }

    public var refChord: Double
    public var rows: [Row]
    public var re: [Double]

    public static func decode(resultFile data: Data) throws -> WingEstimate {
        struct Wrapper: Decodable { var data: WingEstimate }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Wrapper.self, from: data).data
    }

    /// The row nearest an angle.
    public func row(nearest alpha: Double) -> Row? {
        rows.min { abs($0.alpha - alpha) < abs($1.alpha - alpha) }
    }

    /// Each element's lift for the live flow to carry: only when this estimate
    /// was made for `wing` as drawn (`madeFor`), has a row within 0.6° of its
    /// angle and one entry per element; otherwise nil (the Kutta flow).
    public func liftTargets(madeFor: Wing?, wing: Wing) -> [Double]? {
        guard madeFor == wing, let r = row(nearest: wing.alpha), abs(r.alpha - wing.alpha) < 0.6,
              r.elements.count == wing.elements.count else { return nil }
        return r.elements.map(\.cl)
    }
}

extension WingRansResult {
    /// A point of the run's frame (its surface, its field) in the wing's own frame.
    public func toWing(_ p: SIMD2<Double>) -> SIMD2<Double> { Self.turn(p, by: -(frameTurn ?? 0)) }
    /// A point of the wing's frame in the run's.
    public func toRun(_ p: SIMD2<Double>) -> SIMD2<Double> { Self.turn(p, by: frameTurn ?? 0) }

    static func turn(_ p: SIMD2<Double>, by degrees: Double) -> SIMD2<Double> {
        guard degrees != 0 else { return p }
        let a = degrees * .pi / 180
        return SIMD2(p.x * cos(a) - p.y * sin(a), p.x * sin(a) + p.y * cos(a))
    }

    /// Whether this run was of these element outlines (wing frame, metres):
    /// each element's surface, back in the wing's frame, within `tolerance` of
    /// one outline's bounds. The field of a run on another wing is not this one's.
    public func matches(_ outlines: [[SIMD2<Double>]], tolerance: Double = 0.001) -> Bool {
        guard surface.count == outlines.count, !outlines.isEmpty else { return false }
        func bounds(_ pts: [SIMD2<Double>]) -> (SIMD2<Double>, SIMD2<Double>)? {
            guard let f = pts.first else { return nil }
            return pts.reduce((f, f)) { (simd_min($0.0, $1), simd_max($0.1, $1)) }
        }
        let ran = surface.compactMap { s in bounds(zip(s.x, s.y).map { toWing(SIMD2($0, $1)) }) }
        let now = outlines.compactMap(bounds)
        guard ran.count == now.count else { return false }
        var left = now
        for r in ran {
            guard let k = left.firstIndex(where: { simd_reduce_max(simd_abs($0.0 - r.0)) <= tolerance
                                                    && simd_reduce_max(simd_abs($0.1 - r.1)) <= tolerance }) else { return false }
            left.remove(at: k)
        }
        return true
    }
}

