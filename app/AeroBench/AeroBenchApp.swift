import SwiftUI

@main
struct AeroBenchApp: App {
    @State private var app = AppState()

    init() { Fonts.register() }

    var body: some Scene {
        Window("AeroBench", id: "main") {
            ContentView()
                .environment(app)
                .frame(minWidth: 900, minHeight: 680)  // room for the header and dock round Wing Lab's panes
                .preferredColorScheme(.dark)  // sage37 ships dark
                .tint(S37.C.sage)
        }
        .commands { AeroBenchCommands(app: app) }

        Window("Solver Accuracy", id: "accuracy") {
            AccuracyHelpView()
                .environment(app)  // the UIUC section loads results and runs its job
                .preferredColorScheme(.dark)
                .tint(S37.C.sage)
        }
        .defaultSize(width: 640, height: 720)

        Settings {
            SettingsView()
                .environment(app)
                .preferredColorScheme(.dark)
                .tint(S37.C.sage)
        }
    }
}

struct AeroBenchCommands: Commands {
    let app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project…") { app.newProjectPanel() }
                .keyboardShortcut("n")
            Button("Open Project…") { app.openProjectPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(app.recentProjects, id: \.self) { url in
                    Button(url.lastPathComponent) { app.open(url) }
                }
                Divider()
                Button("Clear Menu") { app.clearRecentProjects() }
            }
            Divider()
            Button("Close Project") { app.closeProject() }
                .disabled(app.project == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Project") { app.save() }
                .keyboardShortcut("s")
        }
        CommandMenu("Part") {
            Button(app.partEdit.on ? "Stop Editing Part" : "Edit Part") {
                app.partEdit.on ? app.exitPartEdit() : app.enterPartEdit()
            }
            .keyboardShortcut("e")
            .disabled(!app.cad.isStep || app.cad.model == nil)
            Button("Save Part…") { app.savePartEdit() }
                .disabled(!app.partEdit.on || app.partEdit.reply == nil)
        }
        CommandGroup(after: .help) {
            Button("How Accurate Is Each Solver?") { openWindow(id: "accuracy") }
        }
    }
}
