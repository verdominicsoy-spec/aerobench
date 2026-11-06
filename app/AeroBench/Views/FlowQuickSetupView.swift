import AeroBenchKit
import AppKit
import SwiftUI

/// The one setup panel: open the video, check what was found, measure one
/// thing, type the plane positions, build. Everything else is automatic, or
/// under All settings at the bottom.
struct FlowSetupPanel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var flow = app.flow
        let cal = flow.calibration
        ScrollView {
            VStack(alignment: .leading, spacing: S37.Space.s6) {
                videoSection(flow)
                if flow.sourceURL != nil {
                    legendSection(flow, cal)
                    axesSection(flow, cal)
                    sizeSection(flow, cal)
                    planesSection(flow, cal)
                    buildSection(flow, cal)
                    DisclosureGroup(isExpanded: $flow.showAllSettings) {
                        FlowAdvancedSettings().padding(.top, S37.Space.s3)
                    } label: {
                        Text("All settings").font(.system(size: 14, weight: .semibold)).foregroundStyle(S37.C.inkSecondary)
                    }
                }
            }
            .padding(S37.Space.s5)
        }
    }

    // MARK: 1 Video

    @ViewBuilder private func videoSection(_ flow: FlowFieldModel) -> some View {
        S37Section("1 Video") {
            HStack(spacing: S37.Space.s3) {
                Button("Open another…") { app.openFlowSourcePanel() }
                    .buttonStyle(S37ButtonStyle())
                Menu("Try a demo") {
                    Button("Front View") { app.runFlowDemo(view: "front") }
                    Button("Rear View") { app.runFlowDemo(view: "rear") }
                    Button("Side View") { app.runFlowDemo(view: "side") }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.vertical, S37.Space.s2)
            if let error = flow.loadError {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(S37.C.critical)
            }
            if flow.frameCount > 0 {
                LabeledContent("Frames", value: "\(flow.frameCount), \(Int(flow.frameSize.width)) × \(Int(flow.frameSize.height))")
            }
            if let job = flow.detectJob, !job.status.isFinished {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Looking at the video…")
                }
            }
            ForEach(flow.detectNotes, id: \.self) { note in
                Text(note).font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary)
            }
            if flow.sourceURL != nil, flow.detectJob.map({ $0.status.isFinished }) ?? true {
                Button("Look again") { app.autoDetectFlow() }
                    .buttonStyle(S37ButtonStyle(kind: .plain))
                    .help("Overwrites the crop, exclusions, colours and axes")
            }
        }
    }

    // MARK: 2 Legend

    @ViewBuilder private func legendSection(_ flow: FlowFieldModel, _ cal: FlowCalibration) -> some View {
        let rangeOK = cal.valueRange.count == 2 && cal.valueRange[1] > cal.valueRange[0]
        S37Section("2 Legend", footer: "The numbers at the ends of the colour bar: usually −1 and 1 for Cp0.") {
            if let image = flow.frameImage, let box = legendBox(cal), let legend = crop(image, box) {
                Image(decorative: legend, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 70)
            }
            S37FieldRow(label: "Low (left or bottom) end", value: Binding(
                get: { cal.valueRange.first ?? -1 }, set: { flow.calibration.valueRange[0] = $0 }), width: 90)
            S37FieldRow(label: "High end", value: Binding(
                get: { cal.valueRange.last ?? 1 }, set: { flow.calibration.valueRange[1] = $0 }),
                error: rangeOK ? nil : "Use a number above the low end", width: 90)
        }
    }

    // MARK: 3 Axes

    @ViewBuilder private func axesSection(_ flow: FlowFieldModel, _ cal: FlowCalibration) -> some View {
        S37Section("3 Axes", footer: "Match the two pictures. X is red, Y green, Z blue; an end-on axis is a dot (towards you) or a cross (away).") {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 4) {
                    if let image = flow.frameImage, let box = flow.detection?.triadBox, let triad = crop(image, box, pad: 12) {
                        Image(decorative: triad, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .frame(width: 100, height: 100)
                    } else {
                        RoundedRectangle(cornerRadius: S37.Radius.sm, style: .continuous).fill(.quaternary).frame(width: 100, height: 100)
                            .overlay { Text("Triad not found").font(.system(size: 11)).foregroundStyle(S37.C.inkSecondary) }
                    }
                    Text("In the video").font(.system(size: 12, weight: .medium))
                }
                VStack(spacing: 4) {
                    TriadDrawing(axes: cal.axes, towardViewer: cal.sweepTowardViewer)
                        .frame(width: 100, height: 100)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: S37.Radius.sm, style: .continuous))
                    Text("As set here").font(.system(size: 12, weight: .medium))
                }
            }
            .padding(.vertical, S37.Space.s3)
            Picker("Arrow pointing right", selection: Binding(get: { cal.axes.right }, set: { flow.setAxes(right: $0) })) {
                ForEach(FlowCalibration.Axes.choices, id: \.self) { Text(axisLabel($0, horizontal: true)).tag($0) }
            }
            Picker("Arrow pointing up", selection: Binding(get: { cal.axes.up }, set: { flow.setAxes(up: $0) })) {
                ForEach(FlowCalibration.Axes.choices, id: \.self) { Text(axisLabel($0, horizontal: false)).tag($0) }
            }
            if cal.axes.isValid {
                LabeledContent("Planes step along", value: cal.axes.sweepLetter)
            } else {
                Text("Pick a different axis for up than for right").font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.critical)
            }
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
        S37Section("4 Size", footer: right == "y"
                   ? "Measure something whose width you know (the track, tyre centres, a wing's span) on a frame where the plane cuts it (cut geometry shows white). Bigger is better. Centred on the car, its middle is at y = 0."
                   : "Measure something whose length you know (the wheelbase, say), then type where its middle is along \(right).") {
            HStack(spacing: S37.Space.s3) {
                Button(cal.measure?.pixelLength ?? 0 >= 2 ? "Measure again" : "Measure") { flow.tool = .measure }
                    .buttonStyle(S37ButtonStyle())
                if let m = cal.measure, m.pixelLength >= 2 {
                    Text("\(Int(m.pixelLength)) px on frame \(m.frame)").font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.inkSecondary)
                    if m.frame != flow.frameIndex {
                        Button("Show") { Task { await flow.showFrame(m.frame) } }.buttonStyle(S37ButtonStyle(kind: .plain))
                    }
                }
            }
            .padding(.vertical, S37.Space.s2)
            NumberField(label: "Its real width", unit: "mm", value: Binding(
                get: { (cal.measure?.width ?? 0) * 1000 }, set: { flow.setMeasure(width: $0 / 1000) }))
            NumberField(label: "Its middle is at \(right)", unit: "mm", value: Binding(
                get: { (cal.measure?.centre ?? 0) * 1000 }, set: { flow.setMeasure(centre: $0 / 1000) }))
            if let m = cal.measure, m.pixelLength >= 2, m.pixelLength < 250 {
                Label("Only \(Int(m.pixelLength)) px long, so a few pixels out is a few percent. Measure something bigger.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(S37.C.clayInk).font(.system(size: 12, weight: .medium))
            }
            if !cal.ground.track && cal.spatial.frames.count < 2 {
                Label("No ground line found, so the size can drift between planes. All settings can calibrate a second frame.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(S37.C.clayInk).font(.system(size: 12, weight: .medium))
            }
        }
    }

    // MARK: 5 Planes

    @ViewBuilder private func planesSection(_ flow: FlowFieldModel, _ cal: FlowCalibration) -> some View {
        let sweep = cal.axes.sweepLetter
        let last = cal.planes.lastFrame ?? max(flow.frameCount - 1, 0)
        S37Section("5 Plane positions", footer: "From STAR's plane sweep. Not sure which way round? Build anyway: the result says if they look reversed.") {
            if cal.planes.mode == "linear" {
                NumberField(label: "First plane (frame \(cal.planes.firstFrame)) at \(sweep)", unit: "mm",
                            value: mm({ cal.planes.start }, { flow.calibration.planes.start = $0 }))
                NumberField(label: "Last plane (frame \(last)) at \(sweep)", unit: "mm",
                            value: mm({ cal.planes.end }, { flow.calibration.planes.end = $0 }))
            } else {
                Text("Set under All settings (\(cal.planes.mode == "csv" ? "from a CSV" : "from the camera")).")
            }
        }
    }

    // MARK: 6 Build

    @ViewBuilder private func buildSection(_ flow: FlowFieldModel, _ cal: FlowCalibration) -> some View {
        let steps = cal.quickSteps
        let ready = cal.problems.isEmpty
        S37Section("6 Build") {
            ForEach(steps) { step in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: step.done ? "checkmark.circle" : "circle")
                        .foregroundStyle(step.done ? S37.C.sageInk : S37.C.inkTertiary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title)
                        if !step.done { Text(step.hint).font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary) }
                    }
                }
            }
            if !ready, steps.allSatisfy(\.done) {
                ForEach(cal.problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(S37.C.clayInk).font(.system(size: 12, weight: .medium)) }
            }
            HStack(spacing: S37.Space.s3) {
                Button("Check this frame") { app.checkFlowFrame() }
                    .buttonStyle(S37ButtonStyle())
                    .disabled(!ready || isRunning(flow.previewJob))
                    .help("Runs one plane and shows it under the frame")
                Button("Build 3D") { app.reconstructFlow() }
                    .buttonStyle(S37ButtonStyle(kind: .prominent))
                    .disabled(!ready || isRunning(flow.reconstructJob))
            }
            .padding(.vertical, S37.Space.s2)
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
