import AeroBenchKit
import SwiftUI

/// Edit Part mode's side panel: the tools, the active tool's picks and
/// values, and the feature list.
struct PartEditView: View {
    @Environment(AppState.self) private var app
    @Environment(\.undoManager) private var undo

    private static let tools: [(EditFeature.Kind, String)] = [
        (.point, "smallcircle.filled.circle"), (.spline, "scribble"), (.plane, "square.on.square.dashed"),
        (.extrude, "arrow.up.square"), (.fill, "square.dashed.inset.filled"), (.add, "plus.square.on.square"),
        (.fillet, "roundedbottom.horizontal"), (.chamfer, "triangle"), (.pushpull, "arrow.up.and.down.square"),
    ]

    var body: some View {
        @Bindable var edit = app.partEdit
        Form {
            if let reply = edit.reply, reply.parts.count > 1 {
                Picker("Part", selection: Binding(get: { edit.file.part ?? "" }, set: { edit.choosePart($0) })) {
                    if edit.file.part == nil { Text("Pick a part").tag("") }
                    ForEach(reply.parts, id: \.self) { Text($0).tag($0) }
                }
            }
            if let reply = edit.reply, !reply.partValid {
                HStack {
                    Label("This part is not a valid solid", systemImage: "exclamationmark.triangle").foregroundStyle(S37.C.clayInk)
                    Button("Repair First") { app.repairBeforeEditing() }
                }
            }
            Section("Tools") {
                HStack(spacing: 4) {
                    ForEach(Self.tools, id: \.0) { kind, icon in
                        Button { edit.tool = edit.tool == kind ? nil : kind } label: { Image(systemName: icon) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(edit.tool == kind ? S37.C.sageInk : S37.C.inkSecondary)
                            .accessibilityLabel(kind.title)
                            .help(kind.title)
                    }
                }
                if edit.tool != nil { ToolPanel() }
            }
            Section("Features") {
                if edit.file.features.isEmpty {
                    Text("No edits yet").foregroundStyle(.secondary)
                }
                List(selection: Binding(get: { edit.selectedFeature }, set: { if let id = $0 { edit.edit(id) } })) {
                    ForEach(edit.file.features) { f in
                        FeatureRow(feature: f, status: edit.reply?.features.first { $0.id == f.id })
                            .tag(f.id)
                            .contextMenu {
                                Button("Edit") { edit.edit(f.id) }
                                Button("Remove") { edit.remove(f.id, undo: undo) }
                            }
                    }
                }
                .frame(minHeight: 120, maxHeight: 280)
            }
            Section {
                if let status = edit.status { Text(status).font(.caption).foregroundStyle(S37.C.clayInk) }
                HStack {
                    if edit.busy || edit.saving { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Save Part…") { app.savePartEdit() }
                        .disabled(edit.reply == nil || edit.busy || edit.saving
                                  || !(edit.reply?.features.allSatisfy { $0.status == "ok" } ?? false))
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct FeatureRow: View {
    let feature: EditFeature
    let status: PartEditReply.Status?

    var body: some View {
        HStack {
            Text(PartEditModel.describe(feature))
            Spacer()
            if let s = status, s.status != "ok" {
                Text(s.status == "lost" ? "Reference lost" : s.status.capitalized)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(s.status == "skipped" ? Color.gray.opacity(0.2) : S37.C.clayWash))
                    .foregroundStyle(s.status == "skipped" ? S37.C.inkSecondary : S37.C.clayInk)
                    .help(s.message ?? "")
            }
        }
    }
}

/// What the active tool still needs, its values, and Apply.
private struct ToolPanel: View {
    @Environment(AppState.self) private var app
    @Environment(\.undoManager) private var undo

    var body: some View {
        let edit = app.partEdit
        if let draft = edit.draft {
            Text(need(draft)).font(.caption).foregroundStyle(.secondary)
            switch draft.kind {
            case .plane, .extrude:
                HStack {
                    ForEach(["XY", "YZ", "ZX"], id: \.self) { name in
                        Button(name) { edit.usePlane(EditRef(src: "std", kind: "plane", name: name)) }
                    }
                    ForEach(edit.reply?.planes ?? [], id: \.id) { p in
                        if draft.kind == .extrude { Button(p.id) { edit.usePlane(EditRef(src: p.id, kind: "plane")) } }
                    }
                }
                if draft.kind == .extrude {
                    value("Distance", "distance", default: 10)
                    Toggle("Symmetric", isOn: Binding(get: { (edit.draft?.values["symmetric"] ?? 0) != 0 },
                                                      set: { edit.draft?.values["symmetric"] = $0 ? 1 : 0 }))
                }
            case .fillet: value("Radius", "radius", default: 2)
            case .chamfer, .pushpull: value("Distance", "distance", default: 2)
            default: EmptyView()
            }
            HStack {
                Button("Cancel") { edit.cancel() }
                Spacer()
                Button("Apply") { edit.apply(undo: undo) }
                    .keyboardShortcut(.return)
                    .disabled(!edit.ready(draft))
            }
        }
    }

    private func value(_ label: String, _ key: String, default d: Double) -> some View {
        let edit = app.partEdit
        return LabeledContent(label) {
            HStack(spacing: 4) {
                TextField(label, value: Binding(get: { edit.draft?.values[key] ?? d }, set: { edit.draft?.values[key] = $0 }),
                          format: .number.precision(.fractionLength(0...3)))
                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 70)
                Text("mm").foregroundStyle(.secondary)
            }
        }
        .onAppear { if edit.draft?.values[key] == nil { edit.draft?.values[key] = d } }
    }

    private func need(_ d: EditFeature) -> String {
        switch d.kind {
        case .point: "Click an edge or face of the part"
        case .spline: "Click 2 or more points, in order (\(d.refs.count) so far)"
        case .plane: d.refs.isEmpty ? "Pick a reference plane or click a flat face" : "Click a point for the plane to pass through"
        case .extrude: "Click a spline or edge, and pick a plane to extrude along"
        case .fill: "Click the boundary edges in order (\(d.refs.count) so far); part edges stay tangent to the face you click from"
        case .add: "Click the surfaces that close a volume (\(d.refs.count) so far)"
        case .fillet, .chamfer: "Click the edges (\(d.refs.count) picked)"
        case .pushpull: "Click a flat face"
        }
    }
}
