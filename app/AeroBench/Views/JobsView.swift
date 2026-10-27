import AeroBenchKit
import AppKit
import SwiftUI

struct JobsView: View {
    @Environment(AppState.self) private var app
    @State private var selectedID: JobItem.ID?

    var body: some View {
        HSplitView {
            List(app.jobs.jobs, selection: $selectedID) { job in
                JobRow(job: job)
            }
            .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)

            Group {
                if let job = app.jobs.jobs.first(where: { $0.id == selectedID }) {
                    JobDetailView(job: job)
                } else {
                    ContentUnavailableView("No Job Selected", systemImage: "list.bullet.rectangle",
                                           description: Text("Pick a job to see its progress, log and result."))
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if app.jobs.jobs.isEmpty {
                ContentUnavailableView("No Jobs Yet", systemImage: "list.bullet.rectangle",
                                       description: Text("Ping the engine or run the dummy job from the Project screen."))
            }
        }
    }
}

struct JobStatusIcon: View {
    let status: JobStatus

    var body: some View {
        switch status {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: Image(systemName: "play.circle").foregroundStyle(.blue)
        case .succeeded: Image(systemName: "checkmark.circle").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }
}

struct JobRow: View {
    let job: JobItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                JobStatusIcon(status: job.status)
                Text(job.command).bold()
                Spacer()
                Text(job.created, format: .dateTime.day().month().hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if job.status == .running {
                ProgressView(value: job.progress, total: 100)
            }
            if let line = subtitle {
                Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                JobStatusIcon(status: job.status)
                Text(job.command).font(.title2).bold()
                Text(job.status.rawValue).foregroundStyle(.secondary)
                Spacer()
                if !job.status.isFinished {
                    Button("Cancel", role: .cancel) { app.jobs.cancel(job) }
                        .disabled(job.cancelRequested)
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([job.workdir])
                }
            }
            Text(job.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)

            if job.status == .running || job.status == .succeeded {
                ProgressView(value: job.progress, total: 100) {
                    Text(job.progressMessage.isEmpty ? " " : job.progressMessage).font(.caption)
                }
            }

            if job.status == .failed, let message = job.message {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
                        if let detail = job.detail {
                            ScrollView {
                                Text(detail)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 120)
                        }
                    }
                }
            }

            if let result = job.resultText {
                GroupBox("result.json") {
                    ScrollView {
                        Text(result)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
            }

            GroupBox("Log") {
                LogView(lines: job.log)
            }
        }
        .padding()
    }
}

struct LogView: View {
    let lines: [LogLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { line in
                        Text(line.level == "saved" ? line.text : "[\(line.level)] \(line.text)")
                            .font(.caption.monospaced())
                            .foregroundStyle(color(for: line))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
            }
            .onChange(of: lines.count) {
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func color(for line: LogLine) -> Color {
        switch line.level {
        case "error", "stderr": .red
        case "warning": .orange
        default: .primary
        }
    }
}
