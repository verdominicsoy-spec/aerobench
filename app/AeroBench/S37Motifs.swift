import SwiftUI

/// The quiet line drawing behind each tool: what the tool is about, kept to
/// the header band and the gutters and faded out before the panes.
enum S37Motif: Equatable, Sendable {
    case plain, wing, track, floor, vortex, prism
}

enum S37Motifs {
    static let sage = (150.0, 183.0, 127.0), ochre = (230.0, 177.0, 78.0), bone = (183.0, 176.0, 163.0)
    static func c(_ t: (Double, Double, Double), _ a: Double) -> Color { Color(t.0, t.1, t.2, a) }
    static let bg = Color(hex: 0x100e0b)

    static func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ motif: S37Motif) {
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(rect), with: .color(bg))
        // the faint ochre glow every tool keeps, top right
        ctx.fill(Path(rect), with: .radialGradient(Gradient(colors: [c(ochre, 0.05), c(ochre, 0)]),
                                                   center: CGPoint(x: size.width * 0.82, y: size.height * 0.12),
                                                   startRadius: 0, endRadius: max(size.width, size.height) * 0.5))
        switch motif {
        case .plain: break
        case .wing: wing(&ctx, size)
        case .track: track(&ctx, size)
        case .floor: floor(&ctx, size)
        case .vortex: vortex(&ctx, size)
        case .prism: prism(&ctx, size)
        }
    }

    /// Lays bg over the drawing, opaque at `from` and clear by `to`
    static func fade(_ ctx: inout GraphicsContext, _ size: CGSize, from: CGPoint, to: CGPoint) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: [bg, bg.opacity(0)]), startPoint: from, endPoint: to))
    }

    // MARK: Wing Lab

    struct Z {
        var re: Double, im: Double
        init(_ re: Double, _ im: Double) { self.re = re; self.im = im }
        static func + (a: Z, b: Z) -> Z { Z(a.re + b.re, a.im + b.im) }
        static func - (a: Z, b: Z) -> Z { Z(a.re - b.re, a.im - b.im) }
        static func * (a: Z, b: Z) -> Z { Z(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re) }
        static func * (a: Z, k: Double) -> Z { Z(a.re * k, a.im * k) }
        static func / (a: Z, b: Z) -> Z {
            let d = b.re * b.re + b.im * b.im
            return Z((a.re * b.re + a.im * b.im) / d, (a.im * b.re - a.re * b.im) / d)
        }
        var conj: Z { Z(re, -im) }
        var abs: Double { hypot(re, im) }
    }

    /// Potential-flow streamlines round a Joukowski section with the Kutta
    /// condition, pitched 9° and drawn upside down like a rear wing, so the
    /// lines bunch underneath on the suction side.
    static func wing(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        let alpha = 9 * Double.pi / 180, eps = 0.1, mu = 0.1
        let z0 = Z(-eps, mu), R = hypot(1 + eps, mu)
        let gamma = 4 * Double.pi * R * sin(alpha + atan2(mu, 1 + eps))
        let ea = Z(cos(alpha), sin(alpha)), eaBar = ea.conj
        // velocity u + iv, the conjugate of dF/dζ
        func vel(_ s: Z) -> Z {
            let d = s - z0
            return (eaBar - Z(R * R, 0) * ea / (d * d) + Z(0, gamma / (2 * Double.pi)) / d).conj
        }
        let scale = min(w * 0.3, 520) / 4, cx = w * 0.72, cy = h * 0.2
        // Joukowski, then the free stream turned level; screen y runs down, which inverts the wing
        func screen(_ s: Z) -> CGPoint {
            let z = (s + Z(1, 0) / s) * eaBar
            return CGPoint(x: cx + z.re * scale, y: cy + z.im * scale)
        }
        let ds = 0.03
        for (i, t) in stride(from: -3.3, through: 3.3, by: 0.3).enumerated() {
            var s = Z(-7, t) * ea
            var path = Path()
            path.move(to: screen(s))
            for _ in 0..<1200 {
                let v1 = vel(s), m1 = v1.abs
                if m1 < 0.03 { break }
                let v2 = vel(s + v1 * (ds / 2 / m1)), m2 = v2.abs
                if m2 < 0.03 { break }
                s = s + v2 * (ds / m2)
                if (s * eaBar).re > 9 { break }
                path.addLine(to: screen(s))
            }
            ctx.stroke(path, with: .color(c(bone, i % 4 == 0 ? 0.16 : 0.09)), lineWidth: 0.75)
        }
        var body = Path()
        for k in 0...120 {
            let th = Double(k) / 120 * 2 * Double.pi
            let p = screen(z0 + Z(R * cos(th), R * sin(th)))
            k == 0 ? body.move(to: p) : body.addLine(to: p)
        }
        ctx.stroke(body, with: .color(c(sage, 0.3)), lineWidth: 1)
        fade(&ctx, size, from: CGPoint(x: 0, y: 0), to: CGPoint(x: w * 0.5, y: 0))
        fade(&ctx, size, from: CGPoint(x: 0, y: h * 0.72), to: CGPoint(x: 0, y: h * 0.42))
    }

    // MARK: Lap Sim

    /// Contour lines of a circuit with the racing line through them, bottom
    /// right, and a skidpad's figure of eight in the right gutter.
    static func track(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        let cx = w * 0.88, cy = h * 0.9, R = min(w, h) * 0.46
        func circuit(_ k: Double) -> Path {
            var p = Path()
            for i in 0...240 {
                let th = Double(i) / 240 * 2 * Double.pi
                let r = R * k * (1 + 0.16 * sin(2 * th + 0.6) + 0.08 * cos(3 * th - 0.4))
                let pt = CGPoint(x: cx + r * cos(th), y: cy + r * sin(th) * 0.7)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            return p
        }
        for k in 0..<7 {
            ctx.stroke(circuit(1 - Double(k) * 0.08), with: .color(c(bone, 0.1 - Double(k) * 0.01)), lineWidth: 0.75)
        }
        ctx.stroke(circuit(0.76), with: .color(c(sage, 0.26)), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
        // the skidpad: 15.25 m inner and 21.25 m outer diameter, centres 18.25 m apart
        let ri = min(w, h) * 0.05, ro = ri * 21.25 / 15.25, half = ri * 18.25 / 15.25
        let sx = w * 0.92, sy = h * 0.4
        for dx in [-half, half] {
            for r in [ri, ro] {
                ctx.stroke(Path(ellipseIn: CGRect(x: sx + dx - r, y: sy - r, width: 2 * r, height: 2 * r)),
                           with: .color(c(bone, 0.09)), lineWidth: 0.75)
            }
        }
        fade(&ctx, size, from: CGPoint(x: w * 0.3, y: 0), to: CGPoint(x: w * 0.6, y: 0))
    }

    // MARK: CAD

    /// A turntable floor: a perspective grid in the bottom third, fading out toward the horizon.
    static func floor(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        let horizon = h * 0.62, vp = CGPoint(x: w * 0.5, y: horizon)
        var grid = Path()
        for i in -16...16 {
            grid.move(to: vp)
            grid.addLine(to: CGPoint(x: w * 0.5 + Double(i) * w * 0.1, y: h))
        }
        for j in 0..<16 {
            let y = horizon + (h - horizon) / (1 + Double(j) * 0.4)
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: w, y: y))
        }
        ctx.stroke(grid, with: .color(c(bone, 0.1)), lineWidth: 0.75)
        fade(&ctx, size, from: CGPoint(x: 0, y: horizon), to: CGPoint(x: 0, y: horizon + (h - horizon) * 0.6))
    }

    // MARK: Flow Field

    /// A von Kármán vortex street shed from a cylinder, trailing off to the right.
    static func vortex(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        let rc = min(w, h) * 0.03, x0 = w * 0.55, cy = h * 0.2
        let l = rc * 4.3, sep = l * 0.36
        ctx.stroke(Path(ellipseIn: CGRect(x: x0 - rc, y: cy - rc, width: 2 * rc, height: 2 * rc)),
                   with: .color(c(sage, 0.3)), lineWidth: 1)
        for k in 1...12 {
            let row = k % 2 == 0 ? 1.0 : -1.0
            let vx = x0 + rc + Double(k) * l / 2, vy = cy + row * sep / 2
            let rv = rc * 0.8 * (1 + Double(k) * 0.08)
            var spiral = Path()
            for i in 0...90 {
                let th = Double(i) / 90 * 3 * 2 * Double.pi
                let r = rv * th / (6 * Double.pi)
                let p = CGPoint(x: vx + r * cos(row * th), y: vy + r * sin(row * th))
                i == 0 ? spiral.move(to: p) : spiral.addLine(to: p)
            }
            ctx.stroke(spiral, with: .color(c(sage, 0.22 * (1 - Double(k) / 14))), lineWidth: 0.75)
        }
        // the wake's edges, waving with the street
        for (i, off) in [-2.2, -1.2, 1.2, 2.2].enumerated() {
            var line = Path()
            let side = off < 0 ? -1.0 : 1.0
            for x in stride(from: w * 0.2, through: w, by: 4) {
                let behind = max(0, (x - x0) / (w - x0))
                let around = x < x0 - rc * 3 ? 0 : rc * 1.2 * exp(-pow((x - x0) / (rc * 3), 2)) * side
                let y = cy + off * sep + around + sin((x - x0) / l * 2 * Double.pi + Double(i)) * sep * 0.4 * behind
                x == w * 0.2 ? line.move(to: CGPoint(x: x, y: y)) : line.addLine(to: CGPoint(x: x, y: y))
            }
            ctx.stroke(line, with: .color(c(bone, 0.1)), lineWidth: 0.75)
        }
        fade(&ctx, size, from: CGPoint(x: w * 0.25, y: 0), to: CGPoint(x: w * 0.5, y: 0))
        fade(&ctx, size, from: CGPoint(x: 0, y: h * 0.6), to: CGPoint(x: 0, y: h * 0.4))
    }

    // MARK: Prism Layer

    /// Prism layers growing off the bottom edge, each 1.2 times the one under it.
    static func prism(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        var wall = Path()
        wall.move(to: CGPoint(x: 0, y: h - 0.5)); wall.addLine(to: CGPoint(x: w, y: h - 0.5))
        ctx.stroke(wall, with: .color(c(sage, 0.3)), lineWidth: 1)
        var y = h, gap = 3.0, k = 0
        while h - y < h * 0.3 {
            y -= gap; gap *= 1.2; k += 1
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: w, y: y))
            ctx.stroke(line, with: .color(c(sage, max(0.03, 0.2 - Double(k) * 0.013))), lineWidth: 0.75)
        }
    }
}
