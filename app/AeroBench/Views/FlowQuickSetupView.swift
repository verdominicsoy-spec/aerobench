import AeroBenchKit
import AppKit
import SwiftUI

/// The guided setup: open the video, check what was found, measure one
/// thing, type the plane positions, build. Everything else is automatic or
/// in All Settings.
struct FlowQuickSetupPanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let flow = app.flow
        let cal = flow.calibration
        Form {
            videoSection(flow)
            if flow.sourceURL != nil {
                legendSection(flow, cal)
                axesSection(flow, cal)
                sizeSection(flow, cal)
                planesSection(flow, cal)
                buildSection(flow, cal)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: 1 Video

    @ViewBuilder private func videoSection(_ flow: FlowFieldModel) -> some View {
        Section {
            HStack {
                Button(flow.sourceURL == nil ? "Open Video…" : "Open Another…") { app.openFlowSourcePanel() }
                    .keyboardShortcut("o")
                Menu("Try a Demo") {
                    Button("Front View") { app.runFlowDemo(view: "front") }
                    Button("Rear View") { app.runFlowDemo(view: "rear") }
                    Button("Side View") { app.runFlowDemo(view: "side") }
                }
                .fixedSize()
            }
            if flow.sourceURL == nil {
                Text("A STAR-CCM+ video of a section plane stepping through the flow (mp4 or mov). You can also drop it on the window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = flow.loadError {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            if let job = flow.detectJob, !job.status.isFinished {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Looking at the video…").font(.caption)
                }
            }
            ForEach(flow.detectNotes, id: \.self) { note in
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if flow.sourceURL != nil, flow.detectJob.map({ $0.status.isFinished }) ?? true {
                Button("Look Again") { app.autoDetectFlow() }
                    .buttonStyle(.link)
                    .help("Find the plot, legend, axes and ground again (overwrites the crop, exclusions, colours and axes)")
            }
        } header: {
            Text("1  Video")
        }
    }

    // MARK: 2 Legend

    @ViewBuilder private func legendSection(_ flow: FlowFieldModel, _ cal: FlowCalibration) -> some View {
        Section {
            if let image = flow.frameImage, let box = legendBox(cal), let legend = crop(image, box) {
                Image(decorative: legend, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 70)
            }
            NumberField(label: "Number at the low (left or bottom) end", value: Binding(
                get: { cal.valueRange.first ?? -1 }, set: { flow.calibration.valueRange[0] = $0 }))
            NumberField(label: "Number at the high end", value: Binding(
                get: { cal.valueRange.last ?? 1 }, set: { flow.calibration.valueRange[1] = $0 }))
            if !(cal.valueRange.count == 2 && cal.valueRange[1] > cal.valueRange[0]) {
                Label("The high end must be bigger than the low end.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption)
            }
        } header: {
            Text("2  Legend")
        } footer: {
            Text("Type the numbers written at the ends of the colour bar. For total pressure coefficient that is usually −1 and 1.")
        }
    }

    // MARK: 3 Axes

    @ViewBuilder private func axesSection(_ flow: FlowFieldModel, _ cal: FlowCalibration) -> some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 4) {
                    if let image = flow.frameImage, let box = flow.detection?.triadBox, let triad = crop(image, box, pad: 12) {
                        Image(decorative: triad, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .frame(width: 100, height: 100)
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(width: 100, height: 100)
                            .overlay { Text("Triad not found").font(.caption2).foregroundStyle(.secondary) }
                    }
                    Text("In the video").font(.caption)
                }
                VStack(spacing: 4) {
                    TriadDrawing(axes: cal.axes, towardViewer: cal.sweepTowardViewer)
                        .frame(width: 100, height: 100)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                    Text("As set here").font(.caption)
                }
            }
            Picker("Arrow pointing right", selection: Binding(get: { cal.axes.right }, set: { flow.setAxes(right: $0) })) {
                ForEach(FlowCalibration.Axes.choices, id: \.self) { Text(axisLabel($0, horizontal: true)).tag($0) }
            }
            Picker("Arrow pointing up", selection: Binding(get: { cal.axes.up }, set: { flow.setAxes(up: $0) })) {
                ForEach(FlowCalibration.Axes.choices, id: \.self) { Text(axisLabel($0, horizontal: false)).tag($0) }
            }
            if !cal.axes.isValid {
                Label("Right and up must be different axes.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
            }
        } header: {
            Text("3  Axes")
        } footer: {
            Text("Make the two pictures match: same letters pointing the same ways. X is red, Y green, Z blue; the axis seen end-on is a dot (towards you) or a cross (away).")
        }
    }

    private func axisLabel(_ axis: String, horizontal: Bool) -> String {
        let letter = axis.suffix(1).uppercased()
        let positive = axis.hasPrefix("+")
        let way = horizontal ? (positive ? "right" : "left") : (positive ? "up" : "down")
        return "\(letter) arrow points \(way)"
    }

    // MARK: 4 Size

    @ViewBuilder private func sizeSection(_ flow: FlowFieldModel, _ cal: FlowCalibration) -> some View {
        let right = cal.axes.rightLetter
        Section {
            HStack {
                Button(cal.measure?.pixelLength ?? 0 >= 2 ? "Measure Again" : "Measure") { flow.tool = .measure }
                if let m = cal.measure, m.pixelLength >= 2 {
                    Text("\(Int(m.pixelLength)) px on frame \(m.frame)").font(.caption).foregroundStyle(.secondary)
                    if m.frame != flow.frameIndex {
                        Button("Show") { Task { await flow.showFrame(m.frame) } }.buttonStyle(.link)
                    }
                }
            }
            NumberField(label: "Its real width", unit: "mm", value: Binding(
                get: { (cal.measure?.width ?? 0) * 1000 }, set: { flow.setMeasure(width: $0 / 1000) }))
            NumberField(label: "Its middle is at \(right)", unit: "mm", value: Binding(
                get: { (cal.measure?.centre ?? 0) * 1000 }, set: { flow.setMeasure(centre: $0 / 1000) }))
            if let m = cal.measure, m.pixelLength >= 2, m.pixelLength < 250 {
                Label("That line is only \(Int(m.pixelLength)) px long, so a few pixels out is a few percent. Measure something bigger, or on a frame where it looks bigger.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption)
            }
            if !cal.ground.track && cal.spatial.frames.count < 2 {
                Label("No ground line was found, so the size can drift between planes. All Settings can calibrate a second frame.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption)
            }
        } header: {
            Text("4  Size")
        } footer: {
            Text(right == "y"
                 ? "Find a frame where you can see something whose width you know (the track, between the tyre centres, or a wing's span), press Measure and drag across it. It has to be cut by the plane in that frame (the cut geometry shows white). The bigger it looks, the better. Its middle is at y = 0 if it is centred on the car."
                 : "Find a frame where you can see something whose length you know (the wheelbase, between the axles, say), press Measure and drag across it, then type where its middle is along \(right).")
        }
    }

    // MARK: 5 Planes

    @ViewBuilder private func planesSection(_ flow: FlowFieldModel, _ cal: FlowCalibration) -> some View {
        let sweep = cal.axes.sweepLetter
        let last = cal.planes.lastFrame ?? max(flow.frameCount - 1, 0)
        Section {
            if cal.planes.mode == "linear" {
                NumberField(label: "First plane (frame \(cal.planes.firstFrame)) at \(sweep)", unit: "mm",
                            value: mm({ cal.planes.start }, { flow.calibration.planes.start = $0 }))
                NumberField(label: "Last plane (frame \(last)) at \(sweep)", unit: "mm",
                            value: mm({ cal.planes.end }, { flow.calibration.planes.end = $0 }))
            } else {
                Text("Plane positions are set in All Settings (\(cal.planes.mode == "csv" ? "from a CSV" : "from the camera")).")
                    .font(.caption)
            }
        } header: {
            Text("5  Plane positions")
        } footer: {
            Text("Where the section plane was in the first and last frames, from STAR's plane sweep. Not sure which way round? Build anyway: the result says if they look reversed.")
        }
    }

    // MARK: 6 Build

    @ViewBuilder private func buildSection(_ flow: FlowFieldModel, _ cal: FlowCalibration) -> some View {
        let steps = cal.quickSteps
        let ready = cal.problems.isEmpty
        Section {
            ForEach(steps) { step in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(step.done ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title)
                        if !step.done { Text(step.hint).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if !ready, steps.allSatisfy(\.done) {
                ForEach(cal.problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption) }
            }
            HStack {
                Button("Check This Frame") { app.checkFlowFrame() }
                    .disabled(!ready || isRunning(flow.previewJob))
                    .help("Runs one plane and shows it under the frame, to check before building")
                Button("Build 3D") { app.reconstructFlow() }
                    .keyboardShortcut("r")
                    .buttonStyle(S37ButtonStyle(kind: .prominent))
                    .disabled(!ready || isRunning(flow.reconstructJob))
            }
            if let job = flow.reconstructJob {
                JobInlineStatus(job: job)
                if job.status == .failed { FailureAdvice(message: job.message ?? "", detail: job.detail ?? "") }
            }
            if let job = flow.previewJob, job.status == .failed {
                FailureAdvice(message: job.message ?? "", detail: job.detail ?? "")
            }
            if let ground = flow.reconstructStats["ground"] as? [String: Any] {
                ImpliedCameraNote(ground: ground, sweep: cal.axes.sweepLetter)
            }
        } header: {
            Text("6  Build")
        }
    }

    private func isRunning(_ job: JobItem?) -> Bool { job.map { !$0.status.isFinished } ?? false }

    /// A legend box: the detected one, or one around the legend line.
    private func legendBox(_ cal: FlowCalibration) -> [Double]? {
        if let box = app.flow.detection?.legend?.box, box.count == 4 { return box }
        guard let l = cal.colormap.legend, l.p0.count == 2, l.p1.count == 2 else { return nil }
        return [min(l.p0[0], l.p1[0]) - 40, min(l.p0[1], l.p1[1]) - 40, max(l.p0[0], l.p1[0]) + 40, max(l.p0[1], l.p1[1]) + 20]
    }

    private func crop(_ image: CGImage, _ box: [Double], pad: Double = 4) -> CGImage? {
        guard box.count == 4 else { return nil }
        let r = CGRect(x: box[0] - pad, y: box[1] - pad, width: box[2] - box[0] + 2 * pad, height: box[3] - box[1] + 2 * pad)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard r.width >= 4, r.height >= 4 else { return nil }
        return image.cropping(to: r.integral)
    }
}

/// An axis triad as STAR draws it: X red, Y green, Z blue, the third axis
/// end-on as a dot (towards the viewer) or a cross (away).
struct TriadDrawing: View {
    let axes: FlowCalibration.Axes
    let towardViewer: Bool?

    var body: some View {
        Canvas { context, size in
            let ctx = context  // drawing through a copy, as the helpers below capture it
            let o = CGPoint(x: size.width * 0.42, y: size.height * 0.58)
            let length = min(size.width, size.height) * 0.36
            func colour(_ letter: String) -> Color {
                switch letter { case "x": .red; case "y": .green; default: .blue }
            }
            func arrow(_ axis: String, dx: CGFloat, dy: CGFloat) {
                let sign: CGFloat = axis.hasPrefix("-") ? -1 : 1
                let tip = CGPoint(x: o.x + sign * dx * length, y: o.y + sign * dy * length)
                var p = Path()
                p.move(to: o)
                p.addLine(to: tip)
                let back = CGPoint(x: -sign * dx * 10, y: -sign * dy * 10), side = CGPoint(x: -sign * dy * 5, y: sign * dx * 5)
                p.move(to: CGPoint(x: tip.x + back.x + side.x, y: tip.y + back.y + side.y))
                p.addLine(to: tip)
                p.addLine(to: CGPoint(x: tip.x + back.x - side.x, y: tip.y + back.y - side.y))
                let letter = String(axis.suffix(1))
                ctx.stroke(p, with: .color(colour(letter)), lineWidth: 3)
                ctx.draw(Text(letter.uppercased()).font(.caption.bold()).foregroundStyle(Color.black),
                         at: CGPoint(x: tip.x + sign * dx * 10, y: tip.y + sign * dy * 10))
            }
            guard axes.isValid else { return }
            arrow(axes.right, dx: 1, dy: 0)
            arrow(axes.up, dx: 0, dy: -1)
            let third = axes.sweepLetter
            let dot = CGRect(x: o.x - 7, y: o.y - 7, width: 14, height: 14)
            ctx.fill(Path(ellipseIn: dot), with: .color(colour(third)))
            if towardViewer == false {
                var cross = Path()
                cross.move(to: CGPoint(x: dot.minX + 3, y: dot.minY + 3))
                cross.addLine(to: CGPoint(x: dot.maxX - 3, y: dot.maxY - 3))
                cross.move(to: CGPoint(x: dot.maxX - 3, y: dot.minY + 3))
                cross.addLine(to: CGPoint(x: dot.minX + 3, y: dot.maxY - 3))
                ctx.stroke(cross, with: .color(.white), lineWidth: 1.5)
            }
            ctx.draw(Text(third.uppercased()).font(.caption.bold()).foregroundStyle(Color.black),
                     at: CGPoint(x: o.x - 14, y: o.y + 14))
        }
    }
}

/// What to do about an engine error, in plain words.
struct FailureAdvice: View {
    let message: String
    let detail: String

    var body: some View {
        if let advice {
            Label(advice, systemImage: "lightbulb").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var advice: String? {
        let text = (message + " " + detail).lowercased()
        if text.contains("ground line") || text.contains("steady camera") {
            return "The ground line could not be followed through the video. Press Look Again; if that does not help, turn ground tracking off in All Settings and calibrate the first and last frames there."
        }
        if text.contains("does not overlap") {
            return "The size or plane positions put the planes in impossible places. Measure again on a frame where the thing you measure is in the plane, and check its width."
        }
        if text.contains("legend") {
            return "The legend could not be read. Press Look Again, or pick the STAR colours in All Settings."
        }
        if text.contains("value_range") || text.contains("value range") {
            return "Check the legend numbers: the high end must be bigger than the low end."
        }
        if text.contains("fewer than two frames") || text.contains("ended early") {
            return "The video has fewer frames than the setup expects. Press Look Again, or check the frame range in All Settings."
        }
        return nil
    }
}
