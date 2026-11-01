import Foundation

/// A Lap Sim track drawn in the app as a chain of cubic Bézier curves. Each
/// node is a point on the centreline with two handles that stay in line (the
/// curve leaves along `out` and arrives along `in`), so the line never kinks.
/// The engine gets it as densely sampled centreline points.
public struct DrawnTrack: Codable, Equatable, Sendable {
    public struct Node: Codable, Equatable, Sendable {
        public var x: Double  // m
        public var y: Double
        public var inX: Double  // handle the curve arrives along, m from the point
        public var inY: Double
        public var outX: Double  // handle the curve leaves along
        public var outY: Double

        public init(x: Double, y: Double, inX: Double, inY: Double, outX: Double, outY: Double) {
            self.x = x
            self.y = y
            self.inX = inX
            self.inY = inY
            self.outX = outX
            self.outY = outY
        }

        public var point: SIMD2<Double> { [x, y] }
        public var inHandle: SIMD2<Double> { [inX, inY] }
        public var outHandle: SIMD2<Double> { [outX, outY] }
    }

    public struct Sample: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var s: Double  // m from the first node
        public var kappa: Double  // signed curvature, 1/m
        public var segment: Int
    }

    public struct Issue: Equatable, Sendable {
        public enum Kind: Sendable { case tooTight, longStraight }
        public var kind: Kind
        /// Sample indices it covers, start ..< start + count, wrapping on a closed track.
        public var start: Int
        public var count: Int
        public var s: Double  // m along the lap where it starts
        /// Tightest radius for a turn, length for a straight, m.
        public var value: Double
    }

    // shortcut: endurance and autocross share these in data/rules/fs2027_tracks.json; read the file if a season splits them.
    /// FS D 7.1.1 and D 6.1.1: hairpins at least 9 m outside diameter, so a
    /// centreline radius of 4.5 m less half the 3 m minimum track width; 80 m
    /// longest straight.
    public static let minRadius = 3.0
    public static let straightMax = 80.0
    /// Flatter than this counts as straight, as the engine's generator counts it.
    public static let straightRadius = 150.0

    public var nodes: [Node] = []
    public var closed = true
    /// The track it was copied from.
    public var source: String?

    public init(nodes: [Node] = [], closed: Bool = true, source: String? = nil) {
        self.nodes = nodes
        self.closed = closed
        self.source = source
    }

    public var segmentCount: Int { nodes.count < 2 ? 0 : (closed ? nodes.count : nodes.count - 1) }
    /// Enough nodes for the engine to fit a line through.
    public var isUsable: Bool { nodes.count >= (closed ? 3 : 2) }

    /// Bézier control points of segment i (node i to the next).
    public func controls(_ i: Int) -> [SIMD2<Double>] {
        let a = nodes[i], b = nodes[(i + 1) % nodes.count]
        return [a.point, a.point + a.outHandle, b.point + b.inHandle, b.point]
    }

    public func point(_ i: Int, _ t: Double) -> SIMD2<Double> {
        let p = controls(i), u = 1 - t
        return u * u * u * p[0] + 3 * u * u * t * p[1] + 3 * u * t * t * p[2] + t * t * t * p[3]
    }

    private func curvature(_ p: [SIMD2<Double>], _ t: Double) -> Double {
        let u = 1 - t
        let d1 = 3 * u * u * (p[1] - p[0]) + 6 * u * t * (p[2] - p[1]) + 3 * t * t * (p[3] - p[2])
        let d2 = 6 * u * (p[2] - 2 * p[1] + p[0]) + 6 * t * (p[3] - 2 * p[2] + p[1])
        let speed = (d1 * d1).sum().squareRoot()
        return speed < 1e-12 ? 0 : (d1.x * d2.y - d1.y * d2.x) / (speed * speed * speed)
    }

    /// Points along the line about `spacing` apart. On a closed track the last is the first again.
    public func samples(spacing: Double = 0.5) -> [Sample] {
        var out: [Sample] = []
        var s = 0.0
        for i in 0..<segmentCount {
            let p = controls(i)
            let polygon = zip(p, p.dropFirst()).map { (($1 - $0) * ($1 - $0)).sum().squareRoot() }.reduce(0, +)
            let n = max(Int(polygon / spacing) + 1, 8)
            for k in (i == 0 ? 0 : 1)...n {
                let t = Double(k) / Double(n)
                let q = point(i, t)
                if let last = out.last { s += ((q - [last.x, last.y]) * (q - [last.x, last.y])).sum().squareRoot() }
                out.append(Sample(x: q.x, y: q.y, s: s, kappa: curvature(p, t), segment: i))
            }
        }
        return out
    }

    public var length: Double { samples(spacing: 0.25).last?.s ?? 0 }

    /// Tightest radius and longest straight, m.
    public func extremes(_ samples: [Sample]) -> (minRadius: Double, longestStraight: Double) {
        let k = samples.map { abs($0.kappa) }.max() ?? 0
        return (k > 0 ? 1 / k : .infinity, straights(samples).map(\.length).max() ?? 0)
    }

    /// Runs flatter than `straightRadius`: (start, count, length).
    private func straights(_ samples: [Sample]) -> [(start: Int, count: Int, length: Double)] {
        guard samples.count > 1 else { return [] }
        // A closed track's last sample repeats the first.
        let pts = closed ? Array(samples.dropLast()) : samples
        let step = { (i: Int) -> Double in
            let j = (i + 1) % pts.count
            return j == 0 ? (samples.last!.s - pts[i].s) : pts[j].s - pts[i].s
        }
        return Self.runs(pts.map { abs($0.kappa) < 1 / Self.straightRadius }, closed: closed).map { start, count in
            (start, count, (start..<start + count - 1).map { step($0 % pts.count) }.reduce(0, +))
        }
    }

    /// Where the line breaks the FS layout rules: turns tighter than the
    /// turning diameter, straights longer than allowed.
    public func issues(_ samples: [Sample]) -> [Issue] {
        guard samples.count > 1 else { return [] }
        let pts = closed ? Array(samples.dropLast()) : samples
        var found: [Issue] = []
        for (start, count) in Self.runs(pts.map { abs($0.kappa) > 1 / Self.minRadius }, closed: closed) {
            let idx = (start..<start + count).map { $0 % pts.count }
            let k = idx.map { abs(pts[$0].kappa) }.max() ?? 0
            found.append(Issue(kind: .tooTight, start: start, count: count, s: pts[start].s, value: 1 / k))
        }
        for run in straights(samples) where run.length > Self.straightMax {
            found.append(Issue(kind: .longStraight, start: run.start, count: run.count, s: pts[run.start].s, value: run.length))
        }
        return found.sorted { $0.s < $1.s }
    }

    /// Runs of true as (start, count); on a closed track a run can wrap past the end.
    static func runs(_ flags: [Bool], closed: Bool) -> [(Int, Int)] {
        guard flags.contains(true) else { return [] }
        guard flags.contains(false) else { return [(0, flags.count)] }
        let first = closed ? (flags.firstIndex(of: false)! + 1) % flags.count : 0
        var out: [(Int, Int)] = []
        var start: Int?
        for k in 0..<flags.count {
            let i = (first + k) % flags.count
            if flags[i], start == nil { start = first + k }
            if !flags[i], let s = start {
                out.append((s % flags.count, first + k - s))
                start = nil
            }
        }
        if let s = start { out.append((s % flags.count, first + flags.count - s)) }
        return out
    }

    /// The centreline for the engine, about a metre apart (the engine resamples it).
    public func jobValue() -> JSONValue {
        var pts = samples(spacing: 1)
        if closed, !pts.isEmpty { pts.removeLast() }
        return .object([
            "points": .object(["x": .array(pts.map { .double($0.x) }), "y": .array(pts.map { .double($0.y) })]),
            "closed": .bool(closed),
            "name": .string("Drawn track"),
        ])
    }

    // MARK: Editing

    /// The nearest point on the line to `p`: segment, parameter and distance.
    public func nearest(to p: SIMD2<Double>) -> (segment: Int, t: Double, distance: Double)? {
        var best: (Int, Double, Double)?
        for i in 0..<segmentCount {
            for k in 0...64 {
                let t = Double(k) / 64
                let d = ((point(i, t) - p) * (point(i, t) - p)).sum().squareRoot()
                if best == nil || d < best!.2 { best = (i, t, d) }
            }
        }
        return best.map { ($0.0, $0.1, $0.2) }
    }

    /// Adds a node on segment i at t without changing the line's shape (de Casteljau).
    @discardableResult
    public mutating func split(segment i: Int, at t: Double) -> Int {
        let p = controls(i)
        let q0 = p[0] + t * (p[1] - p[0]), q1 = p[1] + t * (p[2] - p[1]), q2 = p[2] + t * (p[3] - p[2])
        let r0 = q0 + t * (q1 - q0), r1 = q1 + t * (q2 - q1)
        let s = r0 + t * (r1 - r0)
        let j = (i + 1) % nodes.count
        nodes[i].outX = q0.x - p[0].x
        nodes[i].outY = q0.y - p[0].y
        nodes[j].inX = q2.x - p[3].x
        nodes[j].inY = q2.y - p[3].y
        nodes.insert(Node(x: s.x, y: s.y, inX: r0.x - s.x, inY: r0.y - s.y, outX: r1.x - s.x, outY: r1.y - s.y), at: i + 1)
        return i + 1
    }

    /// Sets one handle; the other turns to stay in line and keeps its length.
    public mutating func setHandle(_ i: Int, out: Bool, to h: SIMD2<Double>) {
        let len = (h * h).sum().squareRoot()
        guard len > 1e-9 else { return }
        let other = out ? nodes[i].inHandle : nodes[i].outHandle
        let back = -h / len * (other * other).sum().squareRoot()
        if out {
            (nodes[i].outX, nodes[i].outY, nodes[i].inX, nodes[i].inY) = (h.x, h.y, back.x, back.y)
        } else {
            (nodes[i].inX, nodes[i].inY, nodes[i].outX, nodes[i].outY) = (h.x, h.y, back.x, back.y)
        }
    }

    /// The other way round the lap.
    public func reversed() -> DrawnTrack {
        var t = self
        t.nodes = nodes.reversed().map { Node(x: $0.x, y: $0.y, inX: $0.outX, inY: $0.outY, outX: $0.inX, outY: $0.inY) }
        return t
    }

    // MARK: Fitting

    /// From the warm engine's lapsim-track reply: a track's centreline.
    public static func fit(engineReply data: Data, source: String) throws -> DrawnTrack {
        struct Centreline: Decodable { var closed: Bool; var x: [Double]; var y: [Double] }
        struct Envelope: Decodable { var data: Centreline }
        let c = try JSONDecoder().decode(Envelope.self, from: data).data
        return fit(x: c.x, y: c.y, closed: c.closed, source: source)
    }

    /// Few enough nodes to drag about, through a dense centreline (the
    /// engine's, every half metre): a node every `maxSpacing` metres of
    /// straight, or every `maxTurn` radians of turn, whichever comes first,
    /// and more where the curve would stray over `tolerance` metres from it.
    public static func fit(x: [Double], y: [Double], closed: Bool, source: String? = nil,
                           maxSpacing: Double = 25, maxTurn: Double = 35 * .pi / 180, tolerance: Double = 0.1) -> DrawnTrack {
        var pts = zip(x, y).map { SIMD2($0, $1) }
        if closed, pts.count > 1, ((pts[0] - pts[pts.count - 1]) * (pts[0] - pts[pts.count - 1])).sum() < 1e-12 {
            pts.removeLast()
        }
        let n = pts.count
        guard n >= 4 else { return DrawnTrack(closed: closed, source: source) }
        let at = { (i: Int) -> SIMD2<Double> in closed ? pts[(i % n + n) % n] : pts[min(max(i, 0), n - 1)] }
        var s = [0.0]
        for i in 1..<n { s.append(s[i - 1] + ((pts[i] - pts[i - 1]) * (pts[i] - pts[i - 1])).sum().squareRoot()) }
        let total = closed ? s[n - 1] + ((pts[0] - pts[n - 1]) * (pts[0] - pts[n - 1])).sum().squareRoot() : s[n - 1]
        let tangent = { (i: Int) -> SIMD2<Double> in
            let d = at(i + 2) - at(i - 2)
            return d / max((d * d).sum().squareRoot(), 1e-12)
        }
        var heading = [atan2(tangent(0).y, tangent(0).x)]
        for i in 1..<n {
            let t = tangent(i)
            var h = atan2(t.y, t.x)
            while h - heading[i - 1] > .pi { h -= 2 * .pi }
            while h - heading[i - 1] < -.pi { h += 2 * .pi }
            heading.append(h)
        }
        // Turning either way counts, so an S-bend gets its nodes too.
        var picks = [0]
        var turned = 0.0
        for i in 1..<n {
            turned += abs(heading[i] - heading[i - 1])
            if s[i] - s[picks.last!] >= maxSpacing || turned >= maxTurn {
                picks.append(i)
                turned = 0
            }
        }
        if closed {
            // The last node must not crowd the first: drop it when the gap to close is under 40% of a step.
            if picks.count > 3, total - s[picks.last!] < 0.4 * (s[picks.last!] - s[picks[picks.count - 2]]) { picks.removeLast() }
        } else if picks.last != n - 1 {
            if picks.count > 1, s[n - 1] - s[picks.last!] < 0.4 * (s[picks.last!] - s[picks[picks.count - 2]]) { picks.removeLast() }
            picks.append(n - 1)
        }
        func build(_ picks: [Int]) -> DrawnTrack {
            let gaps = picks.indices.map { k -> Double in
                if k + 1 < picks.count { return s[picks[k + 1]] - s[picks[k]] }
                return closed ? total - s[picks[k]] : 0
            }
            // Handle lengths per segment, (out of its first node, into its last): least
            // squares through the points between (Schneider, Graphics Gems 1990),
            // or as for a circular arc, 4/3 tan(turn/4) R, when that fails.
            let handles = picks.indices.map { k -> (Double, Double) in
                let a = picks[k], b = k + 1 < picks.count ? picks[k + 1] : (closed ? n : a)
                let t1 = tangent(a), t2 = -tangent(b)
                let turn = abs(atan2(t1.x * -t2.y + t1.y * t2.x, -(t1 * t2).sum()))
                let arc = turn < 1e-6 ? gaps[k] / 3 : 4.0 / 3 * tan(turn / 4) * gaps[k] / turn
                guard b - a > 2 else { return (arc, arc) }
                let p0 = at(a), p3 = at(b)
                var c00 = 0.0, c01 = 0.0, c11 = 0.0, x0 = 0.0, x1 = 0.0
                for i in a...b {
                    let u = ((i == n ? total : s[i]) - s[a]) / gaps[k], v = 1 - u
                    let a1 = 3 * v * v * u * t1, a2 = 3 * v * u * u * t2
                    let rest = at(i) - (v * v * v + 3 * v * v * u) * p0 - (3 * v * u * u + u * u * u) * p3
                    c00 += (a1 * a1).sum(); c01 += (a1 * a2).sum(); c11 += (a2 * a2).sum()
                    x0 += (a1 * rest).sum(); x1 += (a2 * rest).sum()
                }
                let det = c00 * c11 - c01 * c01
                guard abs(det) > 1e-12 else { return (arc, arc) }
                let l1 = (x0 * c11 - x1 * c01) / det, l2 = (c00 * x1 - c01 * x0) / det
                return l1 > 0.05 * gaps[k] && l2 > 0.05 * gaps[k] && l1 < gaps[k] && l2 < gaps[k] ? (l1, l2) : (arc, arc)
            }
            let nodes = picks.indices.map { k -> Node in
                let p = pts[picks[k]], t = tangent(picks[k])
                let before = k > 0 ? handles[k - 1].1 : (closed ? handles[picks.count - 1].1 : 0)
                let after = k + 1 < picks.count || closed ? handles[k].0 : 0
                return Node(x: p.x, y: p.y, inX: -t.x * before, inY: -t.y * before, outX: t.x * after, outY: t.y * after)
            }
            return DrawnTrack(nodes: nodes, closed: closed, source: source)
        }
        // Split any segment that strays more than `tolerance` from the line it copies.
        var track = build(picks)
        for _ in 0..<8 {
            var added: [Int] = []
            for k in 0..<track.segmentCount {
                let a = picks[k], b = k + 1 < picks.count ? picks[k + 1] : n
                guard b - a > 2 else { continue }
                let curve = (0...128).map { track.point(k, Double($0) / 128) }
                let worst = (a..<b).map { i in
                    zip(curve, curve.dropFirst()).map { distanceSquared(pts[i], $0, $1) }.min()!
                }.max()!
                if worst > tolerance * tolerance { added.append((a + b) / 2) }
            }
            if added.isEmpty { break }
            picks = (picks + added).sorted()
            track = build(picks)
        }
        return track
    }

    /// From p to the line segment a-b, squared.
    private static func distanceSquared(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a, len2 = (ab * ab).sum()
        let t = len2 > 0 ? min(max(((p - a) * ab).sum() / len2, 0), 1) : 0
        let d = p - (a + t * ab)
        return (d * d).sum()
    }
}
