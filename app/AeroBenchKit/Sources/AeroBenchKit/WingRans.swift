import Foundation

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
    public var folder: String?
    public var seconds: Double?
    public var cfl: Double?
    /// "jst" (the default) or "fds", the more dissipative fallback whose drag reads high.
    public var scheme: String?
    public var attempts: [Attempt]?

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
    }

    public struct Row: Codable, Equatable, Sendable, Identifiable {
        public var alpha: Double
        public var cl: Double
        public var cd: Double
        public var trusted: Bool
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
