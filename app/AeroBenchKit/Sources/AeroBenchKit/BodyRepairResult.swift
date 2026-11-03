import Foundation

/// The result of the engine's cad-repair-body job: what was fixed without
/// asking, the items left for review, and whether the output is one closed body.
public struct BodyRepairResult: Decodable, Sendable {
    public struct Auto: Decodable, Sendable {
        public var parts: Int
        public var partsSewn: Int
        public var smallEdgesRemoved: Int
        public var smallFacesRemoved: Int
        public var maxSewMM: Double?

        enum CodingKeys: String, CodingKey {
            case parts
            case partsSewn = "parts_sewn"
            case smallEdgesRemoved = "small_edges_removed"
            case smallFacesRemoved = "small_faces_removed"
            case maxSewMM = "max_sew_mm"
        }
    }

    public struct Item: Decodable, Sendable, Identifiable {
        public var id: String
        public var kind: String  // gap, hole, wide_gap, nonmanifold_edge
        public var part: String
        public var sizeMM: Double?
        public var centre: [Double]  // metres, world
        public var centreMM: [Double]  // millimetres, part-local: what saved decisions match on
        public var lines: [[[Double]]]  // polylines, metres, world, at every placement
        public var fix: String?
        public var decision: String?  // accept, skip, or nil when pending

        /// Gaps and holes have a fix to accept or skip; the rest are reports.
        public var reviewable: Bool { kind == "gap" || kind == "hole" }

        enum CodingKeys: String, CodingKey {
            case id, kind, part, centre, lines, fix, decision
            case sizeMM = "size_mm"
            case centreMM = "centre_mm"
        }
    }

    public struct Outcome: Decodable, Sendable {
        public var solids: Int
        public var openShells: Int
        public var openParts: [String]
        public var fused: Bool
        public var freeEdges: Int
        public var nonmanifoldEdges: Int
        public var valid: Bool
        public var closed: Bool

        enum CodingKeys: String, CodingKey {
            case solids, fused, valid, closed
            case openShells = "open_shells"
            case openParts = "open_parts"
            case freeEdges = "free_edges"
            case nonmanifoldEdges = "nonmanifold_edges"
        }
    }

    public var output: String
    public var limitMM: Double
    public var auto: Auto
    public var items: [Item]
    public var result: Outcome

    enum CodingKeys: String, CodingKey {
        case output, auto, items, result
        case limitMM = "limit_mm"
    }

    public static func decode(resultFile data: Data) throws -> BodyRepairResult {
        struct Envelope: Decodable { var data: BodyRepairResult }
        return try JSONDecoder().decode(Envelope.self, from: data).data
    }
}
