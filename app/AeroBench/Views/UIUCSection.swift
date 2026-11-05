import AeroBenchKit
import Charts
import SwiftUI

/// The accuracy window's comparison against the University of Illinois tunnel: ten sections on
/// the tunnel models' measured shapes, the latest run's errors, each section's polars with the
/// tunnel, the estimate and RANS overlaid, and the history of runs.
struct UIUCSection: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: S37.Space.s3) {
            Text("Against the UIUC wind tunnel").font(.headline)
            Text("Ten sections from the University of Illinois low-speed tests (Selig et al., volumes 1 to 3), each on the tunnel model's measured shape at Re about 300,000, so the geometry is the same and only the physics differs. Errors are over the attached range; RANS angles that did not converge are hollow and left out.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let r = app.uiuc {
                if let run = r.runs.first { results(r, run) } else { Text("Not run yet.") }
            } else if let note = app.uiucNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            recompute
        }
        .task { await app.loadUIUC() }
    }

    @ViewBuilder private func results(_ r: UIUCResults, _ run: UIUCResults.Run) -> some View {
        if r.isStale(run) {
            Text("Run with \(describe(run.settings)); Wing Lab now uses \(describe(r.current)). Recompute to compare like with like.")
                .font(.caption).foregroundStyle(S37.C.clayInk).fixedSize(horizontal: false, vertical: true)
        }
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: S37.Space.s4, verticalSpacing: S37.Space.s1) {
                GridRow {
                    Text("")
                    Text("Lift error").foregroundStyle(.secondary)
                    Text("Drag error").foregroundStyle(.secondary)
                }
                GridRow { Text("Estimate"); pct(run.summary.estimate.lift); pct(run.summary.estimate.drag) }
                GridRow { Text("RANS"); pct(run.summary.rans.lift); pct(run.summary.rans.drag) }
            }
            .font(.body.monospacedDigit())
            Text("RANS converged at \(percent(run.summary.converged)) of its angles. Run \(run.date.prefix(10)), \(describe(run.settings)), \(Int(run.seconds / 60)) min on \(run.cores) cores.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        if let why = r.tunnelError {
            Text("Tunnel points not shown: \(why).").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(run.cases) { c in
            DisclosureGroup {
                UIUCCharts(tunnel: r.tunnel[c.key]?.rows ?? [], estimate: c.estimate, rans: c.rans)
            } label: {
                HStack {
                    Text(c.name)
                    Spacer()
                    Text(caseLine(c)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        if r.runs.count > 1 { history(r.runs) }
    }

    private func history(_ runs: [UIUCResults.Run]) -> some View {
        VStack(alignment: .leading, spacing: S37.Space.s1) {
            Text("History").font(.body.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: S37.Space.s3, verticalSpacing: S37.Space.s1) {
                GridRow {
                    ForEach(["Date", "Settings", "Est. lift", "Est. drag", "RANS lift", "RANS drag", "Converged"], id: \.self) {
                        Text($0).foregroundStyle(.secondary)
                    }
                }
                ForEach(runs) { run in
                    GridRow {
                        Text(run.date.prefix(10))
                        Text(describe(run.settings))
                        pct(run.summary.estimate.lift); pct(run.summary.estimate.drag)
                        pct(run.summary.rans.lift); pct(run.summary.rans.drag)
                        Text(percent(run.summary.converged))
                    }
                }
            }
            .font(.caption.monospacedDigit())
        }
    }

    @ViewBuilder private var recompute: some View {
        let haveSU2 = app.settings.su2Executable != nil
        let running = app.uiucJob.map { !$0.status.isFinished } ?? false
        HStack(spacing: S37.Space.s3) {
            Button("Recompute") { app.recomputeUIUC() }
                .buttonStyle(S37ButtonStyle(kind: .prominent))
                .disabled(!haveSU2 || running)
            if haveSU2 {
                Text("About an hour on 12 cores. Wing Lab's own RANS runs share the cores meanwhile.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Needs SU2: install it under Solvers, RANS CFD.").font(.caption).foregroundStyle(S37.C.clayInk)
            }
        }
        if let job = app.uiucJob, !job.status.isFinished || job.status == .failed { JobInlineStatus(job: job) }
    }

    private func describe(_ s: UIUCResults.Settings) -> String {
        let model = WingLabModel.TurbulenceModel(rawValue: s.model)?.title ?? s.model
        return "\(model), \(s.mesh) mesh" + (s.commit.map { " (\($0))" } ?? "")
    }

    private func caseLine(_ c: UIUCResults.Case) -> String {
        let e = c.errors
        let rans = if let why = c.ransError { "RANS failed: \(why)" }
            else if !c.rans.contains(where: \.converged) { "RANS: no converged angles" }
            else if e.rans.lift == nil { "RANS: no converged angle in the attached range" }
            else { "RANS lift \(percent(e.rans.lift)), drag \(percent(e.rans.drag))" }
        return "estimate lift \(percent(e.estimate.lift)), drag \(percent(e.estimate.drag)) · \(rans)"
    }

    private func pct(_ x: Double?) -> Text { Text(percent(x)) }
    private func percent(_ x: Double?) -> String { x.map { String(format: "%.1f%%", $0 * 100) } ?? "–" }
}

/// Cl–α, Cd–α and Cl–Cd with the tunnel (points), the estimate (dashed) and RANS (line through
/// the converged angles, every angle marked, hollow where it did not converge) on each.
struct UIUCCharts: View {
    let tunnel: [UIUCResults.Point]
    let estimate: [UIUCResults.Point]
    let rans: [UIUCResults.Point]

    var body: some View {
        HStack(spacing: S37.Space.s3) {
            chart("α (°)", "Cl", \.alpha, \.cl)
            chart("α (°)", "Cd", \.alpha, \.cd)
            chart("Cd", "Cl", \.cd, \.cl)
        }
        .frame(height: 180)
    }

    private func chart(_ xName: String, _ yName: String, _ x: KeyPath<UIUCResults.Point, Double>,
                       _ y: KeyPath<UIUCResults.Point, Double>) -> some View {
        Chart {
            ForEach(Array(tunnel.enumerated()), id: \.offset) { _, p in
                PointMark(x: .value(xName, p[keyPath: x]), y: .value(yName, p[keyPath: y]))
                    .foregroundStyle(by: .value("Source", "Tunnel")).symbolSize(24)
            }
            ForEach(Array(estimate.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value(xName, p[keyPath: x]), y: .value(yName, p[keyPath: y]), series: .value("Source", "Estimate"))
                    .foregroundStyle(by: .value("Source", "Estimate"))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
            ForEach(Array(rans.filter(\.converged).enumerated()), id: \.offset) { _, p in
                LineMark(x: .value(xName, p[keyPath: x]), y: .value(yName, p[keyPath: y]), series: .value("Source", "RANS"))
                    .foregroundStyle(by: .value("Source", "RANS"))
            }
            ForEach(Array(rans.enumerated()), id: \.offset) { _, p in
                PointMark(x: .value(xName, p[keyPath: x]), y: .value(yName, p[keyPath: y]))
                    .foregroundStyle(by: .value("Source", "RANS"))
                    .symbol {
                        if p.converged {
                            Circle().fill(S37.C.chart1).frame(width: 6, height: 6)
                        } else {
                            Circle().strokeBorder(S37.C.chart1, lineWidth: 1.5).frame(width: 7, height: 7)
                        }
                    }
            }
        }
        .chartForegroundStyleScale(["Tunnel": S37.C.ink, "Estimate": S37.C.chart2, "RANS": S37.C.chart1])
        .chartXAxisLabel(xName)
        .chartYAxisLabel(yName)
        .chartXScale(domain: .automatic(includesZero: false))
        .chartYScale(domain: .automatic(includesZero: false))
    }
}
