import Foundation
import simd

/// Airfoil coordinates from a CSV file: comma, semicolon or tab separated,
/// with or without a header row, as one Selig loop or as upper and lower
/// surfaces, in any chord length. x and y are the columns a header names x and
/// y, else the last two numbers in each row. A text column, or a label row
/// before each block of points, names the element the points belong to, so a
/// multi-element wing export (element,index,x_mm,y_mm) gives one section per
/// element. Each becomes a Selig .dat the engine's import reads like any other.
public enum AirfoilCSV {
    public indirect enum ParseError: LocalizedError, Equatable {
        case tooFewPoints(Int)
        case notANumber(line: Int, field: String)
        case oneColumn(line: Int)
        case tooManyBlocks(Int)
        case notAnAirfoil
        case zeroChord
        case severalElements(Int)
        case inElement(String, ParseError)

        public var errorDescription: String? {
            switch self {
            case .tooFewPoints(let n):
                return "Only \(n) x,y rows: an airfoil needs at least six."
            case .notANumber(let line, let field):
                return "Line \(line): “\(field)” is not a number."
            case .oneColumn(let line):
                return "Line \(line) has one column: x and y need two."
            case .tooManyBlocks(let n):
                return "The points come in \(n) blocks: give one loop, or the upper and lower surfaces."
            case .notAnAirfoil:
                return "The points are not an airfoil outline: give one loop that starts at the trailing edge (Selig order), or the upper and lower surfaces one after the other."
            case .zeroChord:
                return "Every point has the same x, so there is no chord."
            case .severalElements(let n):
                return "The file holds \(n) elements, not one section."
            case .inElement(let name, let error):
                return "\(name): \(error.errorDescription ?? "")"
            }
        }
    }

    public struct Element: Equatable, Sendable {
        /// From an element column or a label row; nil for a lone section.
        public var name: String?
        /// Selig order, scaled so x runs 0 to 1 (unit chord for a section at 0°).
        public var points: [SIMD2<Double>]
        /// The same loop in the file's own units and frame, for placement().
        public var outline: [SIMD2<Double>]

        /// Where the element sits, and its section upright: unit chord, leading
        /// edge at the origin, chord along +x, positive camber, Selig order. The
        /// inverse of WingElement.placed(): a section whose camber points down
        /// in the file is an inverted element. `scale` turns file units into metres.
        public func placement(scale: Double = 1) -> Placement {
            let p = outline.map { $0 * scale }
            let te = 0.5 * (p[0] + p[p.count - 1])
            let le = p.max { simd_distance($0, te) < simd_distance($1, te) }!
            let v = te - le, chord = simd_length(v), phi = atan2(v.y, v.x)
            let c = cos(phi), s = sin(phi)
            var unit = p.map { q -> SIMD2<Double> in
                let d = (q - le) / chord
                return SIMD2(c * d.x + s * d.y, -s * d.x + c * d.y)
            }
            let i = unit.indices.min { unit[$0].x < unit[$1].x }!
            func meanY(_ s: ArraySlice<SIMD2<Double>>) -> Double { s.reduce(0) { $0 + $1.y } / Double(s.count) }
            if meanY(unit[...i]) < meanY(unit[i...]) { unit.reverse() }  // upper surface first
            let camber = Airfoil(key: "", name: "", family: "", source: "", thickness: 0, thicknessX: 0, camber: 0,
                                 camberX: 0, teThickness: 0, coords: unit).measured().camber
            let inverted = camber < 0
            if inverted { unit = unit.reversed().map { SIMD2($0.x, -$0.y) } }
            return Placement(section: unit, chord: chord, angle: (inverted ? 1 : -1) * phi * 180 / .pi,
                             leadingEdge: le, inverted: inverted)
        }
    }

    public struct Placement: Equatable, Sendable {
        public var section: [SIMD2<Double>]
        public var chord: Double
        public var angle: Double  // degrees, as WingElement.angle
        public var leadingEdge: SIMD2<Double>
        public var inverted: Bool
    }

    /// Metres per file unit for a wing's elements: millimetres when any chord
    /// is over 2 (no element is 2 m long), else metres.
    public static func metresPerUnit(_ elements: [Element]) -> Double {
        elements.contains { $0.placement().chord > 2 } ? 0.001 : 1
    }

    /// Label rows that only split one section into its surfaces.
    private static let surfaceWords = ["upper", "lower", "top", "bottom", "suction", "pressure", "surface"]

    /// The points of a file that holds one section.
    public static func parse(_ text: String) throws -> [SIMD2<Double>] {
        let elements = try parseElements(text)
        guard elements.count == 1 else { throw ParseError.severalElements(elements.count) }
        return elements[0].points
    }

