import AeroBenchKit
import Charts
import SwiftUI

/// One A4 page for a design review: the wing, the conditions, every
/// solver's answer, Cp, the estimate polar and the flow field. Drawn with
/// plain values (no environment) so ImageRenderer can make a PDF of it.
struct WingReportView: View {
    let title: String
    let wing: Wing
    let preview: PanelSolution?
    let estimate: WingEstimate?
    let rans: WingRansResult?
    let field: WingField?
    let fieldScalar: WingField.Scalar?
    let fieldImage: CGImage?

    static let size = CGSize(width: 595, height: 842)  // A4 in points

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            geometry
            HStack(alignment: .top, spacing: 16) {
                elementTable
                conditions
            }
            results
            HStack(alignment: .top, spacing: 12) {
                cpChart.frame(width: 265, height: 170)
                polarChart.frame(width: 265, height: 170)
            }
            if let field, let fieldImage, let fieldScalar {
                fieldView(field, fieldImage, fieldScalar)
            }
            Spacer(minLength: 0)
            Text("AeroBench, 2D section. A quick check before a full CFD run, not a replacement for it: the quick estimate is within about 2% of RANS on lift and 10% high on drag for a main-and-flap wing; RANS matched wind-tunnel lift within 2% on NACA 0012.")
                .font(.system(size: 7)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(Color.black)
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 18, weight: .semibold))
            Spacer()
            Text(Date.now.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    // MARK: Geometry

    private var geometry: some View {
        Canvas { ctx, size in
            let pts = wing.elements.flatMap { $0.placed() }
            guard let x0 = pts.map(\.x).min(), let x1 = pts.map(\.x).max(),
                  let y0 = pts.map(\.y).min(), let y1 = pts.map(\.y).max() else { return }
            let scale = min(size.width / max(x1 - x0, 1e-6), size.height / max(y1 - y0, 1e-6)) * 0.95
            let ox = (size.width - (x1 - x0) * scale) / 2, oy = (size.height - (y1 - y0) * scale) / 2
            func view(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x: ox + (p.x - x0) * scale, y: oy + (y1 - p.y) * scale) }
            for e in wing.elements {
                var path = Path()
                for (k, p) in e.placed().enumerated() {
                    if k == 0 { path.move(to: view(p)) } else { path.addLine(to: view(p)) }
                }
                path.closeSubpath()
                ctx.fill(path, with: .color(Color(white: 0.8)))
                ctx.stroke(path, with: .color(.black), lineWidth: 0.8)
            }
        }
        .frame(height: 120)
    }

    private var elementTable: some View {
        Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 2) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                Text("Section").gridColumnAlignment(.leading)
                Text("Chord")
                Text("Angle")
                Text("Gap")
                Text("Overlap")
            }
            .bold()
            ForEach(wing.elements.indices, id: \.self) { i in
                let e = wing.elements[i]
                GridRow {
                    Text(WingIssue.label(i))
                    Text(e.airfoil.name).lineLimit(1)
                    Text(String(format: "%.0f mm", e.chord * 1000))
                    Text(String(format: "%.1f°", e.angle))
                    Text(wing.gap(of: i).map { String(format: "%.1f mm", $0 * 1000) } ?? "")
                    Text(wing.overlap(of: i).map { String(format: "%.1f mm", $0 * 1000) } ?? "")
                }
            }
        }
        .font(.system(size: 8).monospacedDigit())
    }

    private var conditions: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Conditions").bold()
            Text(String(format: "%.1f m/s, Re %.2g on the reference chord", wing.speed, wing.reynolds(chord: wing.refChord)))
            Text(String(format: "Wing angle %.1f°, reference chord %.0f mm", wing.alpha, wing.refChord * 1000))
            Text(String(format: "Span %.0f mm, 3D factor %.2f", wing.span * 1000, wing.factor3D))
            Text(wing.elements.first?.inverted ?? true ? "Inverted (downforce)" : "Upright (lift)")
        }
        .font(.system(size: 8).monospacedDigit())
    }

    // MARK: Results

    private var results: some View {
        let est = estimate?.row(nearest: wing.alpha)
        let n = wing.elements.count
        return Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 2) {
            GridRow {
                Text("Solver").gridColumnAlignment(.leading)
                Text("Cl")
                Text("Cd")
                Text("L/D")
                ForEach(0..<n, id: \.self) { i in Text("\(WingIssue.label(i)) Cl") }
                Text("ClA / CdA on the car")
                Text("Notes").gridColumnAlignment(.leading)
            }
            .bold()
            if let p = preview {
                GridRow {
                    Text("Inviscid preview")
                    Text(String(format: "%.3f", p.clTotal))
                    Text("–")
                    Text("–")
                    ForEach(0..<n, id: \.self) { i in Text(i < p.cl.count ? String(format: "%.3f", p.cl[i]) : "") }
                    Text("")
                    Text("no drag, lift runs high")
                }
            }
            if let e = est {
                GridRow {
                    Text("Quick estimate")
                    Text(String(format: "%.3f", e.cl))
                    Text(String(format: "%.4f", e.cd))
                    Text(String(format: "%.1f", abs(e.cl) / max(e.cd, 1e-9)))
                    ForEach(0..<n, id: \.self) { i in Text(i < e.elements.count ? String(format: "%.3f", e.elements[i].cl) : "") }
                    Text(car(e.cl, e.cd))
                    Text(e.separating == true ? "last element separating" : (e.trusted ? "" : "NeuralFoil unsure"))
                }
            }
            if let r = rans {
                GridRow {
                    Text("RANS (\(r.meshLevel))")
                    Text(String(format: "%.3f", r.cl))
                    Text(String(format: "%.4f", r.cd))
                    Text(String(format: "%.1f", r.liftToDrag))
                    ForEach(0..<n, id: \.self) { i in Text(i < r.elements.count ? r.elements[i].cl.map { String(format: "%.3f", $0) } ?? "" : "") }
                    Text(r.converged ? car(r.cl, r.cd) : "")
                    Text(r.converged
                         ? String(format: "%@, %ld iterations, residual down %.1f orders", r.modelName, r.iterations, r.residualDrop)
                         : "NOT CONVERGED: \(r.reason ?? "did not settle")")
                        .foregroundStyle(r.converged ? Color.black : Color.red)
                }
            }
        }
        .font(.system(size: 8).monospacedDigit())
    }

    private func car(_ cl: Double, _ cd: Double) -> String {
        let c = wing.carContribution(cl: cl, cd: cd)
        return String(format: "%.3f / %.3f m²", c.cla, c.cda)
    }

    private struct CpPoint: Identifiable {
        let id: Int
        let series: String
        let x: Double
        let minusCp: Double
    }

    /// RANS surface Cp when there is a run, else the inviscid preview.
    private var cpChart: some View {
        var points: [CpPoint] = []
        var source = "inviscid"
        if let r = rans, !r.surface.isEmpty {
            source = "RANS"
            for (i, s) in r.surface.enumerated() {
                for k in s.x.indices where k < s.cp.count {
                    points.append(CpPoint(id: points.count, series: "\(i)", x: s.x[k] * 1000, minusCp: -s.cp[k]))
                }
            }
        } else if let p = preview, p.cp.count == wing.elements.count {
            for (i, e) in wing.elements.enumerated() {
                let pts = e.placed()
                let half = (pts.count - 1) / 2
                for k in pts.indices where k < p.cp[i].count {
                    points.append(CpPoint(id: points.count, series: "\(i)\(k <= half ? "u" : "l")", x: pts[k].x * 1000, minusCp: -p.cp[i][k]))
                }
            }
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text("Surface pressure, \(source) (−Cp up)").font(.system(size: 8)).foregroundStyle(.secondary)
            Chart(points) { p in
                LineMark(x: .value("x (mm)", p.x), y: .value("−Cp", p.minusCp), series: .value("s", p.series))
                    .lineStyle(StrokeStyle(lineWidth: 0.8))
                    .foregroundStyle(.blue)
            }
            .chartXAxisLabel("x (mm)")
            .font(.system(size: 7))
        }
    }

    private var polarChart: some View {
        let rows = estimate?.rows ?? []
        return VStack(alignment: .leading, spacing: 2) {
            Text(rows.isEmpty ? "Lift against wing angle: run the quick estimate" : "Quick estimate: Cl against wing angle")
                .font(.system(size: 8)).foregroundStyle(.secondary)
            Chart {
                ForEach(rows) { r in
                    LineMark(x: .value("α", r.alpha), y: .value("Cl", r.cl))
                    PointMark(x: .value("α", r.alpha), y: .value("Cl", r.cl))
                        .symbolSize(10)
                        .foregroundStyle(r.separating == true ? Color.orange : Color.blue)
                }
                if let r = rans {
                    PointMark(x: .value("α", r.alpha ?? wing.alpha), y: .value("Cl", r.cl))
                        .symbol(.square).symbolSize(30)
                        .foregroundStyle(r.converged ? Color.green : Color.red)
                }
            }
            .chartXAxisLabel("Wing angle (°)")
            .chartYScale(domain: .automatic(includesZero: false))
            .font(.system(size: 7))
            if rans != nil {
                Text("Square: the RANS run").font(.system(size: 7)).foregroundStyle(.secondary)
            }
        }
    }

    private func fieldView(_ f: WingField, _ image: CGImage, _ scalar: WingField.Scalar) -> some View {
        let w = f.window.x1 - f.window.x0, h = f.window.y1 - f.window.y0
        let width = 547.0, height = min(width * h / max(w, 1e-9), 200)
        let scale = min(width / w, height / h)
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(scalar.name), RANS, with streamlines").font(.system(size: 8)).foregroundStyle(.secondary)
            Canvas { ctx, size in
                let rect = CGRect(x: (size.width - w * scale) / 2, y: 0, width: w * scale, height: h * scale)
                func view(_ p: SIMD2<Double>) -> CGPoint {
                    CGPoint(x: rect.minX + (p.x - f.window.x0) * scale, y: rect.minY + (f.window.y1 - p.y) * scale)
                }
                ctx.draw(Image(decorative: image, scale: 1), in: rect)
                // The elements as SU2 saw them, as in the CFD tab.
                for s in rans?.surface ?? [] where s.x.count > 2 {
                    var path = Path()
                    for k in s.x.indices where k < s.y.count {
                        let p = view(SIMD2(s.x[k], s.y[k]))
                        if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    path.closeSubpath()
                    ctx.fill(path, with: .color(Color(white: 0.55)))
                }
                var lines = Path()
                for line in f.streamlines where line.count > 1 {
                    lines.move(to: view(line[0]))
                    for p in line.dropFirst() { lines.addLine(to: view(p)) }
                }
                ctx.stroke(lines, with: .color(.black.opacity(0.45)), lineWidth: 0.5)
            }
            .frame(width: width, height: height)
            if scalar.range.count == 2 {
                Text(String(format: "Colour range %.2f to %.2f", scalar.range[0], scalar.range[1]))
                    .font(.system(size: 7)).foregroundStyle(.secondary)
            }
        }
    }
}
