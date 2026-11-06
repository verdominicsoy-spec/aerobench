import AeroBenchKit
import AppKit
import Charts
import SwiftUI

struct LapSimView: View {
    var body: some View {
        HSplitView {
            LapSimSetupView()
                .s37Region()
                .frame(minWidth: 400, idealWidth: 440, maxWidth: 560)
            LapSimResultsView()
                .s37Region()
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: Setup

/// One editable car parameter, shown in display units.
struct CarField: Identifiable {
    let id: String
    let label: String
    let unit: String
    let scale: Double  // display = stored * scale
    let keyPath: WritableKeyPath<CarParameters, Double>

    static let all: [CarField] = [
        CarField(id: "mass", label: "Mass with driver", unit: "kg", scale: 1, keyPath: \.mass),
        CarField(id: "cla", label: "ClA", unit: "m²", scale: 1, keyPath: \.cla),
        CarField(id: "cda", label: "CdA", unit: "m²", scale: 1, keyPath: \.cda),
        CarField(id: "muLat", label: "μ lateral", unit: "", scale: 1, keyPath: \.muLat),
        CarField(id: "muLong", label: "μ longitudinal", unit: "", scale: 1, keyPath: \.muLong),
        CarField(id: "power", label: "Peak power", unit: "kW", scale: 0.001, keyPath: \.power),
        CarField(id: "driven", label: "Driven axle load share", unit: "0–1", scale: 1, keyPath: \.drivenAxleFraction),
        CarField(id: "balance", label: "Downforce on driven axle", unit: "0–1", scale: 1, keyPath: \.aeroBalanceDriven),
        CarField(id: "crr", label: "Rolling resistance", unit: "Crr", scale: 1, keyPath: \.crr),
        CarField(id: "rho", label: "Air density", unit: "kg/m³", scale: 1, keyPath: \.rho),
        CarField(id: "vmax", label: "Top speed", unit: "km/h", scale: 3.6, keyPath: \.vMax),
        // Load transfer: 0 for all four is the plain point mass.
        CarField(id: "cog", label: "CoG height", unit: "mm", scale: 1000, keyPath: \.cogHeight),
        CarField(id: "wheelbase", label: "Wheelbase", unit: "mm", scale: 1000, keyPath: \.wheelbase),
        CarField(id: "trackWidth", label: "Track width", unit: "mm", scale: 1000, keyPath: \.trackWidth),
        CarField(id: "loadSens", label: "Tyre load sensitivity", unit: "0–1", scale: 1, keyPath: \.tyreLoadSensitivity),
    ]

    func isPlaceholder(_ car: CarParameters) -> Bool {
        let a = car[keyPath: keyPath]
        let b = CarParameters.placeholder[keyPath: keyPath]
        return abs(a - b) <= 1e-9 * max(abs(b), 1)
    }
}

struct LapSimSetupView: View {
    @Environment(AppState.self) private var app
    @Environment(\.undoManager) private var undo
    @State private var editor: TrackEditorRequest?
    @State private var editorStart: LapSimTrack?  // the track as the editor opened, for undoing Done
    @State private var showWorking = false

    var body: some View {
        let setup = app.lapSim
        let usesPlaceholders = CarField.all.contains { field in setup.cars.contains { field.isPlaceholder($0) } }

        ScrollView {
            VStack(alignment: .leading, spacing: S37.Space.s6) {
                S37Section("Track") {
                    S37Row("Track") {
                        Picker("Track", selection: edit(\.track.kind, "Change Track")) {
                            ForEach([LapSimTrackKind.endurance, .autocross, .fsg, .fsi, .testTrack, .skidpad, .acceleration, .csv, .drawn], id: \.self) { Text(Self.trackTitle($0)).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    trackRows(setup)
                    if setup.track.kind != .drawn {
                        S37Row("Track editor") {
                            Button("Edit a copy…") { openEditor(TrackEditorRequest(copyFrom: setup.track.kind)) }
                                .buttonStyle(S37ButtonStyle())
                                .disabled(setup.track.kind == .csv && setup.track.csvPath == nil)
                        }
                    }
                }

                S37Section("Car") {
                    S37Row("Cars") {
                        Text("\(setup.cars.count)").monospacedDigit()
                        Stepper("Cars", value: Binding(get: { app.lapSim.cars.count }, set: { n in
                            // A new car starts as a copy of A; fewer drops the last.
                            var cars = app.lapSim.cars
                            while cars.count < n { cars.append(app.lapSim.carA) }
                            edit(\.cars, n > setup.cars.count ? "Add Car" : "Remove Car").wrappedValue = Array(cars.prefix(n))
                        }), in: 1...LapSimSetup.maxCars).labelsHidden()
                    }
                    if usesPlaceholders {
                        Label("est. marks a placeholder, not team data", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.clayInk)
                    }
                    CarGrid(edit: { field, car in edit((\LapSimSetup.cars[car]).appending(path: field.keyPath), "Change \(field.label)") })
                        .padding(.vertical, S37.Space.s3)
                    HStack(spacing: S37.Space.s3) {
                        if setup.cars.count > 1 {
                            Button("Copy A to the others") {
                                edit(\.cars, "Copy A to the Others").wrappedValue = Array(repeating: app.lapSim.carA, count: app.lapSim.cars.count)
                            }
                            .buttonStyle(S37ButtonStyle())
                        }
                        Spacer()
                        Button("Reset to placeholders") {
                            edit(\.cars, "Reset to Placeholders").wrappedValue = Array(repeating: .placeholder, count: app.lapSim.cars.count)
                        }
                        .buttonStyle(S37ButtonStyle(kind: .plain))
                    }
                    .padding(.vertical, S37.Space.s2)
                }

                S37Section("Simulation") {
                    S37FieldRow(label: "Resampling step", unit: "m", value: edit(\.ds, "Change Resampling Step"), width: 90)
                    S37Row("Endurance laps") {
                        Text("\(setup.enduranceLaps)").monospacedDigit()
                        Stepper("Endurance laps", value: edit(\.enduranceLaps, "Change Endurance Laps"), in: 1...200).labelsHidden()
                    }
                    S37Row("ClA and CdA sensitivities") {
                        Toggle("ClA and CdA sensitivities", isOn: edit(\.sensitivities, "Change Sensitivities"))
                            .labelsHidden().toggleStyle(.switch)
                    }
                }

                DisclosureGroup(isExpanded: $showWorking) {
                    VStack(alignment: .leading, spacing: S37.Space.s3) {
                        if let note = Self.trackNote(setup.track.kind) { Text(note) }
                        Text("With a CoG height or a tyre load sensitivity, each axle holds its own share of the cornering force with its own load, so the downforce balance against the weight split matters; the rear (driven) axle gains weight under acceleration. All four at 0 is the plain point mass.")
                        Text("ClA worth 1 m² CdA is the exchange rate: at equal lap time, one extra m² of CdA is paid for by this much extra ClA.")
                    }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, S37.Space.s2)
                } label: {
                    Text("How it's calculated").font(.system(size: 14, weight: .semibold)).foregroundStyle(S37.C.inkSecondary)
                }
            }
            .padding(S37.Space.s5)
        }
        .scrollIndicators(.automatic)
        .sheet(item: $editor, onDismiss: {
            // Done changes the project's track: one undo puts it back
            if let start = editorStart, start != app.lapSim.track {
                let done = app.lapSim.track
                app.lapSim.track = start
                edit(\.track, "Edit Track").wrappedValue = done
            }
            editorStart = nil
        }) { TrackEditorView(request: $0) }
    }

    @ViewBuilder private func trackRows(_ setup: LapSimSetup) -> some View {
        switch setup.track.kind {
        case .endurance, .autocross:
            S37Row("Layout") {
                Text("\(setup.track.seed)").monospacedDigit()
                Stepper("Layout", value: edit(\.track.seed, "Change Layout"), in: 1...9999).labelsHidden()
            }
        case .testTrack, .fsg, .fsi:
            EmptyView()
        case .skidpad:
            S37FieldRow(label: "Centreline radius", unit: "m", value: edit(\.track.skidpadRadius, "Change Radius"), width: 90)
        case .acceleration:
            S37FieldRow(label: "Length", unit: "m", value: edit(\.track.accelerationLength, "Change Length"), width: 90)
            S37FieldRow(label: "Start speed", unit: "km/h", value: scaled(edit(\.startSpeed, "Change Start Speed"), 3.6), width: 90)
        case .csv:
            S37Row("File") {
                Text(setup.track.csvPath.map { ($0 as NSString).lastPathComponent } ?? "none").foregroundStyle(S37.C.inkSecondary)
                Button("Import…") { app.importTrackCSV() }.buttonStyle(S37ButtonStyle())
            }
            S37Row("Loop") {
                Picker("Loop", selection: edit(\.track.csvClosed, "Change Loop")) {
                    Text("Detect").tag(Bool?.none)
                    Text("Closed").tag(Bool?.some(true))
                    Text("Open").tag(Bool?.some(false))
                }
                .labelsHidden().fixedSize()
            }
            S37Row("File units") {
                Picker("File units", selection: edit(\.track.csvScale, "Change File Units")) {
                    Text("m").tag(1.0)
                    Text("mm").tag(0.001)
                }
                .labelsHidden().fixedSize()
            }
            S37FieldRow(label: "Point scatter (smoothing)", unit: "m", value: edit(\.track.smoothing, "Change Smoothing"), width: 90)
            S37FieldRow(label: "Start speed (open tracks)", unit: "km/h", value: scaled(edit(\.startSpeed, "Change Start Speed"), 3.6), width: 90)
        case .drawn:
            if let drawn = setup.track.drawn, drawn.isUsable {
                let samples = drawn.samples()
                let issues = drawn.issues(samples)
                S37Row(drawn.source.map { "From \($0)" } ?? "Drawn") {
                    Text("\(samples.last?.s ?? 0, format: .number.precision(.fractionLength(0))) m, \(drawn.closed ? "closed" : "open"), \(drawn.nodes.count) points")
                        .monospacedDigit()
                }
                if !issues.isEmpty {
                    Label("\(issues.count) \(issues.count == 1 ? "place breaks" : "places break") the FS layout rules (it still runs)", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.clayInk)
                }
            }
            S37Row(setup.track.drawn?.isUsable == true ? "Track editor" : "Nothing drawn yet") {
                Button("Edit track…") { openEditor(TrackEditorRequest()) }.buttonStyle(S37ButtonStyle())
            }
            if setup.track.drawn?.closed == false {
                S37FieldRow(label: "Start speed", unit: "km/h", value: scaled(edit(\.startSpeed, "Change Start Speed"), 3.6), width: 90)
            }
        }
    }

    private func openEditor(_ request: TrackEditorRequest) {
        editorStart = app.lapSim.track
        editor = request
    }

    /// A setup value, undoable as `name`
    private func edit<V: Equatable>(_ key: WritableKeyPath<LapSimSetup, V>, _ name: String) -> Binding<V> {
        Binding(get: { app.lapSim[keyPath: key] }, set: { app.lapSim[keyPath: key] = $0 }).undoable(undo, name)
    }

    private func scaled(_ binding: Binding<Double>, _ scale: Double) -> Binding<Double> {
        Binding(get: { binding.wrappedValue * scale }, set: { binding.wrappedValue = $0 / scale })
    }

    static func trackTitle(_ kind: LapSimTrackKind) -> String {
        switch kind {
        case .endurance: "Estimated endurance lap (about 1 km)"
        case .autocross: "Estimated autocross (standing start)"
        case .fsg: "FSG Hockenheim, trackdrive (309 m)"
        case .fsi: "FSI Varano, trackdrive (218 m)"
        case .testTrack: "Test track (synthetic)"
        case .skidpad: "Skidpad"
        case .acceleration: "Acceleration"
        case .csv: "Imported CSV"
        case .drawn: "Drawn"
        }
    }

    /// Where the track comes from, for How it's calculated
    static func trackNote(_ kind: LapSimTrackKind) -> String? {
        switch kind {
        case .endurance, .autocross:
            "Generated layouts follow the 2027 FS rules for the event (straights under 80 m, a slalom at the rules' cone spacing, nothing tighter than the 9 m turning diameter, about 1 km for endurance), with corners like the FSG and FSI layouts but a little more open. The same layout number always gives the same track. For comparing cars on a typical layout, not predicting an event time."
        case .testTrack: "The test track is a closed loop of about 381 m with a 12.4 m tightest radius, for checking the sim."
        case .fsg, .fsi:
            "FSG and FSI are the driverless trackdrive courses from AMZ's fssim simulator (MIT licence), cone lines turned into a centreline. Shorter than an endurance lap: compare cars on them rather than predicting event times."
        default: nil
        }
    }
}

struct PlaceholderTag: View {
    /// A dot instead of "est." where columns are narrow (three or more cars).
    var compact = false

    var body: some View {
        Text(compact ? "●" : "est.")
            .font(.system(size: compact ? 6 : 11, weight: .medium))
            .foregroundStyle(S37.C.clayInk)
            .fixedSize()
            .accessibilityLabel("Placeholder estimate")
    }
}

/// Car parameters, one column per car (A to E).
struct CarGrid: View {
    @Environment(AppState.self) private var app
    /// The undoable binding for one car's field
    var edit: (CarField, Int) -> Binding<Double>

    var body: some View {
        let cars = app.lapSim.cars.indices
        // Narrower boxes as cars are added, so five still fit beside the labels.
        let width: CGFloat = cars.count > 3 ? 56 : cars.count > 2 ? 66 : 80
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("")
                ForEach(cars, id: \.self) { Text(LapSimSetup.labels[$0]).font(.system(size: 14, weight: .semibold)).gridColumnAlignment(.trailing) }
                Text("")
            }
            ForEach(CarField.all) { field in
                GridRow {
                    Text(field.label)
                    ForEach(cars, id: \.self) { cell(field, $0, width: width) }
                    Text(field.unit).font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.inkTertiary)
                }
            }
        }
        .font(.system(size: 14))
    }

    private func cell(_ field: CarField, _ car: Int, width: CGFloat) -> some View {
        let value = edit(field, car)
        let binding = Binding<Double>(get: { value.wrappedValue * field.scale }, set: { value.wrappedValue = $0 / field.scale })
        return HStack(spacing: 4) {
            if field.isPlaceholder(app.lapSim.cars[car]) { PlaceholderTag(compact: app.lapSim.cars.count > 2) }
            TextField(field.label, value: binding, format: .number)
                .textFieldStyle(.plain).labelsHidden()
                .multilineTextAlignment(.trailing).monospacedDigit()
                .padding(.horizontal, S37.Space.s2).frame(width: width, height: 24)
                .background(RoundedRectangle(cornerRadius: S37.Radius.sm, style: .continuous).fill(S37.C.recess))
        }
    }
}

// MARK: Results

struct LapSimResultsView: View {
    @Environment(AppState.self) private var app
    @State private var mapConfig = 0
    @State private var gainConfig = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LapSimRunBar().padding(S37.Space.s5)
            if let output = app.lapSimOutput {
                ScrollView {
                    VStack(alignment: .leading, spacing: S37.Space.s6) {
                        header(output)
                        SummaryGrid(result: output.result)
                        if output.result.a.sensitivity != nil {
                            SensitivityView(result: output.result)
                        }
                        chartBox("Speed") {
                            Chart(output.speed) { p in
                                LineMark(x: .value("Distance", p.s), y: .value("Speed", p.kmh))
                                    .foregroundStyle(by: .value("Config", p.config))
                            }
                            .chartXAxisLabel("Distance (m)")
                            .chartYAxisLabel("Speed (km/h)")
                            .chartForegroundStyleScale(range: S37.series)
                            .frame(height: 240)
                        }
                        if !output.delta.isEmpty {
                            chartBox("Time against A") {
                                Chart {
                                    RuleMark(y: .value("Zero", 0)).foregroundStyle(S37.C.inkTertiary)
                                    ForEach(output.delta) { p in
                                        LineMark(x: .value("Distance", p.s), y: .value("Δt", p.dt))
                                            .foregroundStyle(by: .value("Config", p.config))
                                    }
                                }
                                .chartXAxisLabel("Distance (m)")
                                .chartYAxisLabel("Car − A (s), negative means ahead of A")
                                .chartForegroundStyleScale(range: S37.series)
                                .frame(height: 200)
                            }
                        }
                        chartBox("Track map, coloured by speed") {
                            if output.labels.count > 1 {
                                carPicker($mapConfig, output.labels.indices)
                            }
                            TrackMap(output: output, points: output.maps[min(mapConfig, output.maps.count - 1)])
                        }
                        if output.labels.count > 1 {
                            let car = min(max(gainConfig, 1), output.labels.count - 1)
                            chartBox("Where \(output.labels[car]) gains and loses on A") {
                                if output.labels.count > 2 { carPicker($gainConfig, 1..<output.labels.count) }
                                if let gain = output.gains[car] { GainMap(gain: gain, output: output, label: output.labels[car]) }
                            }
                        }
                    }
                    .padding([.horizontal, .bottom], S37.Space.s5)
                }
            } else {
                S37EmptyState(title: "No lap times yet",
                              line: "Run the lap sim for times, speed traces and the track map.")
            }
        }
    }

