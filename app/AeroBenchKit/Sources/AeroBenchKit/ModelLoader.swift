import Foundation
import simd

public enum LengthUnit: String, CaseIterable, Codable, Sendable {
    case millimetre = "mm"
    case metre = "m"
    case inch = "in"

    public var metres: Float {
        switch self {
        case .millimetre: 0.001
        case .metre: 1
        case .inch: 0.0254
        }
    }
}

public enum ModelLoadError: LocalizedError, Equatable {
    case unsupported(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let ext): "AeroBench cannot open .\(ext) files directly."
        case .malformed(let why): "The file could not be read: \(why)"
        }
    }
}

/// Loads STL, OBJ and the engine's .glb in Swift. STEP and IGES go through
/// the engine's tessellate command first.
public enum ModelLoader {
    public static let directExtensions: Set<String> = ["stl", "obj", "glb"]

    /// `units` applies to STL and OBJ, which carry none. glb is metres.
    public static func load(_ url: URL, units: LengthUnit = .millimetre) throws -> Model3D {
        let ext = url.pathExtension.lowercased()
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let name = url.deletingPathExtension().lastPathComponent
        switch ext {
        case "stl": return try STLReader.read(data, scale: units.metres, name: name)
        case "obj": return try OBJReader.read(data, scale: units.metres, name: name)
        case "glb": return try GLBReader.read(data, name: name)
        default: throw ModelLoadError.unsupported(ext)
        }
    }
}

enum STLReader {
    static func read(_ data: Data, scale: Float, name: String) throws -> Model3D {
        let corners = isBinary(data) ? try binary(data) : try ascii(data)
        guard !corners.isEmpty else { throw ModelLoadError.malformed("no triangles") }
        let scaled = scale == 1 ? corners : corners.map { $0 * scale }
        let mesh = TriangleMesh.flatShaded(triangles: scaled, name: name)
        return Model3D(meshes: [mesh], roots: [ModelNode(name: name, mesh: 0)], sourceName: name)
    }

    static func isBinary(_ data: Data) -> Bool {
        guard data.count >= 84 else { return false }
        let n = Int(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self)) })
        if data.count == 84 + 50 * n { return true }
        let head = String(decoding: data.prefix(5), as: UTF8.self).lowercased()
        return head != "solid" && data.count >= 84 + 50 * n
    }

    static func binary(_ data: Data) throws -> [SIMD3<Float>] {
        data.withUnsafeBytes { raw -> [SIMD3<Float>] in
            let n = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 80, as: UInt32.self)))
            var out = [SIMD3<Float>]()
            out.reserveCapacity(3 * n)
            func f(_ o: Int) -> Float { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))) }
            for i in 0..<n {
                let base = 84 + 50 * i + 12
                for k in 0..<3 {
                    let o = base + 12 * k
                    out.append(SIMD3(f(o), f(o + 4), f(o + 8)))
                }
            }
            return out
        }
    }

    static func ascii(_ data: Data) throws -> [SIMD3<Float>] {
        var out = [SIMD3<Float>]()
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.drop { $0 == " " || $0 == "\t" }
            guard t.hasPrefix("vertex") else { continue }
            let parts = t.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 4, let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) else {
                throw ModelLoadError.malformed("bad vertex line: \(line.prefix(80))")
            }
            out.append(SIMD3(x, y, z))
        }
        return out
    }
}

