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
    public var residualDrop: Double
    public var reason: String?
    public var cl: Double
    public var cd: Double
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

    public static func decode(resultFile data: Data) throws -> WingRansResult {
        struct Wrapper: Decodable { var data: WingRansResult }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Wrapper.self, from: data).data
    }

    public var liftToDrag: Double { cd > 0 ? abs(cl) / cd : 0 }
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