    private func carPicker(_ selection: Binding<Int>, _ cars: Range<Int>) -> some View {
        S37Segmented(options: cars.map { ($0, LapSimSetup.labels[$0]) }, selection: selection).fixedSize()
    }

    private func header(_ output: LapSimOutput) -> some View {
        let track = output.result.track
        return VStack(alignment: .leading, spacing: 2) {
            Text(track.name).font(.system(size: 20, weight: .semibold))
            Text("\(track.length, format: .number.precision(.fractionLength(1))) m, \(track.closed ? "closed loop, flying lap" : "open, standing start"), step \(track.ds, format: .number.precision(.fractionLength(3))) m")
                .font(.system(size: 14)).foregroundStyle(S37.C.inkSecondary).monospacedDigit()
            Text("Job \(output.jobID)").font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(S37.C.inkTertiary)
        }
    }

    private func chartBox<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: S37.Space.s3) {
            Text(title).font(.system(size: 16, weight: .semibold))
            content()
        }
    }
}

struct TrackMap: View {
    let output: LapSimOutput
    let points: [LapSimOutput.MapPoint]

    var body: some View {
        VStack(alignment: .leading) {
            Chart(points) { p in
                PointMark(x: .value("x", p.x), y: .value("y", p.y))
                    .symbolSize(10)
                    .foregroundStyle(color(p.kmh))
            }
            .chartXScale(domain: output.xDomain)
            .chartYScale(domain: output.yDomain)
            .chartXAxisLabel("x (m)")
            .chartYAxisLabel("y (m)")
            .aspectRatio(1, contentMode: .fit)
            .frame(maxHeight: 420)
            HStack(spacing: 6) {
                Text("\(output.kmhRange.lowerBound, format: .number.precision(.fractionLength(0))) km/h")
                LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
                    .frame(width: 160, height: 8)
                    .clipShape(Capsule())
                Text("\(output.kmhRange.upperBound, format: .number.precision(.fractionLength(0))) km/h")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(S37.C.inkSecondary)
        }
    }

    // Blue (slow) through to red (fast). A crude v1 colormap.
    private var stops: [Color] { stride(from: 0.0, through: 1.0, by: 0.25).map(hue) }

    private func color(_ kmh: Double) -> Color {
        let r = output.kmhRange
        return hue((kmh - r.lowerBound) / (r.upperBound - r.lowerBound))
    }

    private func hue(_ f: Double) -> Color {
        Color(hue: 0.66 * (1 - min(max(f, 0), 1)), saturation: 0.85, brightness: 0.9)
    }
}

struct SummaryGrid: View {
    let result: LapSimResult

