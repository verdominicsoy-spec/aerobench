import AeroBenchKit
import AppKit
import SwiftUI

/// Prism layer settings for STAR 2606's custom prism control: the three
/// values it takes side by side at one size, then the inputs and a glassout
/// console to copy them from.
struct PrismLayerView: View {
    @AppStorage("prism.treatment") private var treatment = PrismLayer.WallTreatment.resolved
    @AppStorage("prism.velocity") private var velocity = 15.0
    @AppStorage("prism.density") private var density = 1.225
    @AppStorage("prism.yPlus") private var yPlus = 1.0
    @AppStorage("prism.viscosity") private var viscosity = 1.81e-5
    @AppStorage("prism.chord") private var length = 0.3
    @AppStorage("prism.clearance") private var clearance = 0.0  // mm, 0: no wall nearby
    @AppStorage("prism.layers") private var wallFunctionLayers = 4
    @AppStorage("prism.stretching") private var stretching = 1.2
    @State private var wide = true
    @State private var showWorking = false

    var body: some View {
        let layer = PrismLayer(velocity: velocity, density: density, yPlus: yPlus, viscosity: viscosity, length: length,
                               treatment: treatment, layers: wallFunctionLayers,
                               clearance: clearance > 0 ? clearance / 1000 : nil, stretching: stretching)
        let row = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: S37.Space.s6))
                       : AnyLayout(VStackLayout(alignment: .leading, spacing: S37.Space.s6))
        ScrollView {
            VStack(alignment: .leading, spacing: S37.Space.s6) {
                if let layer {
                    results(layer)
                } else {
                    Text("Every value must be above zero, and stretching above 1.")
                        .foregroundStyle(S37.C.clayInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .s37Pane()
                }
                row {
                    inputs(layer)
                        .frame(width: wide ? 380 : nil)
                        .frame(maxWidth: wide ? nil : 560, alignment: .leading)  // stacked, fields stay near their labels
                    // STAR's names run long: the console takes the rest of the row
                    if let layer { StarConsole(layer: layer).frame(minWidth: 460) }
                }
            }
            .padding(6)
            // side by side only when the 380 inputs leave the console room for STAR's long names
            .onGeometryChange(for: Bool.self) { $0.size.width >= 940 } action: { wide = $0 }
        }
        .scrollIndicators(.never)
        .preference(key: ToolTakeawayKey.self, value: layer.map {
            "\($0.layers) layers, \(millimetres($0.total)) mm total, \(millimetres($0.firstCell)) mm near wall."
        } ?? "Every value must be above zero, and stretching above 1.")
    }

    /// The three STAR values at one size in one surface, what they rest on under them
    private func results(_ layer: PrismLayer) -> some View {
        VStack(alignment: .leading, spacing: S37.Space.s4) {
            HStack(alignment: .top, spacing: 0) {
                output("Number of Prism Layers", "\(layer.layers)", "",
                       note: layer.treatment == .resolved ? "From the near wall cell at stretching \(decimal(layer.stretching))" : "Wall functions, \(decimal(layer.stretching)) stretching")
                hairline
                output("Prism Layer Total Thickness", millimetres(layer.total), "mm",
                       aside: layer.capped ? "uncapped \(millimetres(layer.uncappedTotal)) mm" : nil,
                       note: layer.capped ? "Capped at a third of the gap" : layer.treatment == .resolved ? "The full boundary layer" : "Sum of the layers")
                hairline
                output("Prism Layer Near Wall Thickness", millimetres(layer.firstCell), "mm",
                       note: "Goes in the prism control, not a surface size")
            }
            Rectangle().fill(S37.C.separator).frame(height: 1)
            HStack(spacing: S37.Space.s6) {
                fact("Achieved y+", decimal(layer.achievedYPlus))
                fact("Re", layer.reynolds.formatted(.number.notation(.scientific).precision(.significantDigits(3))))
                fact("u*", "\(decimal(layer.frictionVelocity)) m/s")
                fact("δ", "\(millimetres(layer.boundaryLayer)) mm")
            }
            .padding(.horizontal, S37.Space.s4)
            if !layer.warnings.isEmpty {
                VStack(alignment: .leading, spacing: S37.Space.s2) {
                    ForEach(layer.warnings, id: \.self) { warning in
                        Label(text(warning, layer), systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(S37.C.clayInk)
                            .padding(.horizontal, S37.Space.s3).padding(.vertical, S37.Space.s1)
                            .background(Capsule().fill(S37.C.clayWash))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, S37.Space.s4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .s37Pane(padding: S37.Space.s5)
    }

    private var hairline: some View { Rectangle().fill(S37.C.separator).frame(width: 1) }

    private func output(_ field: String, _ figure: String, _ unit: String, aside: String? = nil, note: String) -> some View {
        VStack(alignment: .leading, spacing: S37.Space.s2) {
            Text(field).font(.system(size: 12, weight: .semibold)).foregroundStyle(S37.C.inkSecondary)
            HStack(alignment: .firstTextBaseline, spacing: S37.Space.s1) {
                Text(figure).font(.system(size: 32, weight: .semibold)).tracking(-0.9).monospacedDigit()
                    .foregroundStyle(aside == nil ? S37.C.ink : S37.C.clayInk).lineLimit(1).minimumScaleFactor(0.6)
                if !unit.isEmpty { Text(unit).font(.system(size: 16, weight: .medium)).foregroundStyle(S37.C.inkSecondary) }
                if let aside {
                    Text(aside).font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.clayInk)
                        .padding(.leading, S37.Space.s1).lineLimit(1)
                }
            }
            Text(note).font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textSelection(.enabled)
        .padding(.horizontal, S37.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: S37.Space.s1) {
            Text(label).foregroundStyle(S37.C.inkTertiary)
            Text(value).foregroundStyle(S37.C.inkSecondary).monospacedDigit()
        }
        .font(.system(size: 12, weight: .medium))
        .textSelection(.enabled)
    }

    private func text(_ warning: PrismLayer.Warning, _ layer: PrismLayer) -> String {
        switch warning {
        case .noClearance: "No gap set, so the total is the full boundary layer. A nearby wall will crush it."
        case .thickStack: "Over 10 mm with wall functions. Check it fits every gap."
        case .steepStretching: "Stretching over 1.3 skews the outer layers."
        case .yPlusOutOfRange:
            layer.treatment == .resolved ? "y+ \(decimal(layer.achievedYPlus)) is outside 0.5 to 5 for a resolved wall."
                                         : "y+ \(decimal(layer.achievedYPlus)) is outside 30 to 100 for wall functions."
        case .thinFirstCell: "Near wall thickness under 5 µm. Expect poor cell quality."
        }
    }

    private func inputs(_ layer: PrismLayer?) -> some View {
        VStack(alignment: .leading, spacing: S37.Space.s5) {
            HStack(spacing: S37.Space.s2) {
                Text("Preset").font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.inkTertiary)
                Menu("Choose") {
                    Button("Wing / floor") { fill(.resolved, yPlus: 1, layers: nil, stretching: 1.2) }
                    Button("Body / wheels") { fill(.wallFunctions, yPlus: 40, layers: 4, stretching: 1.25) }
                    Button("Suspension") { fill(.wallFunctions, yPlus: 40, layers: 3, stretching: 1.3) }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .font(.system(size: 12, weight: .semibold))
            }
            S37Segmented(options: [(PrismLayer.WallTreatment.resolved, "Resolved (y+ ≈ 1)"),
                                   (.wallFunctions, "Wall functions (y+ 30 to 50)")],
                         selection: mode)
            group("Flow") {
                field("Velocity", "m/s", $velocity)
                field("Density", "kg/m³", $density)
                field("Target y+", "", $yPlus)
            }
            group("Geometry") {
                field("Reference length", "m", $length)
                field("Nearest gap to another wall", "mm", gap, hint: "floor to ground, arm to floor, slot gap")
            }
            group("Layers") {
                if treatment == .wallFunctions {
                    HStack(spacing: S37.Space.s2) {
                        Text("Number of layers").font(.system(size: 14)).foregroundStyle(S37.C.ink)
                        Spacer(minLength: S37.Space.s2)
                        Text("\(wallFunctionLayers)").font(.system(size: 14)).monospacedDigit()
                        Stepper("Number of layers", value: $wallFunctionLayers, in: 2...6).labelsHidden()
                            .frame(width: 40, alignment: .leading)
                    }
                    .padding(.horizontal, S37.Space.s3)
                    .frame(height: 40)
                }
                field("Stretching", "", $stretching)
                field("Viscosity", "Pa·s", $viscosity)
            }
            DisclosureGroup(isExpanded: $showWorking) {
                Text("Re = ρUL/μ and Cf = 0.026 Re^-1/7 (turbulent flat plate) give u* = U √(Cf/2), and y = y+ μ/(ρ u*). STAR reports y+ at the cell centroid, so the near wall thickness is h1 = 2 y, everywhere the first cell is used. Resolved: the total is δ = 0.37 L Re^-0.2, and the layer count is what reaches it from h1 at the stretching. Wall functions: the total is h1 (r^n − 1)/(r − 1) for the count you pick. With a gap set, the total is capped at a third of it, since both walls grow prisms into the gap and the core cells need the middle third. STAR 2606 has no stretching field in a custom prism control: it works the stretching out from the three values.")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, S37.Space.s2)
            } label: {
                Text("How it's calculated").font(.system(size: 14, weight: .semibold)).foregroundStyle(S37.C.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .s37Pane(padding: S37.Space.s5)
    }

    /// Switching the wall treatment resets y+ and stretching to that treatment's defaults
    private var mode: Binding<PrismLayer.WallTreatment> {
        Binding(get: { treatment }, set: { new in
            guard new != treatment else { return }
            fill(new, yPlus: new == .resolved ? 1 : 40, layers: nil, stretching: new == .resolved ? 1.2 : 1.25)
        })
    }

    private func fill(_ treatment: PrismLayer.WallTreatment, yPlus: Double, layers: Int?, stretching: Double) {
        self.treatment = treatment
        self.yPlus = yPlus
        self.stretching = stretching
        if let layers { wallFunctionLayers = layers }
    }

    /// The clearance as an optional, so an empty box means no wall nearby
    private var gap: Binding<Double?> {
        Binding(get: { clearance > 0 ? clearance : nil }, set: { clearance = $0 ?? 0 })
    }

    private func group<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: S37.Space.s2) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(S37.C.ink)
            VStack(spacing: 0) { rows() }
                .background(RoundedRectangle(cornerRadius: S37.concentric(S37.Radius.xlContent, S37.Space.s5), style: .continuous)
                    .fill(S37.C.inset))
        }
    }

    private func field(_ label: String, _ unit: String, _ value: Binding<Double>) -> some View {
        field(label, unit, Binding<Double?>(get: { value.wrappedValue }, set: { if let v = $0 { value.wrappedValue = v } }))
    }

    private func field(_ label: String, _ unit: String, _ value: Binding<Double?>, hint: String? = nil) -> some View {
        HStack(spacing: S37.Space.s2) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.system(size: 14)).foregroundStyle(S37.C.ink).fixedSize(horizontal: false, vertical: true)
                if let hint {
                    Text(hint).font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: S37.Space.s2)
            TextField(label, value: value, format: .number, prompt: hint == nil ? nil : Text("none"))
                .textFieldStyle(.plain).labelsHidden().multilineTextAlignment(.trailing)
                .font(.system(size: 14)).monospacedDigit()
                .padding(.horizontal, S37.Space.s2).frame(width: hint == nil ? 112 : 72, height: 28)
                .background(RoundedRectangle(cornerRadius: S37.Radius.sm, style: .continuous).fill(S37.C.recess))
            Text(unit).font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.inkTertiary)
                .frame(width: 40, alignment: .leading)
        }
        .padding(.horizontal, S37.Space.s3)
        .frame(minHeight: 40)
        .padding(.vertical, hint == nil ? 0 : S37.Space.s1)
    }
}

