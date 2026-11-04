import AeroBenchKit
import SwiftUI

/// The Design card (mockup A): every setting a chip, one Design button, and
/// the finalists RANS checked, of which you pick the final design.
struct DesignCard: View {
    @Environment(AppState.self) private var app
    @State private var more = false

    var body: some View {
        @Bindable var lab = app.wingLab
        let d = lab.design
        let running = lab.designRun.map { !$0.status.isFinished } ?? false
        let hasBase = app.car.setup != nil && app.car.base != nil
        Section {
            HStack(spacing: S37.Space.s2) {
                chip(lab.wing.rulesFor == .front ? "Front wing" : "Rear wing") {
                    Button("Front wing") { lab.edit { $0.switchRules(to: .front) } }
                    Button("Rear wing") { lab.edit { $0.switchRules(to: .rear) } }
                }
                chip(d.startFrom == .scratch ? "From scratch" : "From this wing") {
                    Button("From scratch") { lab.design.startFrom = .scratch }
                    Button("From this wing") { lab.design.startFrom = .existing }.disabled(lab.wing.elements.isEmpty)
                }
                chip("\(d.startFrom == .existing ? lab.wing.elements.count : d.elements) elements") {
                    ForEach(2...5, id: \.self) { n in Button("\(n) elements") { lab.design.elements = n } }
                }
                .disabled(d.startFrom == .existing)
                .help(d.startFrom == .existing ? "From this wing: its own elements" : "How many elements to lay out")
            }
            HStack(spacing: S37.Space.s2) {
                chip(d.goal.title) {
                    ForEach(WingLabModel.DesignGoal.allCases) { g in
                        Button(g.title) { lab.design.goal = g }.disabled(g == .balance && !hasBase)
                    }
                }
                .help(d.goal == .balance || hasBase ? "What the design is for" : "Hit a balance needs the base car (inspector's Car section)")
                chip("RANS on best \(d.checks)") {
                    ForEach([1, 3, 5], id: \.self) { n in Button("RANS on best \(n)") { lab.design.checks = n } }
                }
                Button { more.toggle() } label: { Label("More", systemImage: "slider.horizontal.3") }
                    .popover(isPresented: $more) { moreSettings.padding(S37.Space.s4).frame(width: 300) }
            }
            if d.goal == .maxClaCdaCap {
                NumberField(label: hasBase ? "Car CdA at most" : "Wing CdA at most", unit: "m²",
                            value: Binding(get: { lab.design.cdaCap }, set: { lab.design.cdaCap = max($0, 0.01) }))
            }
            if d.goal == .balance {
                NumberField(label: "Rear share", unit: "%", value: Binding(get: { lab.design.rearTarget },
                                                                         set: { lab.design.rearTarget = min(max($0, 0), 100) }))
            }
            HStack {
                Button("Design") { app.runDesign() }
                    .buttonStyle(S37ButtonStyle(kind: .prominent))
                    .disabled(running)
                Text(timeText).font(.caption).foregroundStyle(S37.C.inkSecondary)
            }
            if let job = lab.designRun, !job.status.isFinished || job.status == .failed { JobInlineStatus(job: job) }
            if app.settings.su2Executable == nil {
                Text("No SU2: finalists are the estimate's, unchecked.").font(.caption).foregroundStyle(S37.C.clayInk)
            }
            if let r = lab.designResult { finalists(r) }
        } header: {
            Text("Design")
        } footer: {
            Text(app.designFrame.onCar
                 ? "Fills the car's rules box for this end, anywhere in it. The estimate shortlists; RANS picks: a finalist counts only if it converges and stays attached."
                 : "Fills Wing Lab's rules box. The estimate shortlists; RANS picks: a finalist counts only if it converges and stays attached.")
        }
    }

    private var timeText: String {
        let lab = app.wingLab
        let checks = app.settings.su2Executable == nil ? 0 : lab.design.checks
        let minutes = Double(lab.optimise.trials) * 0.4 / 60 + Double(checks + (checks > 0 ? 1 : 0)) * 2.5
        return String(format: "about %.0f min", max(minutes.rounded(), 1)) + (checks > 0 ? ", then RANS" : "")
    }

    @ViewBuilder private func finalists(_ r: WingDesignResult) -> some View {
        let lab = app.wingLab
        let car = r.finalists.contains { $0.carCla != nil }
        if !r.finalists.contains(where: \.held), r.finalists.contains(where: { $0.rans != nil }) {
            HStack {
                Text("None held in RANS: each separated or did not converge.").font(.caption).foregroundStyle(S37.C.clayInk)
                Spacer()
                Button("Check 3 More") {
                    lab.design.checks += 3
                    app.runDesign()
                }
            }
        }
        ForEach(r.finalists) { f in
            let shown = lab.designShown == f.number
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Trial \(f.number)").font(.system(size: 13, weight: .semibold))
                    Text(verdict(f)).font(.caption).foregroundStyle(f.held ? S37.C.sageInk : S37.C.inkSecondary)
                    Spacer()
                    if shown {
                        Button("Use This Wing") { app.useFinalist(f) }
                            .help("On the canvas, saved as a new card and put on the car")
                    }
                }
                Text(numbers(f, car: car)).font(.caption).monospacedDigit()
            }
            .padding(S37.Space.s2)
            .background(RoundedRectangle(cornerRadius: S37.Radius.sm, style: .continuous).fill(shown ? S37.C.sageWash : S37.C.inset))
            .contentShape(Rectangle())
            .onTapGesture { app.showFinalist(f) }
        }
    }

    private func verdict(_ f: WingDesignResult.Finalist) -> String {
        guard let v = f.rans else { return "estimate only" }
        if f.held { return "held in RANS" }
        if v.separated == true { return "separated" }
        return v.converged == false ? "did not converge" : "did not hold"
    }

    private func numbers(_ f: WingDesignResult.Finalist, car: Bool) -> String {
        func n(_ v: Double?, _ fmt: String) -> String { v.map { String(format: fmt, $0) } ?? "–" }
        var s = "ClA " + n(f.cla, "%.3f") + "   CdA " + n(f.cda, "%.3f") + "   ClA/CdA " + n(f.claCda, "%.1f")
        if car { s += "   car " + n(f.carCla, "%.2f") + " / " + n(f.carCda, "%.2f") }
        if let r = f.rearShare { s += String(format: "   rear %.0f %%", r * 100) }
        return s + " (\(f.from))"
    }

    private func chip<Content: View>(_ title: String, @ViewBuilder _ items: () -> Content) -> some View {
        Menu(title, content: items).fixedSize()
    }

    @ViewBuilder private var moreSettings: some View {
        @Bindable var lab = app.wingLab
        VStack(alignment: .leading, spacing: S37.Space.s3) {
            Text("More").font(.system(size: 16, weight: .semibold))
            Stepper("Trials: \(lab.optimise.trials)", value: $lab.optimise.trials, in: 20...5000, step: 50)
            Picker("Sampler", selection: $lab.optimise.sampler) {
                Text("TPE").tag("tpe")
                Text("CMA-ES").tag("cmaes")
            }
            NumberField(label: "Thinnest section", unit: "%", value: Binding(get: { lab.design.minThickness },
                                                                              set: { lab.design.minThickness = min(max($0, 2), 30) }))
            Text("RANS uses the mesh and model under Solvers; the speed and ride height are the wing's own. The Optimise section below holds the same study settings.")
                .font(.caption).foregroundStyle(S37.C.inkSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