    var body: some View {
        let configs = NamedConfig.list(result)
        Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 6) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                ForEach(configs) { Text($0.id).font(.system(size: 14, weight: .semibold)) }
            }
            Divider()
            row("Lap time", configs) { seconds($0.lapTime) }
            if configs.count > 1 {
                GridRow {
                    Text("Δ against A").gridColumnAlignment(.leading)
                    ForEach(configs) { named in
                        if named.id == "A" {
                            Text("")
                        } else {
                            Text(signed(named.config.lapTime - result.a.lapTime) + " s")
                                .foregroundStyle(named.config.lapTime <= result.a.lapTime ? S37.C.sageInk : S37.C.critical)
                        }
                    }
                }
            }
            row("Average speed", configs) { kmh($0.vAvg) }
            row("Minimum speed", configs) { kmh($0.vMin) }
            row("Maximum speed", configs) { kmh($0.vMax) }
            row("Drive energy per lap", configs) { "\(($0.energy / 1000).formatted(.number.precision(.fractionLength(1)))) kJ" }
            if result.track.closed {
                Divider()
                row("Endurance, \(result.a.endurance.laps) laps", configs) { clock($0.endurance.time) }
                row("Endurance energy", configs) { "\(($0.endurance.energy / 3.6e6).formatted(.number.precision(.fractionLength(2)))) kWh" }
            }
        }
        .font(.body.monospacedDigit())
    }

    private func row(_ label: String, _ configs: [NamedConfig], _ value: @escaping (LapSimResult.Config) -> String) -> some View {
        GridRow {
            Text(label).gridColumnAlignment(.leading)
            ForEach(configs) { Text(value($0.config)) }
        }
    }

    private func seconds(_ t: Double) -> String { "\(t.formatted(.number.precision(.fractionLength(3)))) s" }
    private func kmh(_ v: Double) -> String { "\((v * 3.6).formatted(.number.precision(.fractionLength(1)))) km/h" }
    private func signed(_ x: Double) -> String { (x >= 0 ? "+" : "") + x.formatted(.number.precision(.fractionLength(3))) }
    private func clock(_ t: Double) -> String {
        let m = Int(t) / 60
        let s = t - Double(m * 60)
        return "\(m):\(s < 10 ? "0" : "")\(s.formatted(.number.precision(.fractionLength(1))))"
    }
}

