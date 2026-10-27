import Foundation

/// The engine's cad-check result.
public struct GeometryReport: Decodable, Sendable {
    public struct Issue: Decodable, Sendable, Identifiable {
        public var kind: String
        public var title: String
        public var severity: String  // error, warning, info
        public var count: Int
        public var detail: String
        public var fixable: Bool
        public var points: [[Double]]

        public var id: String { kind }
    }

    public struct MeshSection: Decodable, Sendable {
        public var triangles: Int
        public var bodies: Int
        public var closed: Bool
        public var issues: [Issue]
        public var intersectionsChecked: Bool?
        public var intersectionsComplete: Bool?

        enum CodingKeys: String, CodingKey {
            case triangles, bodies, closed, issues
            case intersectionsChecked = "intersections_checked"
            case intersectionsComplete = "intersections_complete"
        }
    }

    public struct BrepSection: Decodable, Sendable {
        public var parts: Int
        public var invalidParts: [String]
        public var issues: [Issue]

        enum CodingKeys: String, CodingKey {
            case parts, issues
            case invalidParts = "invalid_parts"
        }
    }

    public var file: String
    public var mesh: MeshSection
    public var brep: BrepSection?
    public var problems: Int

    public var allIssues: [Issue] { mesh.issues + (brep?.issues ?? []) }
    public var anyFixable: Bool { allIssues.contains { $0.fixable && $0.count > 0 && $0.severity != "info" } }

    public static func decode(resultFile data: Data) throws -> GeometryReport {
        struct Envelope: Decodable { var data: GeometryReport }
        return try JSONDecoder().decode(Envelope.self, from: data).data
    }
}