enum OBJReader {
    /// One part per `o` or `g` group. Polygons are fan-triangulated, shading is flat.
    static func read(_ data: Data, scale: Float, name: String) throws -> Model3D {
        var vertices: [SIMD3<Float>] = []
        var groups: [(name: String, corners: [SIMD3<Float>])] = []
        var current = (name: name, corners: [SIMD3<Float>]())

        func flush() {
            if !current.corners.isEmpty { groups.append(current) }
        }

        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let head = parts.first else { continue }
            switch head {
            case "v":
                guard parts.count >= 4, let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) else {
                    throw ModelLoadError.malformed("bad vertex line: \(line.prefix(80))")
                }
                vertices.append(SIMD3(x, y, z) * scale)
            case "o", "g":
                flush()
                let label = parts.dropFirst().joined(separator: " ")
                current = (name: label.isEmpty ? "Group \(groups.count + 1)" : label, corners: [])
            case "f":
                var poly: [SIMD3<Float>] = []
                for token in parts.dropFirst() {
                    guard let first = token.split(separator: "/", omittingEmptySubsequences: false).first,
                          let i = Int(first), i != 0
                    else { throw ModelLoadError.malformed("bad face line: \(line.prefix(80))") }
                    let index = i > 0 ? i - 1 : vertices.count + i
                    guard vertices.indices.contains(index) else {
                        throw ModelLoadError.malformed("face refers to vertex \(i), which does not exist")
                    }
                    poly.append(vertices[index])
                }
                guard poly.count >= 3 else { continue }
                for k in 1..<(poly.count - 1) {
                    current.corners += [poly[0], poly[k], poly[k + 1]]
                }
            default:
                continue
            }
        }
        flush()
        guard !groups.isEmpty else { throw ModelLoadError.malformed("no faces") }
        let meshes = groups.map { TriangleMesh.flatShaded(triangles: $0.corners, name: $0.name) }
        let root: ModelNode
        if groups.count == 1 {
            root = ModelNode(name: groups[0].name == name ? name : groups[0].name, mesh: 0)
        } else {
            root = ModelNode(name: name, children: groups.enumerated().map { ModelNode(name: $0.element.name, mesh: $0.offset) })
        }
        return Model3D(meshes: meshes, roots: [root], sourceName: name)
    }
}

/// glTF 2.0 binary reader, enough for what the engine writes and for typical
/// exports: triangle primitives, float positions and normals, uint8/16/32
/// indices, node matrices or TRS.
enum GLBReader {
    struct GLTF: Decodable {
        struct Scene: Decodable { var nodes: [Int]? }
        struct Node: Decodable {
            var name: String?
            var children: [Int]?
            var mesh: Int?
            var matrix: [Float]?
            var translation: [Float]?
            var rotation: [Float]?
            var scale: [Float]?
        }
        struct Mesh: Decodable {
            var name: String?
            var primitives: [Primitive]
        }
        struct Primitive: Decodable {
            var attributes: [String: Int]
            var indices: Int?
            var mode: Int?
        }
        struct Accessor: Decodable {
            var bufferView: Int?
            var byteOffset: Int?
            var componentType: Int
            var count: Int
            var type: String
        }
        struct BufferView: Decodable {
            var buffer: Int
            var byteOffset: Int?
            var byteLength: Int
            var byteStride: Int?
        }
        var scene: Int?
        var scenes: [Scene]?
        var nodes: [Node]?
        var meshes: [Mesh]?
        var accessors: [Accessor]?
        var bufferViews: [BufferView]?
    }

