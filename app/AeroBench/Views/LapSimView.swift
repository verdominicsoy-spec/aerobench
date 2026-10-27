import AeroBenchKit
import AppKit
import Charts
import SwiftUI

struct LapSimView: View {
    var body: some View {
        HSplitView {
            LapSimSetupView()
                .frame(minWidth: 400, idealWidth: 440, maxWidth: 560)
            LapSimResultsView()
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
    ]

    func isPlaceholder(_ car: CarParameters) -> Bool {
        let a = car[keyPath: keyPath]
        let b = CarParameters.placeholder[keyPath: keyPath]
        return abs(a - b) <= 1e-9 * max(abs(b), 1)
    }
}

struct LapSimSetupView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        let setup = app.lapSim
        let usesPlaceholders = CarField.all.contains { $0.isPlaceholder(setup.carA) || (setup.compare && $0.isPlaceholder(setup.carB)) }

        Form {
            if usesPlaceholders {
                Section {
                    Label("Values marked est. are placeholder estimates, not team data. Every value here is editable and saved with the project.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("Track") {
                Picker("Track", selection: $app.lapSim.track.kind) {
                    Text("Test track (synthetic)").tag(LapSimTrackKind.testTrack)
                    Text("Skidpad").tag(LapSimTrackKind.skidpad)
                    Text("Acceleration").tag(LapSimTrackKind.acceleration)
                    Text("Imported CSV").tag(LapSimTrackKind.csv)
                }
                switch setup.track.kind {
                case .testTrack:
                    Text("Closed loop of about 381 m with a 12.4 m tightest radius. For checking the sim, not a real event.")
                        .font(.caption).foregroundStyle(.secondary)
                case .skidpad:
                    NumberRow(label: "Centreline radius", unit: "m", value: $app.lapSim.track.skidpadRadius,
                              isDefault: setup.track.skidpadRadius == LapSimTrack.defaultSkidpadRadius)
                case .acceleration:
                    NumberRow(label: "Length", unit: "m", value: $app.lapSim.track.accelerationLength,
                              isDefault: setup.track.accelerationLength == LapSimTrack.defaultAccelerationLength)
                    NumberRow(label: "Start speed", unit: "km/h", value: scaled($app.lapSim.startSpeed, 3.6), isDefault: false)
                case .csv:
                    LabeledContent("File") {
                        HStack {
                            Text(setup.track.csvPath.map { ($0 as NSString).lastPathComponent } ?? "none")
                                .lineLimit(1).truncationMode(.middle)
                            Button("Import…") { app.importTrackCSV() }
                        }
                    }
                    Picker("Loop", selection: $app.lapSim.track.csvClosed) {
                        Text("Detect").tag(Bool?.none)
                        Text("Closed").tag(Bool?.some(true))
                        Text("Open").tag(Bool?.some(false))
                    }
                    Picker("File units", selection: $app.lapSim.track.csvScale) {
                        Text("m").tag(1.0)
                        Text("mm").tag(0.001)
                    }
                    NumberRow(label: "Point scatter (smoothing)", unit: "m", value: $app.lapSim.track.smoothing, isDefault: false)
                    NumberRow(label: "Start speed (open tracks)", unit: "km/h", value: scaled($app.lapSim.startSpeed, 3.6), isDefault: false)
                }
            }

            Section {
                Toggle("Compare with config B", isOn: $app.lapSim.compare)
                CarGrid(compare: setup.compare)
                HStack {
                    if setup.compare {
                        Button("Copy A to B") { app.lapSim.carB = app.lapSim.carA }
                    }
                    Spacer()
                    Button("Reset to placeholders") {
                        app.lapSim.carA = .placeholder
                        app.lapSim.carB = .placeholder
                    }
                }
            } header: {
                Text("Car")
            }

            Section("Simulation") {
                NumberRow(label: "Resampling step", unit: "m", value: $app.lapSim.ds, isDefault: false)
                Stepper("Endurance laps: \(setup.enduranceLaps)", value: $app.lapSim.enduranceLaps, in: 1...200)
                Toggle("ClA and CdA sensitivities", isOn: $app.lapSim.sensitivities)
            }

            Section {
                HStack {
                    Button("Run Lap Sim") { app.runLapSim() }
                        .keyboardShortcut("r")
                        .disabled(isRunning)
                    if let job = app.lapSimJob, !job.status.isFinished {
                        ProgressView(value: job.progress, total: 100).frame(maxWidth: 160)
                        Button("Cancel") { app.jobs.cancel(job) }
                    }
                }
                if let job = app.lapSimJob, job.status == .failed || job.status == .cancelled {
                    Label(job.message ?? job.status.rawValue, systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    if let detail = job.detail {
                        Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var isRunning: Bool {
        guard let job = app.lapSimJob else { return false }
        return !job.status.isFinished
    }

    private func scaled(_ binding: Binding<Double>, _ scale: Double) -> Binding<Double> {
        Binding(get: { binding.wrappedValue * scale }, set: { binding.wrappedValue = $0 / scale })
    }
}

struct NumberRow: View {
    let label: String
    let unit: String
    @Binding var value: Double
    let isDefault: Bool

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                if isDefault { PlaceholderTag() }
                TextField(label, value: $value, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Text(unit).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            }
        } label: {
            Text(label)
        }
    }
}

struct PlaceholderTag: View {
    var body: some View {
        Text("est.")
            .font(.caption2)
            .foregroundStyle(.orange)
            .help("Placeholder estimate, not team data")
    }
}

/// Car parameters, A and optionally B side by side.
struct CarGrid: View {
    @Environment(AppState.self) private var app
    let compare: Bool

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("")
                Text("A").bold().gridColumnAlignment(.trailing)
                if compare { Text("B").bold().gridColumnAlignment(.trailing) }
                Text("")
            }
            ForEach(CarField.all) { field in
                GridRow {
                    Text(field.label)
                    cell(field, \.carA)
                    if compare { cell(field, \.carB) }
                    Text(field.unit).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func cell(_ field: CarField, _ car: WritableKeyPath<LapSimSetup, CarParameters>) -> some View {
        let binding = Binding<Double>(
            get: { app.lapSim[keyPath: car][keyPath: field.keyPath] * field.scale },
            set: { app.lapSim[keyPath: car][keyPath: field.keyPath] = $0 / field.scale }
        )
        return HStack(spacing: 4) {
            if field.isPlaceholder(app.lapSim[keyPath: car]) { PlaceholderTag() }
            TextField(field.label, value: binding, format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
        }
    }
}

// MARK: Results

struct LapSimResultsView: View {
    @Environment(AppState.self) private var app
    @State private var mapConfig = "A"

    var body: some View {
        if let output = app.lapSimOutput {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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
                        .frame(height: 240)
                    }
                    chartBox("Track map, coloured by speed") {
                        if output.result.b != nil {
                            Picker("Config", selection: $mapConfig) {
                                Text("A").tag("A")
                                Text("B").tag("B")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 120)
                        }
                        TrackMap(output: output, points: mapConfig == "B" && output.result.b != nil ? output.mapB : output.mapA)
                    }
                    if !output.delta.isEmpty {
                        chartBox("Time delta, B minus A") {
                            Chart {
                                RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary)
                                ForEach(output.delta) { p in
                                    LineMark(x: .value("Distance", p.s), y: .value("Δt", p.dt))
                                }
                            }
                            .chartXAxisLabel("Distance (m)")
                            .chartYAxisLabel("B − A (s), negative means B is ahead")
                            .frame(height: 200)
                        }
                    }
                }
                .padding()
            }
        } else {
            ContentUnavailableView("No Lap Sim Results", systemImage: "flag.checkered",
                                   description: Text("Pick a track, check the car values and press Run Lap Sim (⌘R)."))
        }
    }

    private func header(_ output: LapSimOutput) -> some View {
        let track = output.result.track
        return VStack(alignment: .leading, spacing: 2) {
            Text(track.name).font(.title2).bold()
            Text("\(track.length, format: .number.precision(.fractionLength(1))) m, \(track.closed ? "closed loop, flying lap" : "open, standing start"), step \(track.ds, format: .number.precision(.fractionLength(3))) m")
                .foregroundStyle(.secondary)
            Text("Job \(output.jobID)").font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    private func chartBox<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(4)
        } label: {
            Text(title).bold()
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
            .font(.caption)
            .foregroundStyle(.secondary)
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
                ForEach(configs) { Text($0.id).bold() }
            }
            Divider()
            row("Lap time", configs) { seconds($0.lapTime) }
            if let b = result.b {
                GridRow {
                    Text("Δ B − A").gridColumnAlignment(.leading)
                    Text("")
                    Text(signed(b.lapTime - result.a.lapTime) + " s")
                        .foregroundStyle(b.lapTime <= result.a.lapTime ? .green : .red)
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
        GroupBox {
            Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    ForEach(configs) { Text($0.id).bold() }
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
            Text("Exchange rate: at equal lap time, one extra m² of CdA is paid for by this much extra ClA. A device with ΔClA/ΔCdA above it gains lap time here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Sensitivities").bold()
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
        var out = [NamedConfig(id: "A", config: result.a)]
        if let b = result.b { out.append(NamedConfig(id: "B", config: b)) }
        return out
    }
}
