import SwiftUI

/// Which RANS model to pick and why SST is the default, with the numbers from the
/// UIUC Vol 1 check (docs/validation/UIUC-Vol1-vs-AeroBench.xlsx) and NASA's NACA 0012 case.
struct ModelHelpView: View {
    private struct Model: Identifiable {
        let model: WingLabModel.TurbulenceModel
        let use: String
        let numbers: String
        var id: String { model.rawValue }
    }

    private let models = [
        Model(model: .sst,
              use: "Designing and comparing wings. It gives an answer at every angle, so every design is judged by the same physics.",
              numbers: "Converged at every angle checked, about 2.5 times faster than with transition. Lift slope within 5% of the UIUC tunnel; drag 3–25% high at Re 200,000, most on sections that keep a long laminar run. Passed NASA's NACA 0012 check at Re 6 million."),
        Model(model: .sstLM,
              use: "The best drag figure for one wing, once you have picked it. Check that the run says converged.",
              numbers: "Drag within 0–9% of the UIUC tunnel where it converged. It did not settle at 16 of 41 angles: low angles on thin cambered sections, and near stall on every section."),
        Model(model: .sa,
              use: "Attached flow and modest flap angles, when you want the lightest run.",
              numbers: "Fully turbulent like SST but less trusted near stall. Not checked against the tunnel."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: S37.Space.s4) {
            Text("Choosing a RANS model").font(.headline)
            Text("SST is the default because it gives a trustworthy answer every time. SST with transition is closer when it works, but often doesn't.")
                .foregroundStyle(S37.C.inkSecondary)
            ForEach(models) { m in
                VStack(alignment: .leading, spacing: S37.Space.s1) {
                    Text("\(m.model.title) · \(m.model.accuracy)").font(.body.weight(.semibold))
                    Text(m.use)
                    Text(m.numbers).font(.caption).foregroundStyle(S37.C.inkSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("Why transition isn't the default: a Design run checks 3 to 5 finalists with RANS, and a run that won't settle is thrown out, so you would lose designs to the solver rather than the aerodynamics. On a car the air is turbulent and the flow trips early, so the laminar runs it predicts may not happen on track.")
                .font(.caption).foregroundStyle(S37.C.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(S37.Space.s5)
        .frame(width: 420, alignment: .leading)
    }
}
