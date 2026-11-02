import SwiftUI

/// The faint line behind each tool: a different space-filling curve per
/// tool, run edge to edge across the window.
enum S37Motif: Equatable, Sendable {
    case hilbert, arrowhead, moore, peano, gosper, sierpinski, dragon
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
        case .arrowhead:
            LSystem(axiom: "A", rules: ["A": "B-A-B", "B": "A+B+A"], angle: 60, draws: ["A", "B"])
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

    static func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ motif: S37Motif) {
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(rect), with: .color(bg))
        ctx.fill(Path(rect), with: .radialGradient(Gradient(colors: [c(ochre, 0.05), c(ochre, 0)]),
                                                   center: CGPoint(x: size.width * 0.82, y: size.height * 0.12),
                                                   startRadius: 0, endRadius: max(size.width, size.height) * 0.5))
        guard size.width > 0, size.height > 0 else { return }
        // rewrite until a step covering the window drops under `step`, then keep the closer of the last two
        let l = system(motif)
        var best: (points: [CGPoint], scale: Double)?
        for n in 1...16 {
            let points = trace(l, n), b = bounds(points)
            let scale = max(size.width / max(b.width, 1), size.height / max(b.height, 1))
            if let prev = best, scale < step {
                if step / scale < prev.scale / step { best = (points, scale) }
                break
            }
            best = (points, scale)
            if points.count > 300_000 { break }
        }
        guard let (points, scale) = best else { return }
        let b = bounds(points)
        let ox = (size.width - b.width * scale) / 2 - b.minX * scale
        let oy = (size.height - b.height * scale) / 2 - b.minY * scale
        var path = Path()
        path.addLines(points.map { CGPoint(x: ox + $0.x * scale, y: oy + $0.y * scale) })
        ctx.stroke(path, with: .color(c(bone, 0.07)), lineWidth: 0.75)
    }
}
