import Foundation

/// A quick viscous polar of one section from the engine's wing-polar
/// command (NeuralFoil): one row per angle of attack.
public struct WingPolar: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable, Identifiable {
        public var alpha: Double
        public var cl: Double
        public var cd: Double
        public var cm: Double
        /// x/c where each surface turns turbulent; 1 is laminar to the trailing edge.
        public var transitionSuction: Double
        public var transitionPressure: Double
        public var confidence: Double
        public var trusted: Bool

        public var id: Double { alpha }
        public var liftToDrag: Double { cd > 0 ? abs(cl) / cd : 0 }
    }

    public var re: Double
    public var nCrit: Double
    public var inverted: Bool
    public var rows: [Row]

    public static func decode(resultFile data: Data) throws -> WingPolar {
        struct Wrapper: Decodable { var data: WingPolar }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Wrapper.self, from: data).data
    }

    /// The row nearest an angle, if the polar covers it.
    public func row(near alpha: Double) -> Row? {
        guard let first = rows.first, let last = rows.last,
              alpha >= min(first.alpha, last.alpha) - 0.5, alpha <= max(first.alpha, last.alpha) + 0.5 else { return nil }
        return rows.min { abs($0.alpha - alpha) < abs($1.alpha - alpha) }
    }
}
