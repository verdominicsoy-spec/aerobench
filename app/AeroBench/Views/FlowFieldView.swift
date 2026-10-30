import AeroBench3D
import AeroBenchKit
import AppKit
import SwiftUI

struct FlowFieldView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var flow = app.flow
        VStack(spacing: 0) {
            HStack {
                Picker("Mode", selection: $flow.mode) {
                    ForEach(FlowFieldModel.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Spacer()
                if let url = flow.sourceURL {
                    Text(url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            switch flow.mode {
            case .calibrate: FlowCalibrateView()
            case .explore: FlowExploreView()
            }
        }
    }
}

// MARK: Calibrate

struct FlowCalibrateView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var flow = app.flow
        HSplitView {
            VStack(spacing: 0) {
                Picker("Setup", selection: $flow.showAllSettings) {
                    Text("Quick Setup").tag(false)
                    Text("All Settings").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
                if flow.showAllSettings {
                    FlowCalibrationPanel()
                } else {
                    FlowQuickSetupPanel()
                }
            }
            .frame(minWidth: 340, idealWidth: 400, maxWidth: 500)
            FlowFramePane()
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// mm in the UI, metres in the calibration.
func mm(_ get: @escaping () -> Double, _ set: @escaping (Double) -> Void) -> Binding<Double> {
    Binding(get: { get() * 1000 }, set: { set($0 / 1000) })
}

struct FlowCalibrationPanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var flow = app.flow
        let cal = flow.calibration
        Form {
            Section {
                HStack {
                    Button("Open Video…") { app.openFlowSourcePanel() }
                    Menu("Demo Sweep") {
                        Button("Front View") { app.runFlowDemo(view: "front") }
                        Button("Rear View") { app.runFlowDemo(view: "rear") }
                        Button("Side View") { app.runFlowDemo(view: "side") }
                    }
                    .fixedSize()
                    .help("A synthetic sweep with a known answer and a matching calibration")
                }
                if let error = flow.loadError {
                    Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
                }
                if flow.frameCount > 0 {
                    LabeledContent("Frames", value: "\(flow.frameCount), \(Int(flow.frameSize.width)) × \(Int(flow.frameSize.height))")
                }
                if flow.isVideo { VideoTiming() }
                DisclosureGroup("Capture guide") { CaptureGuide() }
            } header: {
                Text("Source")
            }

            Section {
                HStack {
                    Button("Auto-detect") { app.autoDetectFlow() }
                        .disabled(flow.sourceURL == nil || isRunning(flow.detectJob))
                        .help("Finds the plot, the legend, labels and axis triad to exclude, the legend bar and the ground, from frames across the sweep")
                    Button(cal.crop == nil ? "Draw Crop" : "Redraw Crop") { flow.tool = .crop }
                    Button("Add Exclusion") { flow.tool = .exclude }
                }
                if let job = flow.detectJob, !job.status.isFinished || job.status == .failed {
                    JobInlineStatus(job: job)
                }
                ForEach(flow.detectNotes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(cal.exclude.enumerated()), id: \.offset) { i, r in
                    HStack {
                        Text("Exclusion \(i + 1): \(Int(r[2] - r[0])) × \(Int(r[3] - r[1])) px").font(.caption)
                        Spacer()
                        Button("Remove") { flow.calibration.exclude.remove(at: i) }.buttonStyle(.link)
                    }
                }
            } header: {
                Text("1  Crop and exclusions")
            } footer: {
                Text("Crop to the plot region. Exclude anything drawn over it: the legend, the axis triad, labels. Auto-detect does all of this; check the boxes on the frame afterwards.")
            }

            Section("2  Colour map") {
                Picker("Source", selection: Binding(
                    get: { cal.colormap.legend == nil ? (cal.colormap.preset ?? "star_blue_yellow_red") : "legend" },
                    set: { value in
                        if value == "legend" {
                            flow.tool = .legend
                        } else {
                            flow.calibration.colormap = .init(preset: value, legend: nil)
                        }
                    })) {
                    Text("STAR-CCM+ blue-yellow-red").tag("star_blue_yellow_red")
                    Text("Viridis").tag("viridis")
                    Text("Jet").tag("jet")
                    Text("Rainbow").tag("rainbow")
                    Text("Sample the legend…").tag("legend")
                }
                if let legend = cal.colormap.legend {
                    Text("Sampled along a line on frame \(legend.frame)").font(.caption).foregroundStyle(.secondary)
                    Button("Redraw Legend Line") { flow.tool = .legend }
                }
            }

            Section("3  Value range") {
                NumberField(label: "Low end", value: Binding(get: { cal.valueRange.first ?? -1 }, set: { flow.calibration.valueRange[0] = $0 }))
                NumberField(label: "High end", value: Binding(get: { cal.valueRange.last ?? 1 }, set: { flow.calibration.valueRange[1] = $0 }))
            }

            Section {
                let axes = cal.axes
                HStack {
                    Picker("Right in the frame", selection: $flow.calibration.axes.right) {
                        ForEach(FlowCalibration.Axes.choices, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Up", selection: $flow.calibration.axes.up) {
                        ForEach(FlowCalibration.Axes.choices, id: \.self) { Text($0).tag($0) }
                    }
                }
                Text(axes.isValid ? "Planes step along \(axes.sweepLetter). Read the axes off STAR's triad: rear view +y / +z, front view −y / +z, side view +x / +z (car facing left) or −x / +z."
                                  : "Right and up must be different axes.")
                    .font(.caption).foregroundStyle(axes.isValid ? Color.secondary : Color.orange)
                Toggle("Track the ground line", isOn: $flow.calibration.ground.track)
                    .disabled(axes.up != "+z")
                    .help("Finds where the ground meets the flow in every frame and pins z = 0 to it, so the planes cannot drift.")
                if cal.ground.track {
                    NumberField(label: "Ground line is at z", unit: "mm", value: mm({ cal.ground.level }, { flow.calibration.ground.level = $0 }))
                }
                Picker("Method", selection: $flow.calibration.spatial.mode) {
                    Text("Two points of known position").tag("points")
                    Text("Crop size").tag("size")
                }
                if cal.spatial.mode == "points" {
                    ForEach(0..<max(cal.spatial.frames.count, 1), id: \.self) { slot in
                        CalFrameEditor(slot: slot, perspective: cal.spatial.frames.count == 2)
                    }
                    Toggle(cal.ground.track ? "Also calibrate a second frame (corrects sideways drift)" : "Perspective camera (calibrate a second frame)", isOn: Binding(
                        get: { cal.spatial.frames.count == 2 },
                        set: { on in
                            if on {
                                flow.ensureSpatialSlot(1)
                            } else if flow.calibration.spatial.frames.count > 1 {
                                flow.calibration.spatial.frames.removeLast()
                            }
                        }))
                } else {
                    NumberField(label: "Crop width", unit: "mm", value: mm({ cal.spatial.width ?? 1 }, { v in
                        flow.calibration.spatial.width = v
                        flow.calibration.spatial.height = nil  // pixels are square: the height follows
                    }))
                    if let crop = cal.crop, let width = cal.spatial.width, width > 0, crop[2] > crop[0] {
                        LabeledContent("Crop height", value: "\(Int((width * (crop[3] - crop[1]) / (crop[2] - crop[0]) * 1000).rounded())) mm")
                            .help("Pixels are square, so the height follows from the width")
                    }
                    NumberField(label: "Bottom-left \(cal.axes.rightLetter)", unit: "mm", value: mm({ cal.spatial.origin?.first ?? 0 }, { v in
                        var o = flow.calibration.spatial.origin ?? [0, 0]; o[0] = v; flow.calibration.spatial.origin = o }))
                    NumberField(label: "Bottom-left \(cal.axes.upLetter)", unit: "mm", value: mm({ cal.spatial.origin?.last ?? 0 }, { v in
                        var o = flow.calibration.spatial.origin ?? [0, 0]; o[1] = v; flow.calibration.spatial.origin = o }))
                }
                Picker("Grid covers", selection: $flow.calibration.extent) {
                    Text("Around the flow (automatic)").tag("auto")
                    Text("Everything any frame sees").tag("all")
                    Text("Only what every frame sees").tag("common")
                }
                Toggle("Limit to a window", isOn: Binding(
                    get: { cal.window != nil },
                    set: { flow.calibration.window = $0 ? [-0.9, 0.9, 0, 1] : nil }))
                if let w = cal.window {
                    NumberField(label: "\(cal.axes.rightLetter) from", unit: "mm", value: mm({ w[0] }, { flow.calibration.window?[0] = $0 }))
                    NumberField(label: "\(cal.axes.rightLetter) to", unit: "mm", value: mm({ w[1] }, { flow.calibration.window?[1] = $0 }))
                    NumberField(label: "\(cal.axes.upLetter) from", unit: "mm", value: mm({ w[2] }, { flow.calibration.window?[2] = $0 }))
                    NumberField(label: "\(cal.axes.upLetter) to", unit: "mm", value: mm({ w[3] }, { flow.calibration.window?[3] = $0 }))
                }
            } header: {
                Text("4  Scale")
            } footer: {
                Text(cal.ground.track
                     ? "Click two points whose \(cal.axes.rightLetter), \(cal.axes.upLetter) you know on one frame. The ground line then sets the scale and height of every other frame (a perspective camera makes later planes look smaller)."
                     : "Click two points whose \(cal.axes.rightLetter), \(cal.axes.upLetter) you know. A perspective camera makes later planes look smaller: calibrate the first and last frames and the scale in between follows the pinhole model, or track the ground line instead.")
            }

            Section("5  Plane positions") {
                Picker("Spacing", selection: $flow.calibration.planes.mode) {
                    Text("Even, start to end").tag("linear")
                    Text("From CSV, one per frame").tag("csv")
                    Text("From the camera's view angle").tag("camera")
                }
                if cal.planes.mode == "linear" {
                    NumberField(label: "\(cal.axes.sweepLetter) at first frame", unit: "mm", value: mm({ cal.planes.start }, { flow.calibration.planes.start = $0 }))
                    NumberField(label: "\(cal.axes.sweepLetter) at last frame", unit: "mm", value: mm({ cal.planes.end }, { flow.calibration.planes.end = $0 }))
                } else if cal.planes.mode == "camera" {
                    NumberField(label: "\(cal.axes.sweepLetter) at first frame", unit: "mm", value: mm({ cal.planes.start }, { flow.calibration.planes.start = $0 }))
                    NumberField(label: "View angle", unit: "°", value: Binding(get: { cal.planes.viewAngle ?? 30 },
                                                                            set: { flow.calibration.planes.viewAngle = $0 }))
                    Picker("Angle spans the frame's", selection: Binding(get: { cal.planes.viewAngleAxis ?? "vertical" },
                                                                         set: { flow.calibration.planes.viewAngleAxis = $0 })) {
                        Text("Height").tag("vertical")
                        Text("Width").tag("horizontal")
                    }
                    Text("Each frame's scale, from the tracked ground line, gives its plane's distance from the camera; the view angle turns that into metres. Read the angle off STAR's view settings. Needs ground tracking and the whole frame as recorded (not cropped or zoomed).")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("\(cal.planes.positions?.count ?? 0) positions")
                        Spacer()
                        Button("Import CSV…") { app.importPlanePositionsCSV() }
                    }
                }
                HStack {
                    Stepper("First frame \(cal.planes.firstFrame)", value: $flow.calibration.planes.firstFrame, in: 0...max(flow.frameCount - 1, 0))
                    Button("Current") { flow.calibration.planes.firstFrame = flow.frameIndex }.buttonStyle(.link)
                }
                HStack {
                    Stepper("Last frame \(cal.planes.lastFrame ?? max(flow.frameCount - 1, 0))",
                            value: Binding(get: { cal.planes.lastFrame ?? max(flow.frameCount - 1, 0) }, set: { flow.calibration.planes.lastFrame = $0 }),
                            in: 0...max(flow.frameCount - 1, 0))
                    Button("Current") { flow.calibration.planes.lastFrame = flow.frameIndex }.buttonStyle(.link)
                }
                Stepper("Use every \(cal.planes.stride == 1 ? "frame" : "\(cal.planes.stride) frames")", value: $flow.calibration.planes.stride, in: 1...30)
            }

            Section {
                HStack(spacing: 6) {
                    ForEach(Array(cal.maskColors.enumerated()), id: \.offset) { i, c in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(red: c[0] / 255, green: c[1] / 255, blue: c[2] / 255))
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary))
                            .frame(width: 22, height: 22)
                            .help("RGB \(Int(c[0])), \(Int(c[1])), \(Int(c[2])). Click to remove.")
                            .onTapGesture { flow.calibration.maskColors.remove(at: i) }
                    }
                    Button("Pick From Frame") { flow.tool = .maskColor }
                }
                NumberField(label: "Mask tolerance", unit: "ΔE", value: $flow.calibration.maskTolerance)
                NumberField(label: "Reject colours further than", unit: "ΔE", value: $flow.calibration.threshold)
                Stepper("Median filter \(cal.median <= 1 ? "off" : "\(cal.median) × \(cal.median)")", value: $flow.calibration.median, in: 1...7, step: 2)
                Picker("Detail", selection: $flow.calibration.detail) {
                    Text("Fixed width").tag(String?.none)
                    Text("Low").tag(String?.some("low"))
                    Text("Medium").tag(String?.some("medium"))
                    Text("High").tag(String?.some("high"))
                }
                .help("Low, Medium and High follow the video's own pixels (about 1.5 px a cell) up to 8, 30 or 100 million voxels.")
                if cal.detail == nil {
                    Stepper("Working width \(cal.workingWidth) cells", value: $flow.calibration.workingWidth, in: 64...1024, step: 64)
                }
            } header: {
                Text("6  Masks and filtering")
            } footer: {
                Text("Geometry and background colours become empty space. Click a swatch to remove it.")
            }

            Section("7  Run") {
                ForEach(cal.problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption) }
                HStack {
                    Button("Check This Frame") { app.checkFlowFrame() }
                        .disabled(flow.sourceURL == nil || !cal.problems.isEmpty)
                    Button("Reconstruct") { app.reconstructFlow() }
                        .keyboardShortcut("r")
                        .disabled(flow.sourceURL == nil || !cal.problems.isEmpty || isRunning(flow.reconstructJob))
                }
                if let job = flow.reconstructJob {
                    JobInlineStatus(job: job)
                }
                if let ground = flow.reconstructStats["ground"] as? [String: Any] {
                    ImpliedCameraNote(ground: ground, sweep: cal.axes.sweepLetter)
                }
                HStack {
                    Button("Save Calibration…") { app.saveFlowCalibrationAs() }
                    Button("Load…") { app.loadFlowCalibration() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func isRunning(_ job: JobItem?) -> Bool { job.map { !$0.status.isFinished } ?? false }
}

/// What the plane positions say about the camera, from the tracked ground
/// line: a view angle to compare with STAR's. Positions spaced wrongly would
/// stretch or squash the volume along the sweep.
struct ImpliedCameraNote: View {
    let ground: [String: Any]
    let sweep: String

    var body: some View {
        if let cam = ground["implied_camera"] as? [String: Any],
           let vertical = cam["view_angle_vertical_deg"] as? Double,
           let horizontal = cam["view_angle_horizontal_deg"] as? Double,
           let distance = cam["distance_to_first_plane_m"] as? Double {
            VStack(alignment: .leading, spacing: 2) {
                Text("These plane positions mean a camera view angle of \(vertical, format: .number.precision(.fractionLength(1)))° across the height (\(horizontal, format: .number.precision(.fractionLength(1)))° across the width), \(distance, format: .number.precision(.fractionLength(2))) m from the first plane. If STAR's view angle differs, the planes are spaced wrongly and the volume is stretched or squashed along \(sweep).")
                if cam["planes_run_away_from_camera"] as? Bool == false {
                    Text("The positions run towards the camera, but the planes get smaller, so they move away: swap the first and last positions, or check the axes.")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct NumberField: View {
    let label: String
    var unit: String = ""
    @Binding var value: Double

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField(label, value: $value, format: .number.precision(.fractionLength(0...4)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Text(unit).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            }
        }
    }
}

struct JobInlineStatus: View {
    @Environment(AppState.self) private var app
    let job: JobItem

    var body: some View {
        switch job.status {
        case .queued, .running:
            HStack {
                ProgressView(value: job.progress, total: 100)
                Text(job.progressMessage).font(.caption).lineLimit(1)
                Button("Cancel") { app.jobs.cancel(job) }
            }
        case .failed:
            VStack(alignment: .leading) {
                Label(job.message ?? "Failed", systemImage: "xmark.octagon").foregroundStyle(.red)
                if let d = job.detail { Text(d).font(.caption.monospaced()).lineLimit(4).textSelection(.enabled) }
            }
        case .cancelled:
            Label("Cancelled", systemImage: "stop.circle").foregroundStyle(.secondary)
        case .succeeded:
            Label("Done", systemImage: "checkmark.circle").foregroundStyle(.green)
        }
    }
}

/// One spatial calibration frame: which frame, two clicked points, their world positions.
struct CalFrameEditor: View {
    @Environment(AppState.self) private var app
    let slot: Int
    let perspective: Bool

    var body: some View {
        let flow = app.flow
        let frame = flow.calibration.spatial.frames[safe: slot]
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(perspective ? (slot == 0 ? "First calibration frame" : "Second calibration frame") : "Calibration frame").bold()
                Spacer()
                Text(frame.map { "frame \($0.frame)" } ?? "not set").foregroundStyle(.secondary)
            }
            ForEach(0..<2, id: \.self) { index in
                let point = frame?.points[safe: index]
                HStack {
                    Button(index == 0 ? "Click A" : "Click B") { flow.tool = .point(slot: slot, index: index) }
                    Text(point.flatMap { $0.px.count == 2 ? "\(Int($0.px[0])), \(Int($0.px[1])) px" : nil } ?? "–")
                        .font(.caption.monospacedDigit()).frame(width: 90, alignment: .leading)
                    TextField(flow.calibration.axes.rightLetter, value: worldBinding(index, 0), format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 64)
                    TextField(flow.calibration.axes.upLetter, value: worldBinding(index, 1), format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 64)
                    Text("mm").foregroundStyle(.secondary)
                }
            }
            if perspective {
                Text("Pick this frame with the frame slider before clicking.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func worldBinding(_ index: Int, _ axis: Int) -> Binding<Double> {
        let flow = app.flow
        return Binding(
            get: { (flow.calibration.spatial.frames[safe: slot]?.points[safe: index]?.world[safe: axis] ?? 0) * 1000 },
            set: { value in
                flow.ensureSpatialSlot(slot)
                var f = flow.calibration.spatial.frames[slot]
                while f.points.count < 2 { f.points.append(.init(px: [], world: [0, 0])) }
                var w = f.points[index].world
                while w.count < 2 { w.append(0) }
                w[axis] = value / 1000
                f.points[index].world = w
                flow.calibration.spatial.frames[slot] = f
            })
    }
}

struct FlowFramePane: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let flow = app.flow
        VStack(spacing: 0) {
            if flow.tool != .none {
                HStack {
                    Image(systemName: "hand.point.up.left")
                    Text(hint(flow.tool))
                    Spacer()
                    Button("Cancel") { flow.tool = .none }
                }
                .padding(8)
                .background(.yellow.opacity(0.2))
            }
            FrameCanvas()
            if flow.frameCount > 0 {
                HStack {
                    Button { Task { await flow.showFrame(flow.frameIndex - 1) } } label: { Image(systemName: "chevron.left") }
                    Slider(value: Binding(get: { Double(flow.frameIndex) },
                                          set: { v in Task { await flow.showFrame(Int(v.rounded())) } }),
                           in: 0...Double(max(flow.frameCount - 1, 1)))
                    Button { Task { await flow.showFrame(flow.frameIndex + 1) } } label: { Image(systemName: "chevron.right") }
                    Text("Frame \(flow.frameIndex) of \(flow.frameCount - 1)").font(.callout.monospacedDigit()).frame(width: 140)
                }
                .padding(8)
            }
            if let preview = flow.previewImage {
                Divider()
                HStack(alignment: .top, spacing: 12) {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .background(Color.gray.opacity(0.3))
                        .frame(maxHeight: 200)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Check, frame \(flow.previewStats["frame"] as? Int ?? flow.frameIndex)").bold()
                        if let dE = flow.previewStats["median_dE"] as? Double {
                            Text("Median colour distance \(dE, format: .number.precision(.fractionLength(1))) ΔE")
                        }
                        if let empty = flow.previewStats["empty_fraction"] as? Double {
                            Text("\(Int((empty * 100).rounded()))% empty")
                        }
                        if let lo = flow.previewStats["value_min"] as? Double, let hi = flow.previewStats["value_max"] as? Double {
                            Text("Values \(lo, format: .number.precision(.fractionLength(2))) to \(hi, format: .number.precision(.fractionLength(2)))")
                        }
                        if let ground = flow.previewStats["ground"] as? [String: Any],
                           let resid = ground["residual_median_px"] as? Double {
                            let camera = ground["camera"] as? String == "pinhole" ? "perspective camera" : "fixed camera"
                            Text("Ground line found, \(camera), fit within \(resid, format: .number.precision(.fractionLength(1))) px")
                        }
                        if let ground = flow.previewStats["ground"] as? [String: Any] {
                            ImpliedCameraNote(ground: ground, sweep: app.flow.calibration.axes.sweepLetter)
                        }
                        Text("Grey is empty. A median distance under about 5 ΔE means the colour map fits well; much higher, check the colour map and lighting.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Hide") { flow.previewImage = nil }.buttonStyle(.link)
                    }
                    .frame(maxWidth: 280, alignment: .leading)
                }
                .padding(8)
            } else if let job = flow.previewJob, !job.status.isFinished || job.status == .failed {
                Divider()
                JobInlineStatus(job: job).padding(8)
            }
        }
    }

    private func hint(_ tool: FrameTool) -> String {
        switch tool {
        case .crop: "Drag a rectangle around the plot region."
        case .exclude: "Drag a rectangle over something to ignore (legend, axes, labels)."
        case .legend: "Drag along the middle of the colour bar, from the low end to the high end."
        case .point(let slot, let index): "Click point \(index == 0 ? "A" : "B")\(app.flow.calibration.spatial.frames.count == 2 ? " on calibration frame \(slot + 1)" : "")."
        case .maskColor: "Click a pixel whose colour should count as empty (geometry, background)."
        case .measure: "Drag from one side of the thing you know the width of to the other. The line stays level."
        case .none: ""
        }
    }
}

/// Maps between view points and continuous image pixels (aspect fit).
struct FrameMapping {
    let imageSize: CGSize
    let viewSize: CGSize

    var scale: CGFloat { min(viewSize.width / imageSize.width, viewSize.height / imageSize.height) }
    var shown: CGSize { CGSize(width: imageSize.width * scale, height: imageSize.height * scale) }
    var origin: CGPoint { CGPoint(x: (viewSize.width - shown.width) / 2, y: (viewSize.height - shown.height) / 2) }

    func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max((p.x - origin.x) / scale, 0), imageSize.width), y: min(max((p.y - origin.y) / scale, 0), imageSize.height))
    }

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale)
    }

    func toView(rect r: [Double]) -> CGRect {
        let a = toView(CGPoint(x: r[0], y: r[1])), b = toView(CGPoint(x: r[2], y: r[3]))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

struct FrameCanvas: View {
    @Environment(AppState.self) private var app
    @State private var dragStart: CGPoint?
    @State private var dragNow: CGPoint?

    var body: some View {
        let flow = app.flow
        GeometryReader { geo in
            if let image = flow.frameImage {
                let m = FrameMapping(imageSize: CGSize(width: image.width, height: image.height), viewSize: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: m.shown.width, height: m.shown.height)
                        .position(x: m.origin.x + m.shown.width / 2, y: m.origin.y + m.shown.height / 2)
                    Canvas { ctx, _ in draw(ctx, m, flow) }
                        .allowsHitTesting(false)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard flow.tool != .none else { return }
                            dragStart = m.toImage(v.startLocation)
                            dragNow = m.toImage(v.location)
                        }
                        .onEnded { v in
                            defer { dragStart = nil; dragNow = nil }
                            let a = m.toImage(v.startLocation), b = m.toImage(v.location)
                            let moved = hypot(v.translation.width, v.translation.height) > 4
                            switch flow.tool {
                            case .crop, .exclude:
                                if moved { flow.apply(rect: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))) }
                            case .legend, .measure:
                                if moved { flow.apply(line: a, to: b) }
                            case .point, .maskColor:
                                flow.apply(point: b)
                            case .none:
                                break
                            }
                        }
                )
            } else {
                ContentUnavailableView {
                    Label("No Video", systemImage: "film")
                } description: {
                    Text("Open a Cp0 video (mp4 or mov) or a folder of frames, or try the demo sweep.")
                } actions: {
                    HStack {
                        Button("Open Video…") { app.openFlowSourcePanel() }
                        Button("Demo Sweep") { app.runFlowDemo() }
                    }
                }
            }
        }
        .background(Color.black.opacity(0.85))
    }

    private func draw(_ ctx: GraphicsContext, _ m: FrameMapping, _ flow: FlowFieldModel) {
        let cal = flow.calibration
        if let crop = cal.crop {
            ctx.stroke(Path(m.toView(rect: crop)), with: .color(.green), lineWidth: 2)
        }
        for r in cal.exclude {
            let rect = m.toView(rect: r)
            ctx.fill(Path(rect), with: .color(.red.opacity(0.25)))
            ctx.stroke(Path(rect), with: .color(.red), lineWidth: 1.5)
        }
        if let legend = cal.colormap.legend, legend.p0.count == 2, legend.p1.count == 2 {
            var line = Path()
            line.move(to: m.toView(CGPoint(x: legend.p0[0], y: legend.p0[1])))
            line.addLine(to: m.toView(CGPoint(x: legend.p1[0], y: legend.p1[1])))
            ctx.stroke(line, with: .color(.yellow), lineWidth: 2)
        }
        for (slot, frame) in cal.spatial.frames.enumerated() where frame.frame == flow.frameIndex {
            for (i, p) in frame.points.enumerated() where p.px.count == 2 {
                let c = m.toView(CGPoint(x: p.px[0], y: p.px[1]))
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(.cyan), lineWidth: 2)
                let label = (i == 0 ? "A" : "B") + (cal.spatial.frames.count == 2 ? "\(slot + 1)" : "")
                ctx.draw(Text(label).font(.caption.bold()).foregroundStyle(.cyan), at: CGPoint(x: c.x + 12, y: c.y - 10))
            }
        }
        if let measure = cal.measure, measure.p0.count == 2, measure.p1.count == 2 {
            let here = measure.frame == flow.frameIndex
            let a = m.toView(CGPoint(x: measure.p0[0], y: measure.p0[1]))
            let b = m.toView(CGPoint(x: measure.p1[0], y: measure.p1[1]))
            var line = Path()
            line.move(to: a)
            line.addLine(to: b)
            for end in [a, b] {
                line.move(to: CGPoint(x: end.x, y: end.y - 8))
                line.addLine(to: CGPoint(x: end.x, y: end.y + 8))
            }
            let colour = Color.orange.opacity(here ? 1 : 0.4)
            ctx.stroke(line, with: .color(colour), lineWidth: 2.5)
            let label = measure.width > 0 ? "\(Int((measure.width * 1000).rounded())) mm" : "type the width"
            ctx.draw(Text(here ? label : "\(label), on frame \(measure.frame)").font(.caption.bold()).foregroundStyle(colour),
                     at: CGPoint(x: (a.x + b.x) / 2, y: a.y - 14))
        }
        if let a = dragStart, let b = dragNow {
            let va = m.toView(a), vb = m.toView(b)
            var path = Path()
            switch flow.tool {
            case .legend:
                path.move(to: va)
                path.addLine(to: vb)
            case .measure:
                path.move(to: va)
                path.addLine(to: CGPoint(x: vb.x, y: va.y))
            default:
                path.addRect(CGRect(x: min(va.x, vb.x), y: min(va.y, vb.y), width: abs(vb.x - va.x), height: abs(vb.y - va.y)))
            }
            ctx.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
    }
}

