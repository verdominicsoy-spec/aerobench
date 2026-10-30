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
