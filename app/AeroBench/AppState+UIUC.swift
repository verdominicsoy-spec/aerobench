import AeroBenchKit
import Foundation

/// The UIUC comparison in the accuracy window: its history from the warm engine, and the
/// validate-uiuc job behind Recompute (aeroengine.validation).
extension AppState {
    func loadUIUC() async {
        guard let executable = settings.engineExecutable else {
            uiucNote = "Set the engine folder in Settings"
            return
        }
        if wingLab.warmEngine == nil { wingLab.warmEngine = WarmEngine(executableURL: executable) }
        guard let engine = wingLab.warmEngine else { return }
        if uiuc == nil { uiucNote = "Loading (the first time downloads the UIUC data, 1.4 MB)" }
        do {
            let data = try await engine.request("uiuc-results", params: .object([:]), timeout: 180)
            uiuc = try UIUCResults.decode(resultFile: data)
            uiucNote = nil
        } catch {
            uiucNote = "Could not load the comparison: \(error.localizedDescription)"
        }
    }

    func recomputeUIUC() {
        uiucJob = jobs.submit(command: "validate-uiuc", in: jobsRoot) { [weak self] item in
            guard let self, item.status == .succeeded else { return }
            Task { @MainActor in await self.loadUIUC() }
        }
    }
}