struct CaptureGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("For STAR-CCM+ section-plane videos:").bold()
            Text("• Export lossless or at a high bitrate. Heavy compression smears colours at edges.")
            Text("• Fix the colour range (Cp0 −1 to 1, say) for the whole sweep and write it down.")
            Text("• Turn scene lighting off so the plane shows the colour map's true colours.")
            Text("• Prefer a parallel (orthographic) camera that does not move. With a perspective camera, calibrate the first and last frames.")
            Text("• Step the plane by a constant distance per frame, or keep a list of positions.")
            Text("• Hide the legend and axis triad, unless you want to sample the legend, then exclude it.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Explore

struct FlowExploreView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HSplitView {
            FlowExplorePanel()
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 440)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ForEach(StandardView.allCases) { v in Button(v.title) { app.flow.viewer.look(from: v) } }
                    Button("Fit") { app.flow.viewer.fitAll() }
                    Divider().frame(height: 14)
                    Button("Side Profile") {
                        app.flow.sliceCut = .side
                        app.flow.sliceIn3D = true
                        app.flow.viewer.look(from: .left)
                    }
                    .help("Looks at the model from the side and cuts the field lengthways, upright, through the middle")
                    .disabled(app.flow.volume == nil)
                    Spacer()
                }
                .controlSize(.small)
                .padding(6)
                Divider()
                ZStack {
                    Viewer3DView(viewer: app.flow.viewer)
                    if app.flow.volume == nil {
                        ContentUnavailableView("No Volume", systemImage: "cube.transparent",
                                               description: Text("Calibrate a video and press Reconstruct."))
                            .background(.background)
                    }
                }
                Divider()
                SliceCompare()
                    .frame(height: 240)
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct FlowExplorePanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var flow = app.flow
        Form {
            if let v = flow.volume {
                Section("Volume") {
                    LabeledContent("Grid", value: "\(v.nx) × \(v.ny) × \(v.nz)")
                    LabeledContent("x", value: range(v.x.first ?? 0, v.x.last ?? 0))
                    LabeledContent("y", value: range(v.y.first ?? 0, v.y.last ?? 0))
                    LabeledContent("z", value: range(v.z.first ?? 0, v.z.last ?? 0))
                    LabeledContent("Cell", value: "\(String(format: "%.1f", v.cellSize * 1000)) mm")
                    LabeledContent("Planes along", value: v.sweepLetter)
                }

                Section {
                    ForEach($flow.isoLevels) { $iso in
                        IsoRow(iso: $iso, volume: v)
                    }
                    Button("Add Isosurface") { app.addIsosurface() }
                } header: {
                    Text("Isosurfaces")
                } footer: {
                    Text("Marching cubes in the engine; releasing a slider recomputes. Empty space counts as the top of the range, so surfaces close around bodies.")
                }

                Section {
                    Toggle("Show the object", isOn: Binding(get: { flow.objectOn }, set: { app.setFlowObject($0) }))
                    if flow.objectComputing { ProgressView().controlSize(.small) }
                    if let error = flow.objectError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    if flow.objectOn {
                        LabeledContent("Opacity") {
                            Slider(value: $flow.objectOpacity, in: 0.1...1, onEditingChanged: { editing in
                                if !editing { flow.updateIsosurfaces() }
                            })
                        }
                        Toggle("Ignore everything below the ground (z ≤ 0)", isOn: $flow.objectIgnoreBelowGround)
                            .onChange(of: flow.objectIgnoreBelowGround) {
                                flow.objectModel = nil
                                app.computeFlowObject()
                            }
                    }
                } header: {
                    Text("Object")
                } footer: {
                    Text("The space with no fluid: wherever the video showed a mask colour (white geometry by default). Volumes reconstructed before this was added need reconstructing again.")
                }

                Section("Value window") {
                    Toggle("Show voxels between", isOn: $flow.windowOn)
                    if flow.windowOn {
                        LabeledContent("Low \(flow.windowLo, format: .number.precision(.fractionLength(2)))") {
                            Slider(value: $flow.windowLo, in: v.vmin...v.vmax, onEditingChanged: { editing in if !editing { flow.refreshWindow() } })
                        }
                        LabeledContent("High \(flow.windowHi, format: .number.precision(.fractionLength(2)))") {
                            Slider(value: $flow.windowHi, in: v.vmin...v.vmax, onEditingChanged: { editing in if !editing { flow.refreshWindow() } })
                        }
                    }
                }

                Section("Slice") {
                    Picker("Cut", selection: $flow.sliceCut) {
                        ForEach(FlowVolume.Cut.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    let n = v.sliceCount(flow.sliceCut), normal = v.axes(flow.sliceCut).normal
                    Slider(value: Binding(get: { Double(flow.sliceIndex) }, set: { flow.sliceIndex = Int($0.rounded()) }),
                           in: 0...Double(max(n - 1, 1)))
                    LabeledContent(flow.sliceCut == .captured ? "Plane" : "Cut at",
                                   value: "\(flow.sliceIndex + 1) of \(n), \(v.axisLetter(normal)) = \(String(format: "%.0f", v.slicePosition(flow.sliceCut, flow.sliceIndex) * 1000)) mm")
                    Toggle("Show the slice in 3D", isOn: $flow.sliceIn3D)
                }

                Section("Export") {
                    HStack {
                        Button("Slice as PNG…") { app.exportSliceImage() }
                            .disabled(flow.sliceImage == nil)
                            .help("The slice on show, with its position, extents, a scale bar and the colour bar")
                        Button("Isosurfaces .glb") { app.exportFlow(.isoGLB) }
                        Button(".obj (mm)") { app.exportFlow(.isoOBJ) }
                    }
                    HStack {
                        Button("Volume .npz") { app.exportFlow(.volumeNPZ) }
                        Button(".vti") { app.exportFlow(.volumeVTI) }
                    }
                }
            } else {
                Text("No volume yet.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func range(_ a: Double, _ b: Double) -> String {
        "\(String(format: "%.0f", a * 1000)) to \(String(format: "%.0f", b * 1000)) mm"
    }
}

struct IsoRow: View {
    @Environment(AppState.self) private var app
    @Binding var iso: IsoLevel
    let volume: FlowVolume

    var body: some View {
        let c = volume.color(iso.level)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)))
                    .frame(width: 16, height: 16)
                Text("Cp0 =")
                TextField("level", value: $iso.level, format: .number.precision(.fractionLength(0...3)))
                    .frame(width: 70)
                    .onSubmit { app.computeIsosurface(iso.id) }
                if iso.computing { ProgressView().controlSize(.small) }
                Spacer()
                Toggle("Visible", isOn: $iso.visible)
                    .labelsHidden()
                    .onChange(of: iso.visible) { app.flow.updateIsosurfaces() }
                Button {
                    app.flow.isoLevels.removeAll { $0.id == iso.id }
                    app.flow.updateIsosurfaces()
                } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
            }
            Slider(value: $iso.level, in: volume.vmin...volume.vmax, onEditingChanged: { editing in
                if !editing { app.computeIsosurface(iso.id) }
            })
            HStack {
                Text("Opacity").font(.caption)
                Slider(value: $iso.opacity, in: 0.1...1, onEditingChanged: { editing in
                    if !editing { app.flow.updateIsosurfaces() }
                })
            }
        }
    }
}