    /// Every element in the file, in the order they first appear.
    public static func parseElements(_ text: String) throws -> [Element] {
        let lines = text.components(separatedBy: .newlines)
        let separator: Character = text.contains("\t") ? "\t" : text.contains(";") ? ";" : ","
        let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'\u{FEFF}"))
        var columns: (x: Int, y: Int)?  // from a header that names x and y
        var groups: [(name: String?, blocks: [[SIMD2<Double>]])] = [(nil, [[]])]
        func breakBlock() {
            if !groups[groups.count - 1].blocks[groups[groups.count - 1].blocks.count - 1].isEmpty {
                groups[groups.count - 1].blocks.append([])
            }
        }
        func start(_ name: String) {
            if groups[groups.count - 1].blocks.joined().isEmpty { groups[groups.count - 1].name = name } else { groups.append((name, [[]])) }
        }
        for (i, line) in lines.enumerated() {
            let fields = line.split(separator: separator, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: trim) }
            if fields.allSatisfy(\.isEmpty) {  // blank line: a break between surfaces
                breakBlock()
                continue
            }
            // Double(_:) ignores the user's locale, so "1,184" never reads as 1184. With a
            // semicolon or tab separator a comma can only be a decimal mark.
            let numbers = fields.map { Double(separator == "," ? $0 : $0.replacingOccurrences(of: ",", with: ".")) }
            if numbers.allSatisfy({ $0 == nil }) {  // a header, a surface label or an element's name
                let lower = fields.map { $0.lowercased() }
                if let x = lower.firstIndex(where: { $0.hasPrefix("x") }), let y = lower.firstIndex(where: { $0.hasPrefix("y") }) {
                    columns = columns ?? (x, y)  // a header, perhaps repeated before each element
                } else if lower.contains(where: { f in surfaceWords.contains { f.contains($0) } }) {
                    breakBlock()
                } else {
                    start(fields.filter { !$0.isEmpty }.joined(separator: " "))
                }
                continue
            }
            guard fields.count >= 2 else { throw ParseError.oneColumn(line: i + 1) }
            let numeric = numbers.indices.filter { numbers[$0] != nil }
            if columns == nil && numeric.count < 2 {
                throw ParseError.notANumber(line: i + 1, field: fields[numbers.firstIndex(where: { $0 == nil })!])
            }
            let (xi, yi) = columns ?? (numeric[numeric.count - 2], numeric[numeric.count - 1])
            for k in [xi, yi] where k >= fields.count || numbers[k] == nil || !numbers[k]!.isFinite {
                throw ParseError.notANumber(line: i + 1, field: k < fields.count ? fields[k] : "")
            }
            if let label = fields.indices.first(where: { numbers[$0] == nil && !fields[$0].isEmpty && $0 != xi && $0 != yi }),
               fields[label] != groups[groups.count - 1].name {
                start(fields[label])
            }
            groups[groups.count - 1].blocks[groups[groups.count - 1].blocks.count - 1].append(SIMD2(numbers[xi]!, numbers[yi]!))
        }
        let filled = groups.filter { !$0.blocks.joined().isEmpty }
        guard !filled.isEmpty else { throw ParseError.tooFewPoints(0) }
        return try filled.map { g in
            do {
                let loop = try outline(g.blocks.filter { !$0.isEmpty })
                let minX = loop.map(\.x).min()!, extent = loop.map(\.x).max()! - minX
                return Element(name: g.name, points: loop.map { SIMD2(($0.x - minX) / extent, $0.y / extent) }, outline: loop)
            } catch let error as ParseError where g.name != nil && filled.count > 1 {
                throw ParseError.inElement(g.name!, error)
            }
        }
    }

    /// One section's blocks of points as one loop from the trailing edge, upper surface first.
    private static func outline(_ blocks: [[SIMD2<Double>]]) throws -> [SIMD2<Double>] {
        let count = blocks.reduce(0) { $0 + $1.count }
        guard count >= 6 else { throw ParseError.tooFewPoints(count) }
        guard blocks.count <= 2 else { throw ParseError.tooManyBlocks(blocks.count) }

        let minX = blocks.joined().map(\.x).min()!, maxX = blocks.joined().map(\.x).max()!
        let chord = maxX - minX
        guard chord > 0 else { throw ParseError.zeroChord }
        let surfaces = blocks.count == 2 ? blocks : split(blocks[0], tolerance: chord * 1e-9)
        guard surfaces.allSatisfy({ $0.count >= 2 }) else { throw ParseError.notAnAirfoil }

        // Each surface from leading to trailing edge, then the upper one first.
        var (a, b) = (surfaces[0], surfaces[1])
        if a[0].x > a[a.count - 1].x { a.reverse() }
        if b[0].x > b[b.count - 1].x { b.reverse() }
        func meanY(_ s: [SIMD2<Double>]) -> Double { s.reduce(0) { $0 + $1.y } / Double(s.count) }
        let (upper, lower) = meanY(a) >= meanY(b) ? (a, b) : (b, a)
        return Array(upper.reversed()) + (upper[0] == lower[0] ? lower.dropFirst() : lower[...])
    }

    /// A Selig .dat: the name line, then one "x y" pair per line.
    public static func dat(name: String, points: [SIMD2<Double>]) -> String {
        ([name] + points.map { String(format: "%.6f %.6f", $0.x, $0.y) }).joined(separator: "\n") + "\n"
    }

    /// One run of points cut into two surfaces by where x turns: a Selig loop
    /// turns once, at the leading edge, and two surfaces listed one after
    /// the other turn twice with a single jump back between them.
    private static func split(_ p: [SIMD2<Double>], tolerance: Double) -> [[SIMD2<Double>]] {
        var runs: [(sign: Bool, first: Int, last: Int)] = []  // steps i to i+1, x rising or falling
        for i in 0..<(p.count - 1) {
            let dx = p[i + 1].x - p[i].x
            guard abs(dx) > tolerance else { continue }
            if let r = runs.last, r.sign == (dx > 0) {
                runs[runs.count - 1].last = i
            } else {
                runs.append((dx > 0, i, i))
            }
        }
        // shortcut: a loop from the LE is refused, since an open TE's points could go to
        // either surface; split it at the TE by its steep gap step if such files turn up.
        if runs.count == 2, !runs[0].sign {  // from the TE: both surfaces share the LE point
            let turn = runs[1].first
            return [Array(p[...turn]), Array(p[turn...])]
        }
        if runs.count == 3, runs[1].first == runs[1].last {
            let jump = runs[1].first
            return [Array(p[...jump]), Array(p[(jump + 1)...])]
        }
        return [[], []]
    }
}
