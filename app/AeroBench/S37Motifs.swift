import SwiftUI

/// The faint line behind each tool: a different space-filling curve per
/// tool, run edge to edge across the window.
enum S37Motif: Equatable, Sendable {
    case hilbert, terdragon, moore, peano, gosper, sierpinski, dragon
}

enum S37Motifs {
    static let ochre = (230.0, 177.0, 78.0), bone = (183.0, 176.0, 163.0)
    static func c(_ t: (Double, Double, Double), _ a: Double) -> Color { Color(t.0, t.1, t.2, a) }
    static let bg = Color(hex: 0x100e0b)
    /// About this far between turns, whatever the window size
    static let step = 18.0

    struct LSystem {
        var axiom: String
        var rules: [Character: String]
        var angle: Double  // degrees
        var draws: Set<Character> = ["F"]
    }

    static func system(_ motif: S37Motif) -> LSystem {
        switch motif {
        case .hilbert:
            LSystem(axiom: "A", rules: ["A": "+BF-AFA-FB+", "B": "-AF+BFB+FA-"], angle: 90)
        case .moore:
            LSystem(axiom: "LFL+F+LFL", rules: ["L": "-RF+LFL+FR-", "R": "+LF-RFR-FL+"], angle: 90)
        case .peano:
            LSystem(axiom: "X", rules: ["X": "XFYFX+F+YFXFY-F-XFYFX", "Y": "YFXFY-F-XFYFX+F+YFXFY"], angle: 90)
        case .terdragon:
            LSystem(axiom: "F", rules: ["F": "F+F-F"], angle: 120)
        case .gosper:
            LSystem(axiom: "A", rules: ["A": "A-B--B+A++AA+B-", "B": "+A-BB--B-A++A+B"], angle: 60, draws: ["A", "B"])
        case .sierpinski:
            LSystem(axiom: "F--XF--F--XF", rules: ["X": "XF+G+XF--F--XF+G+X"], angle: 45, draws: ["F", "G"])
        case .dragon:
            LSystem(axiom: "FX", rules: ["X": "X+YF+", "Y": "-FX-Y"], angle: 90)
        }
    }

    /// The curve after `n` rewrites, as unit-step turtle points
    static func trace(_ l: LSystem, _ n: Int) -> [CGPoint] {
        var s = Array(l.axiom)
        for _ in 0..<n { s = s.flatMap { l.rules[$0].map(Array.init) ?? [$0] } }
        let turn = l.angle * .pi / 180
        var heading = 0.0, p = CGPoint.zero, points = [p]
        for ch in s {
            switch ch {
            case "+": heading += turn
            case "-": heading -= turn
            default:
                if l.draws.contains(ch) {
                    p = CGPoint(x: p.x + cos(heading), y: p.y + sin(heading))
                    points.append(p)
                }
            }
        }
        return points
    }

    static func bounds(_ points: [CGPoint]) -> CGRect {
        var r = CGRect(origin: points[0], size: .zero)
        for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }

    /// The largest rectangle of the given aspect the curve covers with no gap over
    /// three steps, in curve units: a summed-area table over a grid of 3-step cells,
    /// binary searched on height. One ring of cells is left off so the edges are solid too.
    static func solidRect(_ points: [CGPoint], aspect: Double) -> CGRect? {
        let cell = 3.0, b = bounds(points)
        let cols = Int(b.width / cell) + 1, rows = Int(b.height / cell) + 1
        guard cols > 2, rows > 2 else { return nil }
        var sat = [Int](repeating: 0, count: (cols + 1) * (rows + 1))  // sat[(r) * (cols + 1) + c]: hits above and left
        var hit = [Bool](repeating: false, count: cols * rows)
        for p in points { hit[Int((p.y - b.minY) / cell) * cols + Int((p.x - b.minX) / cell)] = true }
        for r in 0..<rows {
            for c in 0..<cols {
                sat[(r + 1) * (cols + 1) + c + 1] = (hit[r * cols + c] ? 1 : 0)
                    + sat[r * (cols + 1) + c + 1] + sat[(r + 1) * (cols + 1) + c] - sat[r * (cols + 1) + c]
            }
        }
        func filled(_ c: Int, _ r: Int, _ w: Int, _ h: Int) -> Bool {
            sat[(r + h) * (cols + 1) + c + w] - sat[r * (cols + 1) + c + w] - sat[(r + h) * (cols + 1) + c] + sat[r * (cols + 1) + c] == w * h
        }
        func place(_ h: Int) -> (Int, Int, Int)? {  // a solid (w + 2) by (h + 2) block, ring included
            let w = max(1, Int((Double(h) * aspect).rounded()))
            guard w + 2 <= cols, h + 2 <= rows else { return nil }
            for r in 0...(rows - h - 2) { for c in 0...(cols - w - 2) where filled(c, r, w + 2, h + 2) { return (c + 1, r + 1, w) } }
            return nil
        }
        var lo = 0, hi = rows, found: (Int, Int, Int, Int)?
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if let (c, r, w) = place(mid) { found = (c, r, w, mid); lo = mid } else { hi = mid - 1 }
        }
        guard let (c, r, w, h) = found else { return nil }
        return CGRect(x: b.minX + Double(c) * cell, y: b.minY + Double(r) * cell, width: Double(w) * cell, height: Double(h) * cell)
    }

    static func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ motif: S37Motif) {
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(rect), with: .color(bg))
        ctx.fill(Path(rect), with: .radialGradient(Gradient(colors: [c(ochre, 0.05), c(ochre, 0)]),
                                                   center: CGPoint(x: size.width * 0.82, y: size.height * 0.12),
                                                   startRadius: 0, endRadius: max(size.width, size.height) * 0.5))
        guard size.width > 0, size.height > 0 else { return }
        // Most of these curves fill a diamond or an island, not a rectangle, so fit the
        // window to the largest window-shaped rectangle the curve fills solid, not its bounds.
        // Rewrite until that fit's step drops under `step`, then keep the closer of the last two.
        let l = system(motif)
        var best: (points: [CGPoint], solid: CGRect, scale: Double)?
        for n in 1...16 {
            let points = trace(l, n)
            guard let solid = solidRect(points, aspect: size.width / size.height) else { continue }
            let scale = max(size.width / solid.width, size.height / solid.height)
            if let prev = best, scale < step {
                if step / scale < prev.scale / step { best = (points, solid, scale) }
                break
            }
            best = (points, solid, scale)
            if points.count > 300_000 { break }
        }
        guard let (points, solid, scale) = best else { return }
        let ox = size.width / 2 - solid.midX * scale
        let oy = size.height / 2 - solid.midY * scale
        var path = Path()
        path.addLines(points.map { CGPoint(x: ox + $0.x * scale, y: oy + $0.y * scale) })
        ctx.stroke(path, with: .color(c(bone, 0.11)), lineWidth: 0.9)
    }
}
