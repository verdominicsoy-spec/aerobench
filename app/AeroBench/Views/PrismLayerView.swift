import AeroBenchKit
import AppKit
import SwiftUI

/// Prism layer settings for STAR 2606's custom prism control: the three
/// values it takes side by side at one size, each with a copy button, then
/// the inputs.
struct PrismLayerView: View {
    @AppStorage("prism.velocity") private var velocity = 15.0
    @AppStorage("prism.density") private var density = 1.225
    @AppStorage("prism.yPlus") private var yPlus = 1.0
    @AppStorage("prism.viscosity") private var viscosity = 1.81e-5
    @AppStorage("prism.chord") private var length = 0.3
    @AppStorage("prism.clearance") private var clearance = 0.0  // mm, 0: no wall nearby
    @AppStorage("prism.layers") private var wallFunctionLayers = 4
    @AppStorage("prism.stretching") private var stretching = 1.2
    @State private var showWorking = false
    @State private var copied: String?  // the value whose button shows a tick

    var body: some View {
        let layer = PrismLayer(velocity: velocity, density: density, yPlus: yPlus, viscosity: viscosity, length: length,
                               layers: wallFunctionLayers,
                               clearance: clearance > 0 ? clearance / 1000 : nil, stretching: stretching)
        // The cards fill the window, and scroll only once they no longer fit it
        ViewThatFits(in: .vertical) {
            page(layer)
            ScrollView { page(layer) }.scrollIndicators(.never)
        }
        .preference(key: ToolTakeawayKey.self, value: layer == nil ? "Every value must be a number above zero, and stretching above 1." : nil)
    }

