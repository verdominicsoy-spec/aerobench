import AeroBenchKit
import SwiftUI

/// Prism layer sizes for a target y+, to type into STAR's mesher.
struct PrismLayerView: View {
    @AppStorage("prism.velocity") private var velocity = 15.0
    @AppStorage("prism.density") private var density = 1.225
    @AppStorage("prism.yPlus") private var yPlus = 1.0
    @AppStorage("prism.viscosity") private var viscosity = 1.81e-5
    @AppStorage("prism.length") private var length = 1.0
    @AppStorage("prism.stretching") private var stretching = 1.2

    var body: some View {
        let layer = PrismLayer(velocity: velocity, density: density, yPlus: yPlus,
                               viscosity: viscosity, length: length, stretching: stretching)
        Form {
            Section {
                field("Velocity", "m/s", $velocity)
                field("Density", "kg/m³", $density)
                field("Target y+", "", $yPlus)
            } header: {
                Text("Flow")
            }
            Section {
                field("Dynamic viscosity", "Pa·s", $viscosity)
                field("Reference length", "m", $length)
                field("Stretching", "", $stretching)
            } header: {
                Text("Also needed")
            } footer: {
                Text("The reference length sets the Reynolds number and how thick the boundary layer grows: use the chord, or the car's length. Air at 15 °C is 1.81e-5 Pa·s.")
            }
            Section {
                if let layer {
                    result("Total thickness (absolute)", millimetres(layer.total))
                    result("First cell thickness", millimetres(layer.firstCell))
                    result("Number of layers", "\(layer.layers)")
                    result("Wall distance y", millimetres(layer.wallDistance))
                    result("Reynolds number", layer.reynolds.formatted(.number.notation(.scientific).precision(.significantDigits(3))))
                } else {
                    Text("Every value must be above zero, and stretching above 1.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Prism layer")
            } footer: {
                Text("Flat-plate estimates: Cf = 0.026 Re^-1/7 for the wall distance, 0.37 L Re^-0.2 for the total. STAR is cell-centred, so the first cell is twice the wall distance y; SU2 meshes take y itself.")
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

    private func result(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).monospacedDigit().textSelection(.enabled) }
    }

    private func millimetres(_ metres: Double) -> String {
        (metres * 1000).formatted(.number.precision(.significantDigits(3))) + " mm"
    }
}