struct SensitivityView: View {
    let result: LapSimResult

    var body: some View {
        let configs = NamedConfig.list(result)
        VStack(alignment: .leading, spacing: S37.Space.s3) {
            Text("Sensitivities").font(.system(size: 16, weight: .semibold))
            Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    ForEach(configs) { Text($0.id).font(.system(size: 14, weight: .semibold)) }
                }
                Divider()
                GridRow {
                    Text("∂t/∂ClA").gridColumnAlignment(.leading)
                    ForEach(configs) { Text(value($0.config.sensitivity?.dtDcla, unit: "s per m²")) }
                }
                GridRow {
                    Text("∂t/∂CdA").gridColumnAlignment(.leading)
                    ForEach(configs) { Text(value($0.config.sensitivity?.dtDcda, unit: "s per m²")) }
                }
                GridRow {
                    Text("ClA worth 1 m² CdA").gridColumnAlignment(.leading)
                    ForEach(configs) { named in
                        if let rate = named.config.sensitivity?.claPerCda {
                            Text("\(rate.formatted(.number.precision(.fractionLength(3)))) m²")
                        } else {
                            Text("n/a").help("Downforce does not change lap time on this track")
                        }
                    }
                }
            }
            .font(.body.monospacedDigit())
            Text("A device with ΔClA/ΔCdA above ClA worth 1 m² CdA gains lap time here.")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func value(_ x: Double?, unit: String) -> String {
        guard let x else { return "–" }
        return "\(x.formatted(.number.precision(.fractionLength(4)))) \(unit)"
    }
}

