import AeroBenchKit
import SwiftUI

/// The Car tool: the base car from its STEP, its 2D strip runs, and front
/// and rear wing cards placed on it, compared quickly (sums) or fully (the
/// strips again with the wings in them), then sent to Lap Sim.
struct CarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.undoManager) private var undo

    var body: some View {
        let car = app.car
        ScrollView {
            VStack(alignment: .leading, spacing: S37.Space.s6) {
                HStack(alignment: .top, spacing: S37.Space.s6) {
                    BaseCarPane().frame(maxWidth: 420)
                    VStack(alignment: .leading, spacing: S37.Space.s6) {
                        SideViewPane()
                        SectionPane()
                    }
                }
                HStack(alignment: .top, spacing: S37.Space.s6) {
                    CardsPane().frame(maxWidth: 420)
                    CombinationsPane()
                }
            }
            .padding(6)
        }
        .scrollIndicators(.never)
        .onAppear { app.loadCar(); app.refreshSections() }
        .preference(key: ToolTakeawayKey.self, value: takeaway(car))
    }

    private func takeaway(_ car: CarModel) -> String {
        guard car.setup != nil else { return "Choose the base car's STEP to start." }
        guard let b = car.base else { return "Run the bare car at the \(car.mesh) mesh to get its numbers." }
        let rear = b.rearShare.map { String(format: ", %.0f %% on the rear axle", $0 * 100) } ?? ""
        return String(format: "Bare car: ClA %.2f m², CdA %.2f m²", b.cla, b.cda) + rear + (b.converged ? "." : " (not converged).")
    }
}
