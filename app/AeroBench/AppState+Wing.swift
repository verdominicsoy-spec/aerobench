import AeroBenchKit
import AppKit
import UniformTypeIdentifiers

/// Wing Lab actions: the airfoil library, export, and the Lap Sim link.
extension AppState {
    /// Downloads the UIUC database (about 1 MB) and builds the index.
    func downloadAirfoils() {
        wingLab.libraryJob = jobs.submit(command: "airfoil-fetch", in: jobsRoot) { [weak self] item in
            guard let self, item.status == .succeeded else { return }
            self.wingLab.loadLibrary(engineDirectory: self.settings.engineDirectory)
        }
    }

    /// Builds the index from what is on disk: the NACA set at least.
    func buildAirfoilIndex() {
        wingLab.libraryJob = jobs.submit(command: "airfoil-index", in: jobsRoot) { [weak self] item in
            guard let self, item.status == .succeeded else { return }
            self.wingLab.loadLibrary(engineDirectory: self.settings.engineDirectory)
        }
    }

    func importAirfoilsPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Airfoils"
        panel.message = "Selig or Lednicer .dat files. They go into My Airfoils."
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "dat") ?? .data, .plainText, .text]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let files = JSONValue.array(panel.urls.map { .string($0.path) })
        wingLab.libraryJob = jobs.submit(command: "airfoil-import", params: ["files": files], in: jobsRoot) { [weak self] item in
            guard let self, item.status == .succeeded else { return }
            self.wingLab.loadLibrary(engineDirectory: self.settings.engineDirectory)
            self.wingLab.filter.source = "mine"
        }
    }

    /// One .dat per element, in mm in the wing frame, into a folder.
    func exportWingDat() {
        let wing = wingLab.wing
        guard !wing.elements.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Export Elements as .dat"
        panel.message = "Choose a folder: one .dat per element, in mm, in the wing's frame."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            for i in wing.elements.indices {
                let name = WingIssue.label(i).lowercased().replacingOccurrences(of: " ", with: "_")
                try wing.datFile(of: i).write(to: folder.appendingPathComponent("\(name).dat"), atomically: true, encoding: .utf8)
            }
        } catch {
            show("Could not export the elements", error)
        }
    }

    func exportWingCSV() {
        let panel = NSSavePanel()
        panel.title = "Export Wing Points"
        panel.nameFieldStringValue = "wing_points_mm.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try wingLab.wing.csvFile().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            show("Could not export the points", error)
        }
    }

    /// Car B becomes car A with this wing in place of the one it replaces,
    /// and the Lap Sim compares the two.
    func sendWingToLapSim(cl: Double, cd: Double, replacedCla: Double, replacedCda: Double) {
        let add = wingLab.wing.carContribution(cl: cl, cd: cd)
        var b = lapSim.carA
        b.cla = max(b.cla - replacedCla + add.cla, 0)
        b.cda = max(b.cda - replacedCda + add.cda, 0)
        lapSim.carB = b
        lapSim.compare = true
    }
}
