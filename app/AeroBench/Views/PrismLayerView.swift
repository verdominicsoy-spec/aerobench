import AeroBenchKit
import AppKit
import SwiftUI

/// Prism layer settings for STAR 2606's custom prism control: the three
/// values it takes side by side at one size, each with a copy button, then
/// the inputs. Flow and length start from the project (Wing Lab's speed, air
/// and main chord); a typed value stays typed, per project.
struct PrismLayerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.undoManager) private var undo
    @State private var showWorking = false
    @State private var copied: String?  // the value whose button shows a tick

    private var inputs: PrismInputs { app.prism.inputs }
    private var wing: Wing { app.wingLab.wing }
    private var velocity: Double { inputs.velocity ?? wing.speed }
    private var density: Double { inputs.density ?? wing.rho }
    private var viscosity: Double { inputs.viscosity ?? wing.mu }
    private var length: Double { inputs.length ?? wing.elements.map(\.chord).max() ?? 0.3 }
    private var yPlus: Double { inputs.yPlus }
    private var stretching: Double { inputs.stretching }
    private var wallFunctionLayers: Int { inputs.layers }
    private var clearance: Double { inputs.clearance }

    var body: some View {
        let layer = PrismLayer(velocity: velocity, density: density, yPlus: yPlus, viscosity: viscosity, length: length,
                               layers: wallFunctionLayers,
                               clearance: clearance > 0 ? clearance / 1000 : nil, stretching: stretching)
        // The cards fill the window, and scroll only once they no longer fit it
        ViewThatFits(in: .vertical) {
            page(layer)
            ScrollView { page(layer) }.scrollIndicators(.never)
        }
    }

    private func page(_ layer: PrismLayer?) -> some View {
        VStack(alignment: .leading, spacing: S37.Space.s4) {
            if let layer { results(layer) }  // otherwise the bad field says how to fix it
            inputPane
        }
        .padding(6)
    }

    /// The three STAR values at one size in one surface, what they rest on under them
    private func results(_ layer: PrismLayer) -> some View {
        VStack(alignment: .leading, spacing: S37.Space.s4) {
            HStack(alignment: .top, spacing: 0) {
                output("Number of Prism Layers", "\(layer.layers)", "")
                hairline
                output("Prism Layer Total Thickness", millimetres(layer.total), "mm",
                       aside: layer.capped ? "uncapped \(millimetres(layer.uncappedTotal)) mm" : nil,
                       note: layer.capped ? (layer.treatment == .resolved ? "Capped at a third of the gap" : "The layers that fit in a third of the gap") : nil)
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
        .s37Pane(padding: S37.Space.s3)
    }

    private var hairline: some View { Rectangle().fill(S37.C.separator).frame(width: 1) }

    private func output(_ field: String, _ figure: String, _ unit: String, aside: String? = nil, note: String? = nil) -> some View {
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
                .help("Copy")
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
            if let note {
                Text(note).font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    private var inputPane: some View {
        VStack(alignment: .leading, spacing: S37.Space.s3) {
            HStack(spacing: S37.Space.s4) {
                Menu("Preset") {
                    Button("Wing / floor") { fill(yPlus: 1, layers: nil, stretching: 1.2) }
                    Button("Body / wheels") { fill(yPlus: 40, layers: 4, stretching: 1.25) }
                    Button("Suspension") { fill(yPlus: 40, layers: 3, stretching: 1.3) }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .font(.system(size: 14, weight: .semibold))
                // the mode follows Target y+, so it's shown, not picked
                Text(treatment == .resolved ? "Resolved, y+ about 1" : "Wall functions, y+ 30 to 100")
                    .font(.system(size: 14)).foregroundStyle(S37.C.inkSecondary)
                if inputs != PrismInputs() {
                    Button("Use project values") { set(\.self, PrismInputs(), "Use Project Values") }
                        .buttonStyle(S37ButtonStyle(kind: .plain))
                }
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
        .s37Pane(padding: S37.Space.s3)
    }

    private var flowGroup: some View {
        group("Flow") {
            S37FieldRow(label: "Velocity", unit: "m/s", value: project(\.velocity, velocity, "Velocity"),
                        error: positive(velocity, "a speed", "m/s"), check: S37NumberInput.within(0.1...150, "m/s"))
            S37FieldRow(label: "Density", unit: "kg/m³", value: project(\.density, density, "Density"),
                        error: positive(density, "a density", "kg/m³"), check: S37NumberInput.within(0.3...2, "kg/m³"))
            S37FieldRow(label: "Target y+", value: binding(\.yPlus, "Target y+"), error: positive(yPlus, "a y+", ""))
        }
    }

    private var geometryGroup: some View {
        group("Geometry") {
            S37FieldRow(label: "Reference length", unit: "m", value: project(\.length, length, "Reference Length"),
                        error: positive(length, "a length", "m"))
            S37FieldRow(label: "Nearest gap to another wall", unit: "mm", value: gap, prompt: "none",
                        error: clearance < 0 ? "Use a gap above 0 mm, or leave it empty" : nil, width: 72)
        }
    }

    private var layersGroup: some View {
        group("Layers") {
            if treatment == .wallFunctions {
                HStack(spacing: S37.Space.s2) {
                    Text("Number of layers").font(.system(size: 14)).foregroundStyle(S37.C.ink)
                    Spacer(minLength: S37.Space.s2)
                    Text("\(wallFunctionLayers)").font(.system(size: 14)).monospacedDigit()
                    Stepper("Number of layers", value: binding(\.layers, "Number of Layers"), in: 2...6).labelsHidden()
                        .frame(width: 40, alignment: .leading)
                }
            }
            S37FieldRow(label: "Stretching", value: binding(\.stretching, "Stretching"),
                        error: stretching > 1 && stretching.isFinite ? nil : "Use stretching above 1")
            S37FieldRow(label: "Viscosity", unit: "Pa·s", value: project(\.viscosity, viscosity, "Viscosity"),
                        error: positive(viscosity, "a viscosity", "Pa·s"))
        }
    }

    /// The wall treatment Target y+ sets
    private var treatment: PrismLayer.WallTreatment { PrismLayer.WallTreatment(yPlus: yPlus) }

    /// A preset sets y+, and the mode follows
    private func fill(yPlus: Double, layers: Int?, stretching: Double) {
        var next = inputs
        next.yPlus = yPlus
        next.stretching = stretching
        if let layers { next.layers = layers }
        set(\.self, next, "Preset")
    }

    /// "Use a speed above 0 m/s" when the value can't be used
    private func positive(_ value: Double, _ what: String, _ unit: String) -> String? {
        value > 0 && value.isFinite ? nil : "Use \(what) above 0" + (unit.isEmpty ? "" : " \(unit)")
    }

    private func set<V: Equatable>(_ key: WritableKeyPath<PrismInputs, V>, _ value: V, _ name: String) {
        app.prism.set(key, value, name, undo: undo)
    }

    private func binding<V: Equatable>(_ key: WritableKeyPath<PrismInputs, V>, _ name: String) -> Binding<V> {
        Binding(get: { inputs[keyPath: key] }, set: { set(key, $0, name) })
    }

    /// A value that follows the project until it's typed
    private func project(_ key: WritableKeyPath<PrismInputs, Double?>, _ shown: Double, _ name: String) -> Binding<Double> {
        // Leaving the field commits what it shows: that isn't typing a value
        Binding(get: { shown }, set: { if inputs[keyPath: key] != nil || $0 != shown { set(key, $0, name) } })
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
        Binding(get: { clearance > 0 ? clearance : nil }, set: { set(\.clearance, $0 ?? 0, "Nearest Gap") })
    }

    private func group<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        S37Section(title, rows: rows).frame(minWidth: 300, maxWidth: .infinity, alignment: .topLeading)
    }
}

private func decimal(_ value: Double) -> String {
    value.formatted(.number.precision(.significantDigits(1...3)))
}

/// Prism Layer's inputs for one project. A nil value follows the project
/// (Wing Lab's speed, air and main chord); a typed one stays typed.
struct PrismInputs: Codable, Equatable {
    var velocity: Double?
    var density: Double?
    var viscosity: Double?
    var length: Double?
    var yPlus = 1.0
    var clearance = 0.0  // mm, 0: no wall nearby
    var layers = 4
    var stretching = 1.2
}

/// The open project's Prism Layer inputs, kept in the user defaults per project
@MainActor @Observable
final class PrismModel {
    private(set) var inputs = PrismInputs()
    private var key = PrismModel.key(nil)

    static func key(_ project: URL?) -> String { "prism.inputs." + (project?.standardizedFileURL.path ?? "none") }

    func load(project: URL?) {
        key = Self.key(project)
        inputs = Self.read(key)
    }

    /// One edit, undoable as `name`. Undo writes back to the project it came
    /// from, even if another one is open by then.
    func set<V: Equatable>(_ path: WritableKeyPath<PrismInputs, V>, _ value: V, _ name: String, undo: UndoManager?) {
        edit(key, path, value, name, undo)
    }

    private func edit<V: Equatable>(_ key: String, _ path: WritableKeyPath<PrismInputs, V>, _ value: V, _ name: String,
                                    _ undo: UndoManager?) {
        var stored = key == self.key ? inputs : Self.read(key)
        let old = stored[keyPath: path]
        guard old != value else { return }
        stored[keyPath: path] = value
        if key == self.key { inputs = stored }
        UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: key)
        undo?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.edit(key, path, old, name, undo) }
        }
        undo?.setActionName(name)
    }

    private static func read(_ key: String) -> PrismInputs {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(PrismInputs.self, from: $0) } ?? PrismInputs()
    }
}
