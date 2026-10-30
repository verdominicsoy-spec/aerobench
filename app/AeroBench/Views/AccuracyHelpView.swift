import SwiftUI

/// What each solver is good for and how far to trust it, with the numbers
/// from the validation runs (docs/DECISIONS.md has the details).
struct AccuracyHelpView: View {
    private struct Solver: Identifiable {
        let name: String
        let speed: String
        let goodFor: String
        let trust: String
        let misses: String
        var id: String { name }
    }

    private let solvers = [
        Solver(name: "Inviscid preview", speed: "under 50 ms, live while dragging",
               goodFor: "How the load splits between elements and which way lift moves when you change an angle or a gap.",
               trust: "Lift trends only. Absolute lift runs high because there is no boundary layer.",
               misses: "Drag, stall, anything the slot does to the boundary layers."),
        Solver(name: "Quick viscous (NeuralFoil)", speed: "seconds",
               goodFor: "Choosing a section: its polar, drag and where the flow turns turbulent.",
               trust: "Close to XFOIL-class results for one section on its own at sensible Reynolds numbers. Rows it is unsure of are marked.",
               misses: "The other elements. Each section is run alone."),
        Solver(name: "Quick estimate", speed: "about a second per sweep; the optimiser runs a few hundred in a minute",
               goodFor: "Every element together: Cl and Cd against wing angle, element angles in the optimiser, and spotting a flap about to separate.",
               trust: "On the main-and-flap wing, lift within about 2% of RANS and drag about 10% high until the flap nears separation. Flags the flap within 2° of its stall angle.",
               misses: "Gap size barely changes its answer, so gaps and overlaps need RANS. Not checked on slats. Past separation its numbers mean nothing."),
        Solver(name: "RANS CFD (SU2)", speed: "about 1½ min on the Quick mesh, several on Medium",
               goodFor: "The real slot flow, separation and gap effects. The last check here before STAR-CCM+.",
               trust: "NACA 0012 at Re 6 million: lift within 2% of Ladson's wind tunnel data, drag 5–15% high up to 10°. 30P30N three-element wing: within 3% up to 16°. Quick mesh within 0.3% of Medium.",
               misses: "2D only: no tip vortices, no endplates, no car underneath. Runs that do not settle are shown as not converged, never as results."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("How far to trust each solver")
                    .font(.title2.bold())
                Text("AeroBench is a quick sanity check before you spend hours in STAR-CCM+. Use the fast solvers to narrow things down and RANS to check the few designs worth a proper run.")
                    .foregroundStyle(.secondary)
                ForEach(solvers) { s in
                    GroupBox {
                        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                            row("Speed", s.speed)
                            row("Good for", s.goodFor)
                            row("Trust", s.trust)
                            row("Misses", s.misses)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text(s.name).font(.headline)
                    }
                }
                Text("Everything here is 2D. A 3D wing makes less lift than its section, so expect STAR-CCM+ on the full car to come in lower.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private func row(_ label: String, _ text: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