    private func page(_ layer: PrismLayer?) -> some View {
        VStack(alignment: .leading, spacing: S37.Space.s6) {
            if let layer {
                results(layer)
            } else {
                Text("Every value must be a number above zero, and stretching above 1.")
                    .foregroundStyle(S37.C.clayInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .s37Pane()
            }
            inputs(layer)
        }
        .padding(6)
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
                       note: layer.capped ? (layer.treatment == .resolved ? "Capped at a third of the gap" : "The layers that fit in a third of the gap") : layer.treatment == .resolved ? "The full boundary layer" : "Sum of the layers")
                hairline
                output("Prism Layer Near Wall Thickness", millimetres(layer.firstCell), "mm",
                       note: "Goes in the prism control, not a surface size")
            }
            .fixedSize(horizontal: false, vertical: true)  // the hairlines would take any spare height
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
            HStack(spacing: S37.Space.s2) {
                Text(field).font(.system(size: 12, weight: .semibold)).foregroundStyle(S37.C.inkSecondary)
                Spacer(minLength: 0)
                Button { copy(figure, field) } label: {
                    Image(systemName: copied == field ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(S37.C.sageInk)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy \(field)")
                .help("Copy \(figure)")
            }
            let value = HStack(alignment: .firstTextBaseline, spacing: S37.Space.s1) {
                Text(figure).font(.system(size: 32, weight: .semibold)).tracking(-0.9).monospacedDigit()
                    .foregroundStyle(aside == nil ? S37.C.ink : S37.C.clayInk).lineLimit(1)
                if !unit.isEmpty { Text(unit).font(.system(size: 16, weight: .medium)).foregroundStyle(S37.C.inkSecondary) }
            }
            if let aside {
                let note = Text(aside).font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.clayInk).lineLimit(1)
                // beside the figure where it fits, under it where it doesn't
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: S37.Space.s2) { value; note }
                    VStack(alignment: .leading, spacing: S37.Space.s1) { value; note }
                }
            } else {
                value
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
        case .bufferLayer:
            "y+ \(decimal(yPlus)) is between the two ranges, so the first cell lands in the buffer layer where neither treatment is accurate. Use 1 or 40."
        case .tooFar: "y+ \(decimal(yPlus)) puts the first cell too far from the wall. Keep it at 100 or under."
        case .layersDropped:
            "Only \(layer.layers) of \(wallFunctionLayers) layers fit in a third of the gap, so the rest don't fit and are dropped."
        case .gapTooSmall:
            "A third of the gap is thinner than the near wall cell, so no prism layer fits. Check the gap is in mm, or turn prisms off on this surface."
        case .smallPart:
            "The first cell reaches past a fifth of the boundary layer, so this part is too small for y+ \(decimal(yPlus)). Lower y+ or check the reference length."
        case .manyLayers: "\(layer.layers) layers will balloon the cell count. Stretching 1.15 to 1.25 is typical."
        case .unlikelyLength: "A reference length over 10 m. Check it's in metres, not mm."
        case .thinFirstCell: "Near wall thickness under 5 µm. Expect poor cell quality."
        }
    }

    private func inputs(_ layer: PrismLayer?) -> some View {
        VStack(alignment: .leading, spacing: S37.Space.s5) {
            HStack(spacing: S37.Space.s2) {
                Text("Preset").font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.inkTertiary)
                Menu("Choose") {
                    Button("Wing / floor") { fill(yPlus: 1, layers: nil, stretching: 1.2) }
                    Button("Body / wheels") { fill(yPlus: 40, layers: 4, stretching: 1.25) }
                    Button("Suspension") { fill(yPlus: 40, layers: 3, stretching: 1.3) }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .font(.system(size: 12, weight: .semibold))
            }
            HStack(spacing: S37.Space.s3) {
                // shows the maths that's running; the mode follows Target y+, so it takes no clicks
                S37Segmented(options: [(PrismLayer.WallTreatment.resolved, "Resolved (y+ ≈ 1)"),
                                       (.wallFunctions, "Wall functions (y+ 30 to 100)")],
                             selection: .constant(treatment))
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(treatment == .resolved ? "Mode: resolved" : "Mode: wall functions")
                Text("Set by Target y+").font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.inkTertiary)
                    .fixedSize()
            }
            // three columns where they fit, then two, then one
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: S37.Space.s5) { flowGroup; geometryGroup; layersGroup }
                HStack(alignment: .top, spacing: S37.Space.s5) {
                    VStack(spacing: S37.Space.s5) { flowGroup; layersGroup }
                    geometryGroup
                }
                VStack(spacing: S37.Space.s5) { flowGroup; geometryGroup; layersGroup }
            }
            DisclosureGroup(isExpanded: $showWorking) {
                Text("Re = ρUL/μ and Cf = 0.026 Re^-1/7 (turbulent flat plate) give u* = U √(Cf/2), and y = y+ μ/(ρ u*). STAR reports y+ at the cell centroid, so the near wall thickness is h1 = 2 y, everywhere the first cell is used. Target y+ picks the maths: up to 1 is resolved, 30 to 100 is wall functions. Between 1 and 30 the first cell sits in the buffer layer, so up to 5 uses the resolved maths and above 5 wall functions, with a warning; over 100 uses wall functions with a warning. Resolved: the total is δ = 0.37 L Re^-0.2, and the layer count is what reaches it from h1 at the stretching. Wall functions: the total is h1 (r^n − 1)/(r − 1) for the count you pick. With a gap set, the total is capped at a third of it, since both walls grow prisms into the gap and the core cells need the middle third. With wall functions that means keeping only the layers whose sum fits. STAR 2606 has no stretching field in a custom prism control: it works the stretching out from the three values.")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, S37.Space.s2)
            } label: {
                Text("How it's calculated").font(.system(size: 14, weight: .semibold)).foregroundStyle(S37.C.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .s37Pane(padding: S37.Space.s5)
    }

    private var flowGroup: some View {
        group("Flow") {
            field("Velocity", "m/s", $velocity)
            field("Density", "kg/m³", $density)
            field("Target y+", "", $yPlus)
        }
    }

    private var geometryGroup: some View {
        group("Geometry") {
            field("Reference length", "m", $length)
            field("Nearest gap to another wall", "mm", gap, hint: "floor to ground, arm to floor, slot gap")
        }
    }

    private var layersGroup: some View {
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
    }

    /// The wall treatment Target y+ sets
    private var treatment: PrismLayer.WallTreatment { PrismLayer.WallTreatment(yPlus: yPlus) }

    /// A preset sets y+, and the mode follows
    private func fill(yPlus: Double, layers: Int?, stretching: Double) {
        self.yPlus = yPlus
        self.stretching = stretching
        if let layers { wallFunctionLayers = layers }
    }

    private func copy(_ text: String, _ key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = key
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if copied == key { copied = nil }
        }
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
        .frame(minWidth: 300, maxWidth: .infinity, alignment: .topLeading)
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

private func decimal(_ value: Double) -> String {
    value.formatted(.number.precision(.significantDigits(1...3)))
}
