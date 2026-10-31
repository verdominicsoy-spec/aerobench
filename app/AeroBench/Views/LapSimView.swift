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

    var body: some View {
        @Bindable var app = app
        let setup = app.lapSim
        let usesPlaceholders = CarField.all.contains { field in setup.cars.contains { field.isPlaceholder($0) } }

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
                    Text("Estimated endurance lap (about 1 km)").tag(LapSimTrackKind.endurance)
                    Text("Estimated autocross (standing start)").tag(LapSimTrackKind.autocross)
                    Text("FSG Hockenheim, trackdrive (309 m)").tag(LapSimTrackKind.fsg)
                    Text("FSI Varano, trackdrive (218 m)").tag(LapSimTrackKind.fsi)
                    Text("Test track (synthetic)").tag(LapSimTrackKind.testTrack)
                    Text("Skidpad").tag(LapSimTrackKind.skidpad)
                    Text("Acceleration").tag(LapSimTrackKind.acceleration)
                    Text("Imported CSV").tag(LapSimTrackKind.csv)
                }
                switch setup.track.kind {
                case .endurance, .autocross:
                    HStack {
                        Stepper("Layout \(setup.track.seed)", value: $app.lapSim.track.seed, in: 1...9999)
                        Spacer()
                        Button("Another Layout") { app.lapSim.track.seed += 1 }
                    }
                    Text("Generated within the 2027 FS rules for the event (straights under 80 m, a slalom at the rules' cone spacing, nothing tighter than the 9 m turning diameter, about 1 km for endurance), with corners like the FSG and FSI layouts but a little more open. The same number always gives the same track. For comparing cars on a typical layout, not predicting an event time.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                case .testTrack:
                    Text("Closed loop of about 381 m with a 12.4 m tightest radius. For checking the sim, not a real event.")
                        .font(.caption).foregroundStyle(.secondary)
                case .fsg, .fsi:
                    Text("A real event layout: the driverless trackdrive course from AMZ's fssim simulator (MIT licence), cone lines turned into a centreline. Shorter than an endurance lap, so compare cars on it rather than predicting event times.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                Stepper("Cars: \(setup.cars.count)", value: Binding(get: { setup.cars.count }, set: { n in
                    // A new car starts as a copy of A; fewer drops the last.
                    while app.lapSim.cars.count < n { app.lapSim.cars.append(app.lapSim.carA) }
                    app.lapSim.cars = Array(app.lapSim.cars.prefix(n))
                }), in: 1...LapSimSetup.maxCars)
                .help("A, and up to four more to compare with it. Wing Lab can put a wing in any of them.")
                CarGrid()
                HStack {
                    if setup.cars.count > 1 {
                        Button("Copy A to the Others") {
                            app.lapSim.cars = Array(repeating: app.lapSim.carA, count: app.lapSim.cars.count)
                        }
                    }
                    Spacer()
                    Button("Reset to placeholders") {
                        app.lapSim.cars = Array(repeating: .placeholder, count: app.lapSim.cars.count)
                    }
                }
            } header: {
                Text("Car")
            } footer: {
                Text("With a CoG height or a tyre load sensitivity, each axle holds its own share of the cornering force with its own load, so the downforce balance against the weight split matters; the rear (driven) axle gains weight under acceleration. All four at 0 is the plain point mass.")
            }

            Section("Simulation") {
                NumberRow(label: "Resampling step", unit: "m", value: $app.lapSim.ds, isDefault: false)
                Stepper("Endurance laps: \(setup.enduranceLaps)", value: $app.lapSim.enduranceLaps, in: 1...200)
                Toggle("ClA and CdA sensitivities", isOn: $app.lapSim.sensitivities)
            }

            Section {
                HStack {
                    Button("Run Lap Sim") { app.runLapSim() }
                        .buttonStyle(S37ButtonStyle(kind: .prominent))
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
    /// A dot instead of "est." where columns are narrow (three or more cars).
    var compact = false

    var body: some View {
        Text(compact ? "●" : "est.")
            .font(compact ? .system(size: 6) : .caption2)
            .foregroundStyle(.orange)
            .fixedSize()
            .help("Placeholder estimate, not team data")
    }
}

/// Car parameters, one column per car (A to E).
struct CarGrid: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let cars = app.lapSim.cars.indices
        // Narrower boxes as cars are added, so five still fit beside the labels.
        let width: CGFloat = cars.count > 3 ? 56 : cars.count > 2 ? 66 : 80
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("")
                ForEach(cars, id: \.self) { Text(LapSimSetup.labels[$0]).bold().gridColumnAlignment(.trailing) }
                Text("")
            }
            ForEach(CarField.all) { field in
                GridRow {
                    Text(field.label)
                    ForEach(cars, id: \.self) { cell(field, $0, width: width) }
                    Text(field.unit).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func cell(_ field: CarField, _ car: Int, width: CGFloat) -> some View {
        let binding = Binding<Double>(
            get: { app.lapSim.cars[car][keyPath: field.keyPath] * field.scale },
            set: { app.lapSim.cars[car][keyPath: field.keyPath] = $0 / field.scale }
        )
        return HStack(spacing: 4) {
            if field.isPlaceholder(app.lapSim.cars[car]) { PlaceholderTag(compact: app.lapSim.cars.count > 2) }
            TextField(field.label, value: binding, format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: width)
        }
    }
}

// MARK: Results

struct LapSimResultsView: View {
    @Environment(AppState.self) private var app
    @State private var mapConfig = 0
    @State private var gainConfig = 1

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
                    if !output.delta.isEmpty {
                        chartBox("Time against A") {
                            Chart {
                                RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary)
                                ForEach(output.delta) { p in
                                    LineMark(x: .value("Distance", p.s), y: .value("Δt", p.dt))
                                        .foregroundStyle(by: .value("Config", p.config))
                                }
                            }
                            .chartXAxisLabel("Distance (m)")
                            .chartYAxisLabel("Car − A (s), negative means ahead of A")
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
                .padding()
            }
        } else {
            ContentUnavailableView {
                Label("No Lap Sim Results", systemImage: "flag.checkered")
            } description: {
                Text("Pick a track and check the car values on the left, then run it (⌘R). The track map shows here.")
            } actions: {
                Button("Run Lap Sim") { app.runLapSim() }
                    .buttonStyle(S37ButtonStyle(kind: .prominent))
                    .disabled(app.lapSimJob.map { !$0.status.isFinished } ?? false)
            }
        }
    }

    private func carPicker(_ selection: Binding<Int>, _ cars: Range<Int>) -> some View {
        Picker("Car", selection: selection) {
            ForEach(cars, id: \.self) { Text(LapSimSetup.labels[$0]).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
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
            if configs.count > 1 {
                GridRow {
                    Text("Δ against A").gridColumnAlignment(.leading)
                    ForEach(configs) { named in
                        if named.id == "A" {
                            Text("")
                        } else {
                            Text(signed(named.config.lapTime - result.a.lapTime) + " s")
                                .foregroundStyle(named.config.lapTime <= result.a.lapTime ? .green : .red)
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
            .font(.caption)
            .foregroundStyle(.secondary)
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
