import AeroBenchKit
import AppKit
import SwiftUI

/// Prism layer sizes for a target y+, to type into STAR's mesher: the inputs
/// in a glass pane, the near-wall thickness as the screen's spotlight, and
/// STAR's settings in a glassout console, each with a copy button.
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
        HStack(alignment: .top, spacing: 0) {
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
            }
            .formStyle(.grouped)
            .s37Region()
            .frame(minWidth: 340, maxWidth: 440)

            ScrollView {
                VStack(alignment: .leading, spacing: S37.Space.s6) {
                    if let layer {
                        S37Spotlight(label: "Prism Layer Near Wall Thickness", figure: millimetres(layer.firstCell), unit: "mm",
                                     note: "\(layer.layers) layers, \(millimetres(layer.total)) mm in all, Reynolds \(layer.reynolds.formatted(.number.notation(.scientific).precision(.significantDigits(3)))).")
                        if layer.layers < 10 {
                            Label("Under 10 layers leaves the boundary layer under-resolved: lower the stretching.", systemImage: "exclamationmark.triangle")
                                .font(.system(size: 14, weight: .medium)).foregroundStyle(S37.C.clayInk)
                        }
                        StarConsole(layer: layer)
                        notes(layer)
                    } else {
                        Text("Every value must be above zero, and stretching above 1.")
                            .foregroundStyle(S37.C.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .s37Pane()
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: 560)
            Spacer(minLength: 0)
        }
    }

    private func notes(_ layer: PrismLayer) -> some View {
        VStack(alignment: .leading, spacing: S37.Space.s2) {
            Text("Where the numbers come from").font(.system(size: 16, weight: .semibold)).foregroundStyle(S37.C.ink)
            if layer.slotShare < 1 {
                Text("The slot holds \(percent(layer.gapFillPercentage)) % a side, so the layer thins there to \((100 * layer.slotShare).formatted(.number.precision(.fractionLength(0)))) % of the total. The reduction and minimum thickness percentages sit below that, so every layer is kept.")
            }
            Text("Flat-plate estimates: Cf = 0.026 Re^-1/7 for the wall distance, 0.37 c Re^-0.2 for the total, at the trailing edge, where it is thickest. Gap fill is the prism share of the slot on each side, at least STAR's 25 and at most 40, as in the engine's meshes. STAR is cell-centred, so the first cell is twice the wall distance y; SU2 meshes take y itself.")
        }
        .font(.system(size: 13))
        .foregroundStyle(S37.C.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .s37Pane(padding: S37.Space.s5)
    }

    private func field(_ label: String, _ unit: String, _ value: Binding<Double>) -> some View {
        LabeledContent(label) {
            HStack {
                TextField(label, value: value, format: .number).labelsHidden().multilineTextAlignment(.trailing).frame(width: 110)
                Text(unit).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            }
        }
    }
}

/// STAR's prism mesher settings as the machine prints them, each with a
/// copy button for the bare number. A reply types on after a copy.
struct StarConsole: View {
    let layer: PrismLayer
    @State private var copied = ""
    @State private var copies = 0

    var body: some View {
        let rows: [(String, String, String)] = [
            ("Number of Prism Layers", "\(layer.layers)", ""),
            ("Prism Layer Near Wall Thickness", millimetres(layer.firstCell), "mm"),
            ("Prism Layer Total Thickness (absolute)", millimetres(layer.total), "mm"),
            ("Minimum Thickness Percentage", percent(layer.minimumThicknessPercentage), "%"),
            ("Gap Fill Percentage", percent(layer.gapFillPercentage), "%"),
            ("Prism Layer Reduction Percentage", percent(layer.reductionPercentage), "%"),
            ("Wall distance y", millimetres(layer.wallDistance), "mm"),
        ]
        GOScreen {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    GOMeta(text: "Console · STAR prism layer mesher")
                    Spacer(minLength: 8)
                    GOPlainButton(label: "Copy all") {
                        copy(rows.map { "\($0.0)\t\($0.1)" }.joined(separator: "\n"))
                        copied = "Copied \(rows.count) lines."
                        copies += 1
                    }
                }
                .padding(.bottom, 8)
                ForEach(rows, id: \.0) { name, value, unit in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(name).foregroundStyle(GO.C.phosphorDim)
                        Spacer(minLength: 8)
                        Text(value).fontWeight(.semibold).foregroundStyle(GO.C.phosphorBright).modifier(GOGlow(kind: .bright))
                            .textSelection(.enabled)
                        Text(unit).foregroundStyle(GO.C.phosphorFaint).frame(width: 22, alignment: .leading)
                        GOPlainButton(label: "Copy") {
                            copy(value)
                            copied = "Copied \(value)\(unit.isEmpty ? "" : " " + unit)."
                            copies += 1
                        }
                        .help("Copy \(value)")
                    }
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 28)
                }
                HStack(spacing: 6) {
                    Text(">").foregroundStyle(GO.C.phosphorFaint)
                    GOTypeOn(text: copied.isEmpty ? "Ready." : copied, trigger: copies)
                        .foregroundStyle(GO.C.phosphor).modifier(GOGlow())
                }
                .padding(.top, 8)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private func percent(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)))
}

private func millimetres(_ metres: Double) -> String {
    String(format: "%.4g", metres * 1000)  // plain digits, no grouping, so it pastes as a number
}
