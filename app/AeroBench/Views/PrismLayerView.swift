import AeroBenchKit
import AppKit
import SwiftUI

/// Prism layer sizes for a target y+, to type into STAR's mesher: the
/// answer first (the near-wall thickness as the spotlight beside a strip of
/// layers, total and Reynolds), then the inputs and STAR's settings in a
/// glassout console side by side, each value with a copy button.
struct PrismLayerView: View {
    @AppStorage("prism.velocity") private var velocity = 15.0
    @AppStorage("prism.density") private var density = 1.225
    @AppStorage("prism.yPlus") private var yPlus = 1.0
    @AppStorage("prism.viscosity") private var viscosity = 1.81e-5
    @AppStorage("prism.chord") private var chord = 0.3
    @AppStorage("prism.slotGap") private var slotGap = 0.0  // 0: a single element, no slot
    @AppStorage("prism.stretching") private var stretching = 1.2
    @State private var wide = true
    @State private var showWorking = false

    var body: some View {
        let layer = PrismLayer(velocity: velocity, density: density, yPlus: yPlus,
                               viscosity: viscosity, chord: chord,
                               slotGap: slotGap > 0 ? slotGap / 1000 : nil, stretching: stretching)
        let row = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: S37.Space.s6))
                       : AnyLayout(VStackLayout(alignment: .leading, spacing: S37.Space.s6))
        ScrollView {
            VStack(alignment: .leading, spacing: S37.Space.s6) {
                if let layer {
                    row {
                        S37Spotlight(label: "Near wall thickness", figure: millimetres(layer.firstCell), unit: "mm",
                                     note: "STAR's Prism Layer Near Wall Thickness: the whole first cell, twice the wall distance y.")
                            .frame(maxWidth: wide ? 400 : .infinity)
                        stats(layer)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Every value must be above zero, and stretching above 1.")
                        .foregroundStyle(S37.C.clayInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .s37Pane()
                }
                row {
                    inputs(layer)
                        .frame(width: wide ? 320 : nil)
                    // STAR's names run long: the console takes the rest of the row
                    if let layer { StarConsole(layer: layer).frame(minWidth: 500) }
                }
            }
            .padding(6)
            .onGeometryChange(for: Bool.self) { $0.size.width >= 860 } action: { wide = $0 }
        }
        .scrollIndicators(.never)
        .preference(key: ToolTakeawayKey.self, value: layer.map {
            "\($0.layers) layers: \(millimetres($0.firstCell)) mm first cell, \(millimetres($0.total)) mm in all."
        } ?? "Every value must be above zero, and stretching above 1.")
    }

    /// The figures that come with the spotlight, one surface split by hairlines
    private func stats(_ layer: PrismLayer) -> some View {
        VStack(alignment: .leading, spacing: S37.Space.s4) {
            HStack(alignment: .top, spacing: 0) {
                stat("Layers", "\(layer.layers)", "")
                Rectangle().fill(S37.C.separator).frame(width: 1)
                stat("Total", millimetres(layer.total), "mm")
                Rectangle().fill(S37.C.separator).frame(width: 1)
                stat("Reynolds", layer.reynolds.formatted(.number.notation(.scientific).precision(.significantDigits(3))), "")
            }
            if layer.layers < 10 {
                Label("Under 10 layers leaves the boundary layer under-resolved: lower the stretching.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(S37.C.clayInk)
                    .padding(.horizontal, S37.Space.s3).padding(.vertical, S37.Space.s1)
                    .background(Capsule().fill(S37.C.clayWash))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .s37Pane(padding: S37.Space.s5)
    }

    private func stat(_ label: String, _ figure: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: S37.Space.s2) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.inkTertiary)
            HStack(alignment: .firstTextBaseline, spacing: S37.Space.s1) {
                Text(figure).font(.system(size: 32, weight: .semibold)).tracking(-0.9).monospacedDigit()
                    .foregroundStyle(S37.C.ink).lineLimit(1).minimumScaleFactor(0.6)
                if !unit.isEmpty { Text(unit).font(.system(size: 16, weight: .medium)).foregroundStyle(S37.C.inkSecondary) }
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, S37.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inputs(_ layer: PrismLayer?) -> some View {
        VStack(alignment: .leading, spacing: S37.Space.s5) {
            group("Flow", note: "y+ sets only the first cell.",
                  help: "y+ sets only the first cell. The total thickness comes from the chord and the Reynolds number.") {
                field("Velocity", "m/s", $velocity)
                field("Density", "kg/m³", $density)
                field("Target y+", "", $yPlus)
            }
            group("Element", note: "Slot gap 0 means a single element.",
                  help: "The element you are meshing: the boundary layer grows along the chord. The slot gap is the narrowest gap to the next element; 0 for a single element.") {
                field("Chord", "m", $chord)
                field("Slot gap", "mm", $slotGap)
            }
            group("Also needed", note: "Air at 15 °C is 1.81e-5 Pa·s.",
                  help: "Air at 15 °C is 1.81e-5 Pa·s. Stretching sets only the number of layers.") {
                field("Dynamic viscosity", "Pa·s", $viscosity)
                field("Stretching", "", $stretching)
            }
            DisclosureGroup(isExpanded: $showWorking) {
                VStack(alignment: .leading, spacing: S37.Space.s2) {
                    if let layer, layer.slotShare < 1 {
                        Text("The slot holds \(percent(layer.gapFillPercentage)) % a side, so the layer thins there to \((100 * layer.slotShare).formatted(.number.precision(.fractionLength(0)))) % of the total. The reduction and minimum thickness percentages sit below that, so every layer is kept.")
                    }
                    Text("Flat-plate estimates: Cf = 0.026 Re^-1/7 for the wall distance, 0.37 c Re^-0.2 for the total, at the trailing edge, where it is thickest. Gap fill is the prism share of the slot on each side, at least STAR's 25 and at most 40, as in the engine's meshes. STAR is cell-centred, so the first cell is twice the wall distance y; SU2 meshes take y itself.")
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, S37.Space.s2)
            } label: {
                Text("Where the numbers come from").font(.system(size: 14, weight: .semibold)).foregroundStyle(S37.C.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .s37Pane(padding: S37.Space.s5)
    }

    private func group<Rows: View>(_ title: String, note: String, help: String,
                                   @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: S37.Space.s2) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(S37.C.ink)
            VStack(spacing: 0) { rows() }
                .background(RoundedRectangle(cornerRadius: S37.Radius.lgIn, style: .continuous).fill(S37.C.inset))
            Text(note).font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.inkTertiary)
                .padding(.horizontal, S37.Space.s1)
                .help(help)
        }
    }

    private func field(_ label: String, _ unit: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: S37.Space.s2) {
            Text(label).font(.system(size: 14)).foregroundStyle(S37.C.ink).lineLimit(1)
            Spacer(minLength: S37.Space.s2)
            TextField(label, value: value, format: .number)
                .textFieldStyle(.plain).labelsHidden().multilineTextAlignment(.trailing)
                .font(.system(size: 14)).monospacedDigit()
                .padding(.horizontal, S37.Space.s2).frame(width: 112, height: 28)
                .background(RoundedRectangle(cornerRadius: S37.Radius.sm, style: .continuous).fill(S37.C.recess))
            Text(unit).font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.inkTertiary)
                .frame(width: 40, alignment: .leading)
        }
        .padding(.horizontal, S37.Space.s3)
        .frame(height: 40)
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
                        Text(name).foregroundStyle(GO.C.phosphorDim).lineLimit(1).minimumScaleFactor(0.8)
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