/// The original video frame next to the reconstructed plane, in real units.
struct SliceCompare: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let flow = app.flow
        HStack(spacing: 12) {
            if let v = flow.volume, flow.sliceCut != .captured {
                lengthways(v, flow)
            } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(flow.volume.map { "Video frame \($0.frames[safe: flow.sliceIndex] ?? 0)" } ?? "Video frame").font(.caption).bold()
                if let image = flow.sliceFrameImage {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if let v = flow.volume {
                    Text("Reconstructed, \(v.sweepLetter) = \(String(format: "%.0f", v.planePosition(flow.sliceIndex) * 1000)) mm").font(.caption).bold()
                    if let slice = flow.sliceImage {
                        // Laid out as the video showed it: the right axis across, the up axis up.
                        let across = v.range(v.right.index), upward = v.range(v.up.index)
                        let left = v.right.sign > 0 ? across.lowerBound : across.upperBound
                        let rightEnd = v.right.sign > 0 ? across.upperBound : across.lowerBound
                        let top = v.up.sign > 0 ? upward.upperBound : upward.lowerBound
                        Image(decorative: slice, scale: 1)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio((across.upperBound - across.lowerBound) / max(upward.upperBound - upward.lowerBound, 1e-9), contentMode: .fit)
                            .background(Color.gray.opacity(0.3))
                            .overlay(alignment: .bottomLeading) { axisLabel("\(v.right.letter) \(Int(left * 1000))") }
                            .overlay(alignment: .bottomTrailing) { axisLabel("\(v.right.letter) \(Int(rightEnd * 1000)) mm") }
                            .overlay(alignment: .topLeading) { axisLabel("\(v.up.letter) \(Int(top * 1000)) mm") }
                    }
                } else {
                    Text("Reconstructed").font(.caption).bold()
                    Rectangle().fill(.quaternary)
                }
            }
            }
        }
        .padding(8)
    }

    /// A side profile or a cut from above: no video frame to compare with,
    /// so the cut takes the whole width, along the sweep left to right.
    @ViewBuilder private func lengthways(_ v: FlowVolume, _ flow: FlowFieldModel) -> some View {
        let a = v.axes(flow.sliceCut)
        let across = v.range(a.across), upward = v.range(a.up)
        VStack(alignment: .leading, spacing: 4) {
            Text("\(flow.sliceCut.rawValue), \(v.axisLetter(a.normal)) = \(String(format: "%.0f", v.slicePosition(flow.sliceCut, flow.sliceIndex) * 1000)) mm")
                .font(.caption).bold()
            if let slice = flow.sliceImage {
                Image(decorative: slice, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio((across.upperBound - across.lowerBound) / max(upward.upperBound - upward.lowerBound, 1e-9), contentMode: .fit)
                    .background(Color.gray.opacity(0.3))
                    .overlay(alignment: .bottomLeading) { axisLabel("\(v.axisLetter(a.across)) \(Int(across.lowerBound * 1000))") }
                    .overlay(alignment: .bottomTrailing) { axisLabel("\(v.axisLetter(a.across)) \(Int(across.upperBound * 1000)) mm") }
                    .overlay(alignment: .topLeading) { axisLabel("\(v.axisLetter(a.up)) \(Int(upward.upperBound * 1000)) mm") }
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func axisLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .padding(2)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
    }
}

/// The video's frame rate and length: as it reports them, or typed in when
/// it reports them wrong. Frame numbers follow whichever is used, in the app
/// and in the engine alike.
struct VideoTiming: View {
    @Environment(AppState.self) private var app
    @State private var fps: Double?
    @State private var duration: Double?

    var body: some View {
        let flow = app.flow
        let typed = flow.calibration.video
        DisclosureGroup("Video timing") {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(format: "The video reports %@ fps and %@ s; using %.3f fps, %ld frames.",
                            flow.detectedFps.map { String(format: "%.3f", $0) } ?? "no",
                            flow.detectedDuration.map { String(format: "%.2f", $0) } ?? "no",
                            flow.calibration.video?.fps ?? 0, flow.frameCount))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LabeledContent("Frame rate") {
                    TextField("as reported", value: $fps, format: .number.precision(.fractionLength(0...3)))
                        .multilineTextAlignment(.trailing).frame(width: 90)
                    Text("fps").foregroundStyle(.secondary)
                }
                LabeledContent("Length") {
                    TextField("as reported", value: $duration, format: .number.precision(.fractionLength(0...3)))
                        .multilineTextAlignment(.trailing).frame(width: 90)
                    Text("s").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Apply") { Task { await flow.setVideoTiming(fps: fps, duration: duration) } }
                    Button("As reported") {
                        fps = nil
                        duration = nil
                        Task { await flow.setVideoTiming(fps: nil, duration: nil) }
                    }
                    .disabled(typed?.typedFps == nil && typed?.typedDuration == nil)
                }
                Text("Type these when the export's frame rate or length is wrong (STAR-CCM+ shows both in its animation export settings). Frame numbers follow the new timing, so set it before picking calibration frames.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            fps = typed?.typedFps
            duration = typed?.typedDuration
        }
    }
}

/// A slice drawn for export: title, the slice to scale with its extents, a
/// scale bar and the colour bar.
struct SliceExportView: View {
    let volume: FlowVolume
    let slice: CGImage
    let cut: FlowVolume.Cut
    let position: Double
    let axes: (normal: Int, across: Int, up: Int)

    var body: some View {
        let across = volume.range(axes.across), upward = volume.range(axes.up)
        let w = across.upperBound - across.lowerBound, h = max(upward.upperBound - upward.lowerBound, 1e-9)
        // Captured planes keep the video's orientation; lengthways cuts run positive.
        let flipAcross = cut == .captured && volume.right.sign < 0
        let flipUp = cut == .captured && volume.up.sign < 0
        let width = 1100.0, height = width * h / max(w, 1e-9)
        let bar = Self.niceLength(w / 5)
        VStack(alignment: .leading, spacing: 8) {
            Text("Cp0, \(cut.rawValue.lowercased()), \(volume.axisLetter(axes.normal)) = \(Int((position * 1000).rounded())) mm")
                .font(.system(size: 18, weight: .semibold))
            Image(decorative: slice, scale: 1)
                .resizable()
                .interpolation(.none)
                .frame(width: width, height: height)
                .background(Color.gray.opacity(0.25))
            HStack {
                Text("\(volume.axisLetter(axes.across)) \(Int(((flipAcross ? across.upperBound : across.lowerBound) * 1000).rounded())) mm")
                Spacer()
                Text("\(volume.axisLetter(axes.across)) \(Int(((flipAcross ? across.lowerBound : across.upperBound) * 1000).rounded())) mm")
            }
            .font(.system(size: 12).monospacedDigit())
            .frame(width: width)
            Text("up: \(volume.axisLetter(axes.up)) from \(Int(((flipUp ? upward.upperBound : upward.lowerBound) * 1000).rounded())) to \(Int(((flipUp ? upward.lowerBound : upward.upperBound) * 1000).rounded())) mm")
                .font(.system(size: 12).monospacedDigit())
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Rectangle().fill(Color.black).frame(width: width * bar / w, height: 4)
                    Text(bar >= 1 ? String(format: "%g m", bar) : String(format: "%g mm", bar * 1000)).font(.system(size: 12))
                }
                VStack(alignment: .leading, spacing: 2) {
                    LinearGradient(colors: volume.colormap.map { Color(red: Double($0.x), green: Double($0.y), blue: Double($0.z)) },
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 320, height: 12)
                    HStack {
                        Text(String(format: "%.2f", volume.vmin))
                        Spacer()
                        Text("Cp0")
                        Spacer()
                        Text(String(format: "%.2f", volume.vmax))
                    }
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: 320)
                }
            }
        }
        .padding(24)
        .background(Color.white)
        .foregroundStyle(Color.black)
    }

    /// 1, 2 or 5 times a power of ten, at most `v`.
    static func niceLength(_ v: Double) -> Double {
        guard v > 0 else { return 0.1 }
        let p = pow(10, floor(log10(v)))
        return [5.0, 2.0, 1.0].map { $0 * p }.first { $0 <= v } ?? p
    }
}
