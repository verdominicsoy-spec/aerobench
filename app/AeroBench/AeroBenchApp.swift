import SwiftUI

@main
struct AeroBenchApp: App {
    @State private var app = AppState()

    var body: some Scene {
        Window("AeroBench", id: "main") {
            ContentView()
                .environment(app)
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(.dark)  // sage37 ships dark
                .tint(S37.C.sage)
        }
        .commands { AeroBenchCommands(app: app) }

        Window("Solver Accuracy", id: "accuracy") {
            AccuracyHelpView()
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
            Button("Save Project") { app.saveProject() }
                .keyboardShortcut("s")
                .disabled(app.project == nil)
        }
        CommandGroup(after: .help) {
            Button("How Accurate Is Each Solver?") { openWindow(id: "accuracy") }
        }
    }
}
