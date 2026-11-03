import Foundation
import simd

/// A reference to something a feature uses: a face or edge of the imported
/// part ("part"), something a feature made (its id), or a standard plane
/// ("std"). The engine resolves it; one it cannot find again is "lost".
public struct EditRef: Codable, Hashable, Sendable {
    public var src: String
    public var kind: String  // face, edge, point, curve, surface, plane
    public var i: Int?
    public var name: String?  // std planes: XY, YZ, ZX
    /// A fill boundary edge of the part: the face the fill stays tangent to.
    public var tangent: EditRef? {
        get { tangentBox.first }
        set { tangentBox = newValue.map { [$0] } ?? [] }
    }
    private var tangentBox: [EditRef] = []  // an array, since a struct cannot hold itself

    public init(src: String, kind: String, i: Int? = nil, name: String? = nil) {
        self.src = src
        self.kind = kind
        self.i = i
        self.name = name
    }

    enum CodingKeys: String, CodingKey { case src, kind, i, name, tangent }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        src = try c.decode(String.self, forKey: .src)
        kind = try c.decode(String.self, forKey: .kind)
        i = try c.decodeIfPresent(Int.self, forKey: .i)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        tangent = try c.decodeIfPresent(EditRef.self, forKey: .tangent)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(src, forKey: .src)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(i, forKey: .i)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(tangent, forKey: .tangent)
    }
}

public struct EditFeature: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case point, spline, plane, extrude, fill, add, fillet, chamfer, pushpull
    }

    public var id: String
    public var kind: Kind
    public var refs: [EditRef]
    public var values: [String: Double]

    public init(id: String, kind: Kind, refs: [EditRef] = [], values: [String: Double] = [:]) {
        self.id = id
        self.kind = kind
        self.refs = refs
        self.values = values
    }
}

/// The edits to one STEP part, saved beside it so they survive quitting.
public struct FeatureFile: Codable, Sendable {
    public var version = 1
    public var part: String?
    public var fingerprint: String?  // of the STEP the references were picked on
    public var features: [EditFeature]

    public init(part: String?, fingerprint: String?, features: [EditFeature]) {
        self.part = part
        self.fingerprint = fingerprint
        self.features = features
    }

    public static func url(beside step: URL) -> URL {
        step.deletingPathExtension().appendingPathExtension("features.json")
    }

    public static func load(beside step: URL) throws -> FeatureFile? {
        let url = url(beside: step)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(FeatureFile.self, from: Data(contentsOf: url))
    }

    public func save(beside step: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(beside: step), options: .atomic)
    }
}

/// The engine's answer to part-edit: the rebuilt part and what each piece is.
public struct PartEditReply: Decodable, Sendable {
    public struct Face: Decodable, Sendable {
        public var ref: EditRef?  // nil: a split piece that cannot be picked
        public var start: Int
        public var count: Int
    }

    public struct Edge: Decodable, Sendable {
        public var ref: EditRef?
        public var points: [[Double]]  // metres
    }

    public struct Point: Decodable, Sendable {
        public var id: String
        public var position: [Double]
    }

    public struct Plane: Decodable, Sendable {
        public var id: String
        public var origin: [Double]
        public var normal: [Double]
    }

    public struct Status: Decodable, Sendable {
        public var id: String
        public var status: String  // ok, failed, lost, skipped
        public var message: String?
    }

    public var parts: [String]
    public var part: String
    public var fingerprint: String
    public var partValid: Bool
    public var glb: String
    public var faces: [Face]
    public var edges: [Edge]
    public var points: [Point]
    public var planes: [Plane]
    public var features: [Status]
    public var valid: Bool
    public var closed: Bool

    enum CodingKeys: String, CodingKey {
        case parts, part, fingerprint, glb, faces, edges, points, planes, features, valid, closed
        case partValid = "part_valid"
    }

    public func face(atTriangle t: Int) -> Face? {
        faces.first { t >= $0.start && t < $0.start + $0.count }
    }

    public static func decode(_ data: Data) throws -> PartEditReply {
        struct Envelope: Decodable { var data: PartEditReply }
        return try JSONDecoder().decode(Envelope.self, from: data).data
    }
}

/// Picking an edge by how close the pointer is to its drawn line on screen.
public enum EdgePick {
    public static func nearest(_ polylines: [[SIMD2<Double>]], to p: SIMD2<Double>, within: Double) -> Int? {
        var best: (Int, Double)?
        for (k, line) in polylines.enumerated() {
            for (a, b) in zip(line, line.dropFirst()) {
                let ab = b - a
                let t = simd_dot(ab, ab) > 0 ? min(max(simd_dot(p - a, ab) / simd_dot(ab, ab), 0), 1) : 0
                let d = simd_length(p - (a + t * ab))
                if d <= within && d < (best?.1 ?? .infinity) { best = (k, d) }
            }
        }
        return best?.0
    }
}
