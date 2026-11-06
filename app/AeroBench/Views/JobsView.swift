import AeroBenchKit
import AppKit
import SwiftUI

struct JobsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let jobs = app.jobs
        if jobs.jobs.isEmpty {
            S37EmptyState(title: "No jobs yet", line: "Every engine run from every tool lands here.") {
                Button("Ping engine") { app.runPing() }.buttonStyle(S37ButtonStyle())
            }
            .s37Region()
        } else {
            HSplitView {
                List(jobs.jobs, selection: Binding(get: { jobs.selected?.id }, set: { jobs.selectedID = $0 })) { job in
                    JobRow(job: job)
                        .contextMenu {
                            Button("Reveal in Finder") { jobs.revealInFinder(job) }
                            Button("Copy Log") { jobs.copyLog(job) }
                            Button("Run Again") { jobs.runAgain(job) }
                            if !job.status.isFinished {
                                Divider()
                                Button("Cancel Job") { jobs.cancel(job) }.disabled(job.cancelRequested)
                            }
                        }
                }
                .scrollContentBackground(.hidden)
                .s37Region()
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)

                Group {
                    if let job = jobs.selected { JobDetailView(job: job) }
                }
                .s37Region()
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct JobStatusIcon: View {
    let status: JobStatus

    var body: some View {
        switch status {
        case .queued: Image(systemName: "clock").foregroundStyle(S37.C.inkSecondary)
        case .running: Image(systemName: "play.circle").foregroundStyle(S37.C.sageInk)
        case .succeeded: Image(systemName: "checkmark.circle").foregroundStyle(S37.C.sageInk)
        case .failed: Image(systemName: "xmark.octagon").foregroundStyle(S37.C.critical)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(S37.C.inkSecondary)
        }
    }
}

struct JobRow: View {
    let job: JobItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                JobStatusIcon(status: job.status)
                Text(job.title).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(job.created, format: .dateTime.day().month().hour().minute().second())
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(S37.C.inkTertiary)
            }
            if job.status == .running {
                ProgressView(value: job.progress, total: 100)
            }
            if let line = subtitle {
                Text(line).font(.system(size: 12)).foregroundStyle(S37.C.inkSecondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String? {
        switch job.status {
        case .running: job.cancelRequested ? "cancelling…" : job.progressMessage
        case .failed, .cancelled: job.message
        default: nil
        }
    }
}

struct JobDetailView: View {
    @Environment(AppState.self) private var app
    let job: JobItem
    private static let previewLimit = 20_000

    var body: some View {
        VStack(alignment: .leading, spacing: S37.Space.s4) {
            HStack(alignment: .firstTextBaseline, spacing: S37.Space.s2) {
                JobStatusIcon(status: job.status)
                Text(job.title).font(.system(size: 20, weight: .semibold))
                Text(job.status.rawValue).font(.system(size: 14)).foregroundStyle(S37.C.inkSecondary)
                Spacer()
                if !job.status.isFinished {
                    Button("Cancel job") { app.jobs.cancel(job) }
                        .buttonStyle(S37ButtonStyle())
                        .disabled(job.cancelRequested)
                }
                Button("Run again") { app.jobs.runAgain(job) }.buttonStyle(S37ButtonStyle())
                Button("Reveal in Finder") { app.jobs.revealInFinder(job) }.buttonStyle(S37ButtonStyle())
            }
            Text("\(job.command)  \(job.id)").font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(S37.C.inkTertiary).textSelection(.enabled)

            if job.status == .running || job.status == .succeeded {
                ProgressView(value: job.progress, total: 100) {
                    Text(job.progressMessage.isEmpty ? " " : job.progressMessage).font(.system(size: 12))
                }
            }

            if job.status == .failed, let message = job.message {
                Label(message, systemImage: "xmark.octagon").foregroundStyle(S37.C.critical)
                if let detail = job.detail { inset(detail, maxHeight: 120) }
            }

            if let result = job.resultText {
                HStack(spacing: S37.Space.s2) {
                    Text("result.json").font(.system(size: 14, weight: .semibold))
                    if result.count > Self.previewLimit {
                        Text("first \(Self.previewLimit / 1000) kB of \(result.utf8.count / 1000) kB")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(S37.C.inkTertiary)
                    }
                    Spacer()
                    Button("Open") { NSWorkspace.shared.open(job.workdir.appendingPathComponent(JobFolder.resultFile)) }
                        .buttonStyle(S37ButtonStyle(kind: .plain))
                }
                // One Text can't lay out a large file (it draws blank), so show the start.
                inset(result.count > Self.previewLimit ? String(result.prefix(Self.previewLimit)) + "\n…" : result, maxHeight: 160)
            }

            LogView(lines: job.log)
        }
        .padding(S37.Space.s5)
    }

    /// Monospaced text in the pane's inset tint, scrolling past `maxHeight`
    private func inset(_ text: String, maxHeight: CGFloat) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(S37.Space.s3)
        }
        .frame(maxHeight: maxHeight)
        .background(RoundedRectangle(cornerRadius: S37.Radius.md, style: .continuous).fill(S37.C.inset))
    }
}

/// A job's log as glassout prints it: machine output, one console per screen.
struct LogView: View {
    let lines: [LogLine]

    var body: some View {
        GOScreen {
            VStack(alignment: .leading, spacing: 8) {
                GOMeta(text: "Log, \(lines.count) \(lines.count == 1 ? "line" : "lines")")
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(lines) { line in
                                Text(line.level == "saved" ? line.text : "[\(line.level)] \(line.text)")
                                    .foregroundStyle(color(for: line))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: lines.count) {
                        if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func color(for line: LogLine) -> Color {
        switch line.level {
        case "error", "stderr": GO.C.critical
        case "warning": GO.C.clayInk
        case "saved": GO.C.phosphorBright
        default: GO.C.phosphor
        }
    }
}

extension JobItem {
    /// The command in words, for the jobs list.
    var title: String {
        switch command {
        case "airfoil-fetch": "Download airfoil library"
        case "airfoil-index": "Index airfoil library"
        case "airfoil-import": "Import airfoils"
        case "airfoil-delete": "Delete airfoils"
        case "airfoil-polars": "Library polars"
        case "wing-polar": "Element polar"
        case "wing-estimate": "Estimate"
        case "wing-rans": "RANS CFD"
        case "wing-sweep": "RANS angle sweep"
        case "wing-optimise": "Optimise"
        case "wing-shortlist": "Find sections"
        case "wing-starter": "Set up from scratch"
        case "su2-install": "Install SU2"
        case "lapsim": "Lap Sim"
        case "tessellate": "Open CAD"
        case "cad-check": "Check geometry"
        case "cad-repair": "Repair geometry"
        case "flow-demo": "Flow demo sweep"
        case "flow-detect": "Detect flow layout"
        case "flow-preview": "Flow preview"
        case "flow-reconstruct": "Reconstruct flow"
        case "flow-iso": "Isosurface"
        case "flow-object": "Flow object"
        case "flow-export": "Export flow"
        case "ping": "Ping engine"
        case "dummy": "Dummy job"
        default: command
        }
    }
}
