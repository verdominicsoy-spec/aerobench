import AeroBenchKit
import AppKit
import UniformTypeIdentifiers

extension AppState {
    func openCADPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Model"
        panel.message = "STEP, IGES, STL, OBJ or glb"
        panel.allowedContentTypes = CADViewerModel.openableExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openCAD(url)
    }

    /// Opens a model: STL, OBJ and glb load directly; STEP and IGES are
    /// tessellated by the engine once per preset and cached.
    func openCAD(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard CADViewerModel.openableExtensions.contains(ext) else {
            alert = AppAlert(title: "Cannot open \(url.lastPathComponent)",
                             message: "The CAD Viewer opens STEP, IGES, STL, OBJ and glb files.")
            return
        }
        cad.setFile(url)
        if CADViewerModel.tessellatedExtensions.contains(ext) {
            tessellate(url)
        } else {
            loadModel(url, units: cad.meshUnits, fromCache: false)
        }
    }

    /// Re-opens the current file, after a preset or unit change.
    func reloadCAD() {
        if let url = cad.fileURL { openCAD(url) }
    }

    private func tessellate(_ url: URL) {
        let preset = cad.preset
        if let cached = CADViewerModel.cacheURL(for: url, preset: preset),
           FileManager.default.fileExists(atPath: cached.path) {
            loadModel(cached, units: .metre, fromCache: true)
            return
        }
        cad.status = .loading("Tessellating \(url.lastPathComponent) (\(preset.rawValue))…")
        cad.job = jobs.submit(
            command: "tessellate",
            params: ["path": .string(url.path), "preset": .string(preset.rawValue)],
            in: jobsRoot
        ) { [weak self] item in
            guard let self, self.cad.fileURL == url else { return }
            guard item.status == .succeeded else {
                self.cad.status = .failed(item.message ?? "Tessellation \(item.status.rawValue)", item.detail)
                return
            }
            let glb = item.workdir.appendingPathComponent("model.glb")
            if let cached = CADViewerModel.cacheURL(for: url, preset: preset) {
                try? FileManager.default.createDirectory(at: CADViewerModel.cacheFolder, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: cached)
                try? FileManager.default.copyItem(at: glb, to: cached)
            }
            self.loadModel(glb, units: .metre, fromCache: false)
        }
    }

    private func loadModel(_ url: URL, units: LengthUnit, fromCache: Bool) {
        cad.status = .loading("Reading \(url.lastPathComponent)…")
        let target = cad.fileURL
        Task {
            do {
                let model = try await Task.detached(priority: .userInitiated) {
                    try ModelLoader.load(url, units: units)
                }.value
                guard self.cad.fileURL == target else { return }  // another file was opened meanwhile
                self.cad.setModel(model, fromCache: fromCache)
            } catch {
                guard self.cad.fileURL == target else { return }
                self.cad.status = .failed("Could not read \(url.lastPathComponent)", error.localizedDescription)
            }
        }
    }
}
