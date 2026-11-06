import Foundation

/// Airfoil coordinates from a CSV file: x and y in the first two columns,
/// comma, semicolon or tab separated, with or without a header row, as one
/// Selig loop or as upper and lower surfaces, in any chord length. The result
/// is a Selig .dat the engine's import reads like any other.
public enum AirfoilCSV {
    public enum ParseError: LocalizedError, Equatable {
        case tooFewPoints(Int)
        case notANumber(line: Int, field: String)
        case oneColumn(line: Int)
        case tooManyBlocks(Int)
        case notAnAirfoil
        case zeroChord

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
            }
        }
    }

    /// Points in Selig order (trailing edge, upper surface, leading edge,
    /// lower surface), scaled to unit chord with the leading edge at x = 0.
    public static func parse(_ text: String) throws -> [SIMD2<Double>] {
        let lines = text.components(separatedBy: .newlines)
        let separator: Character = text.contains("\t") ? "\t" : text.contains(";") ? ";" : ","
        let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'\u{FEFF}"))
        var blocks: [[SIMD2<Double>]] = [[]]
        for (i, line) in lines.enumerated() {
            let fields = line.split(separator: separator, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: trim) }
            if fields.allSatisfy(\.isEmpty) {  // blank line: a break between surfaces
                if !blocks[blocks.count - 1].isEmpty { blocks.append([]) }
                continue
            }
            // Double(_:) ignores the user's locale, so "1,184" never reads as 1184. With a
            // semicolon or tab separator a comma can only be a decimal mark.
            let numbers = fields.map { Double(separator == "," ? $0 : $0.replacingOccurrences(of: ",", with: ".")) }
            if numbers.allSatisfy({ $0 == nil }) {  // header or a label such as "upper"
                if !blocks[blocks.count - 1].isEmpty { blocks.append([]) }
                continue
            }
            guard fields.count >= 2 else { throw ParseError.oneColumn(line: i + 1) }
            for k in 0..<2 where numbers[k] == nil || !numbers[k]!.isFinite {
                throw ParseError.notANumber(line: i + 1, field: fields[k])
            }
            blocks[blocks.count - 1].append(SIMD2(numbers[0]!, numbers[1]!))
        }
        blocks.removeAll(where: \.isEmpty)
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
        let loop = Array(upper.reversed()) + (upper[0] == lower[0] ? lower.dropFirst() : lower[...])
        return loop.map { SIMD2(($0.x - minX) / chord, $0.y / chord) }
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
