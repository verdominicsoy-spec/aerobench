import AeroBenchKit
import AppKit
import SwiftUI

/// Prism layer sizes for a target y+, to type into STAR's mesher.
struct PrismLayerView: View {
    @AppStorage("prism.velocity") private var velocity = 15.0
    @AppStorage("prism.density") private var density = 1.225
    @AppStorage("prism.yPlus") private var yPlus = 1.0
    @AppStorage("prism.viscosity") private var viscosity = 1.81e-5
    @AppStorage("prism.chord") private var chord = 0.3
    @AppStorage("prism.slotGap") private var slotGap = 0.0  // 0: a single element, no slot
    @AppStorage("prism.stretching") private var stretching = 1.2

    var body: some View {
        let layer = PrismLayer(velocity: velocity, density: density, yPlus: yPlus,
                               viscosity: viscosity, chord: chord,
                               slotGap: slotGap > 0 ? slotGap / 1000 : nil, stretching: stretching)
        Form {
            Section {
                field("Velocity", "m/s", $velocity)
                field("Density", "kg/m³", $density)
                field("Target y+", "", $yPlus)
            } header: {
                Text("Flow")
            } footer: {
                Text("y+ sets only the first cell. The total thickness comes from the chord and the Reynolds number.")
            }
            Section {
                field("Chord", "m", $chord)
                field("Slot gap", "mm", $slotGap)
            } header: {
                Text("Element")
            } footer: {
                Text("The element you are meshing: the boundary layer grows along the chord. The slot gap is the narrowest gap to the next element; 0 for a single element.")
            }
            Section {
                field("Dynamic viscosity", "Pa·s", $viscosity)
                field("Stretching", "", $stretching)
            } header: {
                Text("Also needed")
            } footer: {
                Text("Air at 15 °C is 1.81e-5 Pa·s. Stretching sets only the number of layers.")
            }
            Section {
                if let layer {
                    result("Minimum Thickness Percentage", percent(layer.minimumThicknessPercentage), "%")
                    result("Gap Fill Percentage", percent(layer.gapFillPercentage), "%")
                    result("Prism Layer Reduction Percentage", percent(layer.reductionPercentage), "%")
                    result("Number of Prism Layers", "\(layer.layers)")
                    result("Prism Layer Near Wall Thickness", millimetres(layer.firstCell), "mm")
                    result("Prism Layer Total Thickness (absolute)", millimetres(layer.total), "mm")
                    if layer.layers < 10 {
                        Text("Under 10 layers leaves the boundary layer under-resolved: lower the stretching.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if layer.slotShare < 1 {
                        Text("The slot holds \(percent(layer.gapFillPercentage)) % a side, so the layer thins there to \((100 * layer.slotShare).formatted(.number.precision(.fractionLength(0)))) % of the total. The reduction and minimum thickness percentages sit below that, so every layer is kept.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    result("Wall distance y", millimetres(layer.wallDistance), "mm")
                    result("Reynolds number", layer.reynolds.formatted(.number.notation(.scientific).precision(.significantDigits(3))))
                } else {
                    Text("Every value must be above zero, and stretching above 1.").foregroundStyle(.secondary)
                }
            } header: {
                Text("STAR prism layer mesher")
            } footer: {
                Text("Flat-plate estimates: Cf = 0.026 Re^-1/7 for the wall distance, 0.37 c Re^-0.2 for the total, at the trailing edge, where it is thickest. Gap fill is the prism share of the slot on each side, at least STAR's 25 and at most 40, as in the engine's meshes. STAR is cell-centred, so the first cell is twice the wall distance y; SU2 meshes take y itself.")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 560)
    }

    private func field(_ label: String, _ unit: String, _ value: Binding<Double>) -> some View {
        LabeledContent(label) {
            HStack {
                TextField(label, value: value, format: .number).labelsHidden().multilineTextAlignment(.trailing).frame(width: 110)
                Text(unit).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            }
        }
    }

    /// The value with its unit and a button that copies the bare number, to paste into STAR.
    private func result(_ label: String, _ value: String, _ unit: String = "") -> some View {
        LabeledContent(label) {
            HStack {
                Text(value).monospacedDigit().textSelection(.enabled)
                Text(unit).foregroundStyle(.secondary).frame(width: 26, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy \(value)")
            }
        }
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private func millimetres(_ metres: Double) -> String {
        String(format: "%.4g", metres * 1000)  // plain digits, no grouping, so it pastes as a number
    }
}