/// STAR 2606's custom prism control values as the machine prints them, in
/// the order the panel lists them, each with a copy button for the bare number.
struct StarConsole: View {
    let layer: PrismLayer
    @State private var copied: String?  // the row whose button reads Copied

    var body: some View {
        let rows: [(String, String, String)] = [
            ("Number of Prism Layers", "\(layer.layers)", ""),
            ("Prism Layer Total Thickness", millimetres(layer.total), "mm"),
            ("Prism Layer Near Wall Thickness", millimetres(layer.firstCell), "mm"),
        ]
        GOScreen {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    GOMeta(text: "STAR 2606 prism control")
                    Spacer(minLength: 8)
                    GOPlainButton(label: copied == "all" ? "Copied" : "Copy for STAR") { copy(layer.starLines, "all") }
                }
                .padding(.bottom, 8)
                ForEach(rows, id: \.0) { name, value, unit in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(name).foregroundStyle(GO.C.phosphorDim).lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 8)
                        Text(value).fontWeight(.semibold).foregroundStyle(GO.C.phosphorBright).modifier(GOGlow(kind: .bright))
                            .textSelection(.enabled)
                        Text(unit).foregroundStyle(GO.C.phosphorFaint).frame(width: 22, alignment: .leading)
                        GOPlainButton(label: copied == name ? "Copied" : "Copy") { copy(value, name) }
                            .frame(width: 92, alignment: .trailing)
                            .help("Copy \(value)")
                    }
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 28)
                }
                Text(layer.starLines.split(separator: "\n").last.map(String.init) ?? "")
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(GO.C.phosphorFaint)
                    .textSelection(.enabled)
                    .frame(minHeight: 28)
            }
        }
    }

    private func copy(_ text: String, _ row: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = row
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if copied == row { copied = nil }
        }
    }
}

private func decimal(_ value: Double) -> String {
    value.formatted(.number.precision(.significantDigits(1...3)))
}