struct NamedConfig: Identifiable {
    let id: String
    let config: LapSimResult.Config

    static func list(_ result: LapSimResult) -> [NamedConfig] {
        zip(LapSimSetup.labels, result.configs).map { NamedConfig(id: $0, config: $1) }
    }
}

/// The track coloured by how fast one car gains (green) or loses (red) time on A.
struct GainMap: View {
    let gain: LapSimOutput.Gain
    let output: LapSimOutput
    let label: String

    var body: some View {
        VStack(alignment: .leading) {
            Chart(gain.points) { p in
                PointMark(x: .value("x", p.x), y: .value("y", p.y))
                    .symbolSize(12)
                    .foregroundStyle(color(p.rate))
            }
            .chartXScale(domain: output.xDomain)
            .chartYScale(domain: output.yDomain)
            .chartXAxisLabel("x (m)")
            .chartYAxisLabel("y (m)")
            .aspectRatio(1, contentMode: .fit)
            .frame(maxHeight: 420)
            HStack(spacing: 6) {
                Text(String(format: "%@ gains %.3f s/100 m", label, gain.limit))
                LinearGradient(colors: [color(-gain.limit), color(0), color(gain.limit)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 160, height: 8)
                    .clipShape(Capsule())
                Text(String(format: "%@ loses %.3f s/100 m", label, gain.limit))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(S37.C.inkSecondary)
        }
    }

    /// Green where the car gains, grey where it matches A, red where it loses.
    private func color(_ rate: Double) -> Color {
        let f = min(max(rate / gain.limit, -1), 1)
        let grey = 0.6
        return f < 0
            ? Color(red: grey * (1 + f), green: grey + (0.75 - grey) * -f, blue: grey * (1 + f))
            : Color(red: grey + (0.85 - grey) * f, green: grey * (1 - f), blue: grey * (1 - f))
    }
}

/// Run Lap Sim, its progress and what went wrong, at the top of the results
struct LapSimRunBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: S37.Space.s2) {
            HStack(spacing: S37.Space.s3) {
                Button("Run lap sim") { app.runLapSim() }
                    .buttonStyle(S37ButtonStyle(kind: .prominent))
                    .disabled(app.lapSimRunning)
                if let job = app.lapSimJob, !job.status.isFinished {
                    ProgressView(value: job.progress, total: 100).frame(maxWidth: 160)
                    Button("Cancel") { app.jobs.cancel(job) }.buttonStyle(S37ButtonStyle(kind: .plain))
                }
            }
            if let job = app.lapSimJob, job.status == .failed || job.status == .cancelled {
                Label(job.message ?? job.status.rawValue, systemImage: "xmark.octagon")
                    .foregroundStyle(S37.C.critical)
                    .textSelection(.enabled)
                if let detail = job.detail {
                    Text(detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(S37.C.inkSecondary)
                        .lineLimit(6).textSelection(.enabled)
                }
            }
        }
    }
}