    static func read(_ data: Data, name: String) throws -> Model3D {
        func u32(_ o: Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) } }
        guard data.count >= 20, u32(0) == 0x4654_6C67, u32(4) == 2 else { throw ModelLoadError.malformed("not a glTF 2.0 binary") }
        let jsonLength = Int(u32(12))
        guard u32(16) == 0x4E4F_534A, data.count >= 20 + jsonLength else { throw ModelLoadError.malformed("missing JSON chunk") }
        let gltf: GLTF
        do {
            gltf = try JSONDecoder().decode(GLTF.self, from: data.subdata(in: 20..<(20 + jsonLength)))
        } catch {
            throw ModelLoadError.malformed("bad glTF JSON: \(error.localizedDescription)")
        }
        var bin = Data()
        let binStart = 20 + jsonLength
        if data.count >= binStart + 8, u32(binStart + 4) == 0x004E_4942 {
            let len = Int(u32(binStart))
            guard data.count >= binStart + 8 + len else { throw ModelLoadError.malformed("truncated binary chunk") }
            bin = data.subdata(in: (binStart + 8)..<(binStart + 8 + len))
        }

        func floats(_ index: Int, width: Int) throws -> [SIMD4<Float>] {
            guard let acc = gltf.accessors?[safe: index], acc.componentType == 5126,
                  let viewIndex = acc.bufferView, let view = gltf.bufferViews?[safe: viewIndex]
            else { throw ModelLoadError.malformed("unsupported vertex accessor \(index)") }
            let stride = view.byteStride ?? 4 * width
            let start = (view.byteOffset ?? 0) + (acc.byteOffset ?? 0)
            guard start + stride * max(acc.count - 1, 0) + 4 * width <= bin.count else { throw ModelLoadError.malformed("accessor \(index) runs past the buffer") }
            return bin.withUnsafeBytes { raw in
                (0..<acc.count).map { i in
                    var v = SIMD4<Float>(0, 0, 0, 1)
                    for k in 0..<width {
                        v[k] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: start + i * stride + 4 * k, as: UInt32.self)))
                    }
                    return v
                }
            }
        }

        func indices(_ index: Int) throws -> [UInt32] {
            guard let acc = gltf.accessors?[safe: index], let viewIndex = acc.bufferView,
                  let view = gltf.bufferViews?[safe: viewIndex]
            else { throw ModelLoadError.malformed("bad index accessor \(index)") }
            let size: Int
            switch acc.componentType {
            case 5125: size = 4
            case 5123: size = 2
            case 5121: size = 1
            default: throw ModelLoadError.malformed("unsupported index type \(acc.componentType)")
            }
            let start = (view.byteOffset ?? 0) + (acc.byteOffset ?? 0)
            guard start + size * acc.count <= bin.count else { throw ModelLoadError.malformed("indices run past the buffer") }
            return bin.withUnsafeBytes { raw in
                (0..<acc.count).map { i in
                    let o = start + i * size
                    switch size {
                    case 4: return UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))
                    case 2: return UInt32(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt16.self)))
                    default: return UInt32(raw.load(fromByteOffset: o, as: UInt8.self))
                    }
                }
            }
        }

        var meshes: [TriangleMesh] = []
        for (mi, m) in (gltf.meshes ?? []).enumerated() {
            var positions: [SIMD3<Float>] = []
            var normals: [SIMD3<Float>] = []
            var colors: [SIMD4<Float>] = []
            var idx: [UInt32] = []
            var allHaveNormals = true
            var allHaveColors = true
            for prim in m.primitives where (prim.mode ?? 4) == 4 {
                guard let posIndex = prim.attributes["POSITION"] else { continue }
                let base = UInt32(positions.count)
                let pos = try floats(posIndex, width: 3).map { SIMD3($0.x, $0.y, $0.z) }
                positions += pos
                if let n = prim.attributes["NORMAL"] {
                    normals += try floats(n, width: 3).map { SIMD3($0.x, $0.y, $0.z) }
                } else {
                    allHaveNormals = false
                }
                if let c = prim.attributes["COLOR_0"], let acc = gltf.accessors?[safe: c], acc.componentType == 5126 {
                    colors += try floats(c, width: acc.type == "VEC4" ? 4 : 3)
                } else {
                    allHaveColors = false
                }
                let local = try prim.indices.map(indices) ?? (0..<UInt32(pos.count)).map { $0 }
                guard local.allSatisfy({ Int($0) < pos.count }) else { throw ModelLoadError.malformed("index out of range in mesh \(mi)") }
                idx += local.map { $0 + base }
            }
            if !allHaveNormals || normals.count != positions.count {
                normals = TriangleMesh.vertexNormals(positions: positions, indices: idx)
            }
            let meshColors = allHaveColors && colors.count == positions.count && !colors.isEmpty ? colors : nil
            meshes.append(TriangleMesh(positions: positions, normals: normals, indices: idx, colors: meshColors, name: m.name ?? ""))
        }

        let nodes = gltf.nodes ?? []
        func build(_ i: Int, depth: Int) throws -> ModelNode {
            guard depth < 64, let n = nodes[safe: i] else { throw ModelLoadError.malformed("bad node tree") }
            return ModelNode(
                name: n.name ?? (n.mesh.flatMap { gltf.meshes?[safe: $0]?.name } ?? "Node \(i)"),
                transform: transform(n),
                mesh: n.mesh.flatMap { $0 < meshes.count ? $0 : nil },
                children: try (n.children ?? []).map { try build($0, depth: depth + 1) }
            )
        }
        let sceneIndex = gltf.scene ?? 0
        let rootIndices = gltf.scenes?[safe: sceneIndex]?.nodes ?? Array(nodes.indices)
        let roots = try rootIndices.map { try build($0, depth: 0) }
        return Model3D(meshes: meshes, roots: roots, sourceName: name)
    }

    static func transform(_ n: GLTF.Node) -> simd_float4x4 {
        if let m = n.matrix, m.count == 16 {
            return simd_float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                           SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
        }
        var t = matrix_identity_float4x4
        if let s = n.scale, s.count == 3 {
            t = simd_float4x4(diagonal: SIMD4(s[0], s[1], s[2], 1))
        }
        if let r = n.rotation, r.count == 4 {
            t = simd_float4x4(simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])) * t
        }
        if let tr = n.translation, tr.count == 3 {
            var m = matrix_identity_float4x4
            m.columns.3 = SIMD4(tr[0], tr[1], tr[2], 1)
            t = m * t
        }
        return t
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
