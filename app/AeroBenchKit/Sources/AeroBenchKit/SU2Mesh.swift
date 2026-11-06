import Foundation
import simd

/// A 2D SU2 mesh as wing-mesh writes it (gmsh, ASCII): the points, each
/// cell's point indices, and the points on the walls (markers wall_0, wall_1, ...).
public struct SU2Mesh: Sendable {
    public var points: [SIMD2<Double>]
    public var cells: [[Int]]
    public var wallPoints: [Int]

    /// The walls' extent, for framing the view on the wing rather than the far field
    public var wallBounds: (min: SIMD2<Double>, max: SIMD2<Double>)? {
        let ps = wallPoints.compactMap { points.indices.contains($0) ? points[$0] : nil }
        guard let first = ps.first else { return nil }
        return ps.reduce((first, first)) { (simd_min($0.0, $1), simd_max($0.1, $1)) }
    }

    public static func parse(_ text: String) throws -> SU2Mesh {
        let lines = text.split(whereSeparator: \.isNewline)
        var points: [SIMD2<Double>] = [], cells: [[Int]] = [], walls = Set<Int>()
        func count(_ line: Substring) -> Int? { line.split(separator: "=").last.flatMap { Int($0.split(separator: " ").first ?? "") } }
        var i = 0, marker = ""
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("NELEM="), let n = count(lines[i]) {
                for l in lines[(i + 1)..<min(i + 1 + n, lines.count)] {
                    let f = l.split(separator: " ").compactMap { Int($0) }
                    // type, its points, then the cell index: triangles (5) and quads (9)
                    if f.count >= 5 { cells.append(Array(f[1..<(f.count - 1)])) }
                }
                i += n
            } else if line.hasPrefix("NPOIN="), let n = count(lines[i]) {
                for l in lines[(i + 1)..<min(i + 1 + n, lines.count)] {
                    let f = l.split(separator: " ").compactMap { Double($0) }
                    if f.count >= 2 { points.append(SIMD2(f[0], f[1])) }
                }
                i += n
            } else if line.hasPrefix("MARKER_TAG=") {
                marker = line.dropFirst("MARKER_TAG=".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("MARKER_ELEMS="), let n = count(lines[i]) {
                if marker.hasPrefix("wall") {
                    for l in lines[(i + 1)..<min(i + 1 + n, lines.count)] { walls.formUnion(l.split(separator: " ").dropFirst().compactMap { Int($0) }) }
                }
                i += n
            }
            i += 1
        }
        guard !points.isEmpty, !cells.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return SU2Mesh(points: points, cells: cells, wallPoints: walls.sorted())
    }
}
