import AeroBenchKit
import Foundation

extension AppState {
    /// Tracks the editor can start from, in the order the Lap Sim lists them.
    var copyableTracks: [LapSimTrackKind] {
        [.endurance, .autocross, .fsg, .fsi, .testTrack, .skidpad, .acceleration] + (lapSim.track.csvPath == nil ? [] : [.csv])
    }

    func trackName(_ kind: LapSimTrackKind) -> String {
        switch kind {
        case .endurance, .autocross: "\(kind.title.prefix(1).uppercased())\(kind.title.dropFirst()), layout \(lapSim.track.seed)"
        case .csv: lapSim.track.csvPath.map { ($0 as NSString).lastPathComponent } ?? "Imported CSV"
        default: "\(kind.title.prefix(1).uppercased())\(kind.title.dropFirst())"
        }
    }

    /// A track's centreline from the engine, fitted with Bézier curves for the editor.
    func drawnCopy(of kind: LapSimTrackKind) async throws -> DrawnTrack {
        guard let executable = settings.engineExecutable else {
            throw WarmEngine.Failure(message: "Set the engine folder in Settings", detail: nil)
        }
        // Shared with Wing Lab's live estimate: one warm engine for the app.
        wingLab.warmEngine = warm(wingLab.warmEngine, executable)
        guard let engine = wingLab.warmEngine else { throw WarmEngine.Failure(message: "Could not start the engine", detail: nil) }
        var track = lapSim.track
        track.kind = kind
        let reply = try await engine.request("lapsim-track", params: .object(["track": track.jobValue(lapsimFolder: lapSimFolder)]))
        return try DrawnTrack.fit(engineReply: reply, source: trackName(kind))
    }
}
