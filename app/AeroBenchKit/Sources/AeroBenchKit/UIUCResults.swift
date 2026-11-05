import Foundation

/// The UIUC comparison the accuracy window shows: every benchmark run (newest first), the
/// settings a run now would use, and the tunnel's own points (aeroengine.validation.results_view).
public struct UIUCResults: Decodable, Sendable {
    /// What makes two runs comparable. Cores only change speed and are kept on the run instead.
    public struct Settings: Decodable, Equatable, Sendable {
        public let model: String
        public let mesh: String
        public let turbulenceIntensity: Double
        public let commit: String?
    }

    public struct Errors: Decodable, Sendable {
        public let lift: Double?
        public let drag: Double?
    }

    /// One angle: [alpha, cl, cd] or, for RANS, [alpha, cl, cd, converged].
    public struct Point: Decodable, Sendable {
        public let alpha: Double
        public let cl: Double
        public let cd: Double
        public let converged: Bool

        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            alpha = try c.decode(Double.self)
            cl = try c.decode(Double.self)
            cd = try c.decode(Double.self)
            converged = c.isAtEnd ? true : try c.decode(Bool.self)
        }
    }

    public struct Case: Decodable, Identifiable, Sendable {
        public struct CaseErrors: Decodable, Sendable {
            public let estimate: Errors
            public let rans: Errors
        }
        public let key: String
        public let name: String
        public let volume: Int?
        public let re: Double
        public let estimate: [Point]
        public let rans: [Point]
        /// Why RANS gave nothing for this section (the mesh or the solver failed), if it did.
        public let ransError: String?
        public let errors: CaseErrors
        public var id: String { key }
    }

    public struct Summary: Decodable, Sendable {
        public let estimate: Errors
        public let rans: Errors
        public let converged: Double?
    }

    public struct Run: Decodable, Identifiable, Sendable {
        public let date: String
        public let settings: Settings
        public let cores: Int
        public let seconds: Double
        public let summary: Summary
        public let cases: [Case]
        public var id: String { date }
    }

    public struct Tunnel: Decodable, Sendable {
        public let name: String
        public let re: Double
        public let rows: [Point]
    }

    public let runs: [Run]
    public let current: Settings
    /// Keyed by benchmark key (no underscores, so snake-case key conversion leaves them alone).
    public let tunnel: [String: Tunnel]
    /// Why the tunnel points are missing (the download failed), if they are.
    public let tunnelError: String?

    /// The run was made with other settings than a run now would use.
    public func isStale(_ run: Run) -> Bool { run.settings != current }

    /// A job's result.json or a warm-engine reply: both carry the payload under "data".
    public static func decode(resultFile data: Data) throws -> UIUCResults {
        struct Wrapper: Decodable { let data: UIUCResults }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Wrapper.self, from: data).data
    }
}
