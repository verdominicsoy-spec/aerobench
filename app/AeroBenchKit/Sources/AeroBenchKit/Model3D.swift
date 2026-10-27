import Foundation
import simd

/// Triangle mesh in its part's own frame, metres.
public struct TriangleMesh: Sendable {
    public var positions: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    public var indices: [UInt32]
    /// Optional per-vertex colours, for colour-mapped results.
    public var colors: [SIMD4<Float>]?
    public var name: String

    public init(positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32],
                colors: [SIMD4<Float>]? = nil, name: String = "") {
        self.positions = positions
        self.normals = normals
        self.indices = indices
        self.colors = colors
        self.name = name
    }

    public var triangleCount: Int { indices.count / 3 }

    public func triangle(_ i: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)? {
        guard i >= 0, 3 * i + 2 < indices.count else { return nil }
        return (positions[Int(indices[3 * i])], positions[Int(indices[3 * i + 1])], positions[Int(indices[3 * i + 2])])
    }

    /// Three vertices per triangle with face normals: right for STL, which
    /// has no shared vertices, and for faceted CAD exports.
    public static func flatShaded(triangles corners: [SIMD3<Float>], name: String = "") -> TriangleMesh {
        var normals = [SIMD3<Float>](repeating: .zero, count: corners.count)
        var t = 0
        while t + 2 < corners.count {
            let n = simd_cross(corners[t + 1] - corners[t], corners[t + 2] - corners[t])
            let len = simd_length(n)
            let unit = len > 0 ? n / len : SIMD3<Float>(0, 0, 1)
            normals[t] = unit
            normals[t + 1] = unit
            normals[t + 2] = unit
            t += 3
        }
        let count = corners.count - corners.count % 3
        return TriangleMesh(positions: Array(corners.prefix(count)), normals: Array(normals.prefix(count)),
                            indices: (0..<UInt32(count)).map { $0 }, name: name)
    }

    /// Area-weighted vertex normals.
    public static func vertexNormals(positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var n = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var t = 0
        while t + 2 < indices.count {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            let f = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            n[a] += f
            n[b] += f
            n[c] += f
            t += 3
        }
        return n.map { v in
            let len = simd_length(v)
            return len > 0 ? v / len : SIMD3<Float>(0, 0, 1)
        }
    }
}

/// A node in the part tree. Leaves usually carry a mesh; several leaves can
/// share one mesh (four instances of the same wheel).
public struct ModelNode: Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var transform: simd_float4x4
    public var mesh: Int?
    public var children: [ModelNode]

    public init(id: Int = 0, name: String, transform: simd_float4x4 = matrix_identity_float4x4,
                mesh: Int? = nil, children: [ModelNode] = []) {
        self.id = id
        self.name = name
        self.transform = transform
        self.mesh = mesh
        self.children = children
    }

    /// For OutlineGroup, which wants nil rather than an empty array for leaves.
    public var childNodes: [ModelNode]? { children.isEmpty ? nil : children }
}

public struct ModelInstance: Sendable {
    public var node: ModelNode
    public var world: simd_float4x4
}

/// A loaded model: meshes plus the tree that places them. Metres, in the
/// file's own frame.
public struct Model3D: Sendable {
    public var meshes: [TriangleMesh]
    public var roots: [ModelNode]
    public var sourceName: String

    public init(meshes: [TriangleMesh], roots: [ModelNode], sourceName: String) {
        self.meshes = meshes
        self.sourceName = sourceName
        var next = 0
        func number(_ node: ModelNode) -> ModelNode {
            var n = node
            n.id = next
            next += 1
            n.children = node.children.map(number)
            return n
        }
        self.roots = roots.map(number)
    }

    /// Every node with a mesh and its world transform, skipping hidden subtrees.
    public func instances(hidden: Set<Int> = []) -> [ModelInstance] {
        var out: [ModelInstance] = []
        func walk(_ node: ModelNode, _ parent: simd_float4x4) {
            guard !hidden.contains(node.id) else { return }
            let world = parent * node.transform
            if node.mesh != nil { out.append(ModelInstance(node: node, world: world)) }
            for c in node.children { walk(c, world) }
        }
        for r in roots { walk(r, matrix_identity_float4x4) }
        return out
    }

    public var triangleCount: Int {
        instances().reduce(0) { $0 + meshes[$1.node.mesh!].triangleCount }
    }

    public var nodeCount: Int {
        func count(_ n: ModelNode) -> Int { 1 + n.children.reduce(0) { $0 + count($1) } }
        return roots.reduce(0) { $0 + count($1) }
    }

    public func node(id: Int) -> ModelNode? {
        func find(_ n: ModelNode) -> ModelNode? {
            if n.id == id { return n }
            for c in n.children { if let hit = find(c) { return hit } }
            return nil
        }
        for r in roots { if let hit = find(r) { return hit } }
        return nil
    }

    /// Axis-aligned bounds of the visible geometry, metres.
    public func bounds(hidden: Set<Int> = []) -> (min: SIMD3<Double>, max: SIMD3<Double>)? {
        var lo = SIMD3<Double>(repeating: .infinity)
        var hi = SIMD3<Double>(repeating: -.infinity)
        var any = false
        for inst in instances(hidden: hidden) {
            let mesh = meshes[inst.node.mesh!]
            for p in mesh.positions {
                let w = inst.world * SIMD4<Float>(p, 1)
                let d = SIMD3<Double>(Double(w.x), Double(w.y), Double(w.z))
                lo = simd_min(lo, d)
                hi = simd_max(hi, d)
                any = true
            }
        }
        return any ? (lo, hi) : nil
    }
}

public enum Measure {
    public static func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        simd_distance(a, b)
    }

    /// The corner of a triangle nearest to a picked point, for exact
    /// vertex-to-vertex measurements.
    public static func nearestCorner(to p: SIMD3<Double>, of corners: [SIMD3<Double>]) -> SIMD3<Double> {
        corners.min { simd_distance_squared($0, p) < simd_distance_squared($1, p) } ?? p
    }
}
