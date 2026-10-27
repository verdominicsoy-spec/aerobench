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

    // MARK: Geometry check and repair

    func checkGeometry() {
        guard let url = cad.fileURL else { return }
        cad.setReport(nil)
        cad.checkJob = jobs.submit(command: "cad-check", params: [
            "path": .string(url.path), "units": .string(cad.meshUnits.rawValue), "preset": .string(cad.preset.rawValue),
        ], in: jobsRoot) { [weak self] item in
            guard let self, self.cad.fileURL == url, item.status == .succeeded, let text = item.resultText else { return }
            do {
                self.cad.setReport(try GeometryReport.decode(resultFile: Data(text.utf8)))
            } catch {
                self.show("Could not read the geometry report", error)
            }
        }
    }

    /// Applies the safe fixes, asks where to save the result, then opens it.
    func repairGeometry() {
        guard let url = cad.fileURL else { return }
        cad.repairSummary = nil
        cad.repairJob = jobs.submit(command: "cad-repair", params: [
            "path": .string(url.path), "units": .string(cad.meshUnits.rawValue),
        ], in: jobsRoot) { [weak self] item in
            guard let self, item.status == .succeeded, let text = item.resultText,
                  let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let data = obj["data"] as? [String: Any], let name = data["output"] as? String
            else { return }
            let after = (data["after"] as? [String: Any])?["problems"] as? Int
            self.cad.repairSummary = Self.describe(done: data["done"] as? [String: Any] ?? [:], remaining: after)
            let panel = NSSavePanel()
            panel.title = "Save Repaired File"
            panel.nameFieldStringValue = name
            panel.directoryURL = url.deletingLastPathComponent()
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.copyItem(at: item.workdir.appendingPathComponent(name), to: dest)
                self.openCAD(dest)
            } catch {
                self.show("Could not save the repaired file", error)
            }
        }
    }

    private static func describe(done: [String: Any], remaining: Int?) -> String {
        let labels: [(String, String)] = [
            ("vertices_merged", "vertices merged"), ("degenerate_removed", "degenerate faces removed"),
            ("duplicates_removed", "duplicate faces removed"), ("faces_flipped", "faces flipped"),
            ("holes_closed", "holes closed"), ("parts_changed", "parts fixed"), ("parts_sewn", "parts sewn"),
        ]
        var parts = labels.compactMap { key, label -> String? in
            guard let n = done[key] as? Int, n > 0 else { return nil }
            return "\(n) \(label)"
        }
        if parts.isEmpty { parts = ["nothing needed fixing"] }
        let tail = remaining.map { $0 == 0 ? " No problems left." : " \($0) problems left that need a manual fix." } ?? ""
        let text = parts.joined(separator: ", ")
        let sentence: String = String(text.prefix(1)).uppercased() + String(text.dropFirst())
        return sentence + "." + tail
    }
}
