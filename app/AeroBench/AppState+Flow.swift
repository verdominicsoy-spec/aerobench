import AeroBenchKit
import AppKit
import UniformTypeIdentifiers

/// Flow Field Viewer actions: opening sources, running engine jobs, export.
extension AppState {
    func openFlowSourcePanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Cp0 Video or Image Folder"
        panel.message = "An mp4 or mov of section planes, or a folder of frames."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .folder]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await flow.open(url) }
    }

    /// A synthetic sweep with a known answer and a matching calibration, to
    /// try the tool without real data.
    /// A synthetic sweep with a known answer: view is rear, front or side.
    func runFlowDemo(view: String = "rear") {
        flow.loadError = nil
        let params: [String: JSONValue] = ["frames": .int(121), "perspective": .bool(true), "view": .string(view)]
        _ = jobs.submit(command: "flow-demo", params: params, in: jobsRoot) { [weak self] item in
            guard let self else { return }
            guard item.status == .succeeded else {
                self.flow.loadError = item.message ?? "The demo could not be generated."
                return
            }
            do {
                self.flow.calibration = try FlowCalibration.load(item.workdir.appendingPathComponent("demo_calibration.json"))
            } catch {
                self.flow.loadError = error.localizedDescription
            }
            Task { await self.flow.open(item.workdir.appendingPathComponent("demo.mp4")) }
        }
    }

    func checkFlowFrame() {
        guard let source = flow.sourceURL else { return }
        do {
            let calibration = try flow.calibration.jsonValue()
            let params: [String: JSONValue] = [
                "source": .string(source.path),
                "calibration": calibration,
                "frame": .int(flow.frameIndex),
            ]
            flow.previewImage = nil
            flow.previewJob = jobs.submit(command: "flow-preview", params: params, in: jobsRoot) { [weak self] item in
                guard let self, item.status == .succeeded else { return }
                self.flow.previewImage = FrameGrabber.loadImage(item.workdir.appendingPathComponent("preview.png"))
                if let text = item.resultText, let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                    self.flow.previewStats = obj["data"] as? [String: Any] ?? [:]
                }
            }
        } catch {
            show("Could not check the frame", error)
        }
    }

    func reconstructFlow() {
        guard let source = flow.sourceURL else { return }
        do {
            let calibration = try flow.calibration.jsonValue()
            let params: [String: JSONValue] = ["source": .string(source.path), "calibration": calibration]
            flow.reconstructJob = jobs.submit(command: "flow-reconstruct", params: params, in: jobsRoot) { [weak self] item in
                self?.loadFlowVolume(from: item)
            }
        } catch {
            show("Could not start the reconstruction", error)
        }
    }

    func loadFlowVolume(from item: JobItem) {
        guard item.status == .succeeded else { return }
        let folder = item.workdir
        Task {
            do {
                let volume = try await Task.detached(priority: .userInitiated) { try FlowVolume.load(folder: folder) }.value
                self.flow.setVolume(volume, folder: folder)
            } catch {
                self.show("Could not read the reconstructed volume", error)
            }
        }
    }

    /// Recomputes one isosurface in the engine (marching cubes).
    func computeIsosurface(_ id: IsoLevel.ID) {
        guard let folder = flow.volumeFolder, let index = flow.isoLevels.firstIndex(where: { $0.id == id }) else { return }
        let level = flow.isoLevels[index].level
        flow.isoLevels[index].computing = true
        _ = jobs.submit(command: "flow-iso", params: [
            "volume": .string(folder.appendingPathComponent("volume.npz").path),
            "levels": .array([.double(level)]),
        ], in: jobsRoot) { [weak self] item in
            guard let self, let i = self.flow.isoLevels.firstIndex(where: { $0.id == id }) else { return }
            self.flow.isoLevels[i].computing = false
            guard item.status == .succeeded, self.flow.isoLevels[i].level == level else { return }
            self.flow.isoLevels[i].model = try? ModelLoader.load(item.workdir.appendingPathComponent("iso.glb"))
            self.flow.updateIsosurfaces()
        }
    }

    /// Meshes the no-fluid region once per volume, then shows or hides it.
    func setFlowObject(_ on: Bool) {
        flow.objectOn = on
        flow.objectError = nil
        guard on, flow.objectModel == nil else {
            flow.updateIsosurfaces()
            return
        }
        computeFlowObject()
    }

    func computeFlowObject() {
        guard let folder = flow.volumeFolder else { return }
        flow.objectComputing = true
        let ground: JSONValue = flow.objectIgnoreBelowGround ? .double(0) : .null
        _ = jobs.submit(command: "flow-object", params: [
            "volume": .string(folder.appendingPathComponent("volume.npz").path), "ground_z": ground,
        ], in: jobsRoot) { [weak self] item in
            guard let self, self.flow.volumeFolder == folder else { return }
            self.flow.objectComputing = false
            guard item.status == .succeeded else {
                self.flow.objectError = item.message ?? "The object could not be built."
                self.flow.objectOn = false
                return
            }
            self.flow.objectModel = try? ModelLoader.load(item.workdir.appendingPathComponent("object.glb"))
            if self.flow.objectModel?.triangleCount ?? 0 == 0 {
                self.flow.objectError = "No geometry was found. Check the mask colours in the calibration."
            }
            self.flow.updateIsosurfaces()
        }
    }

    func addIsosurface() {
        guard let volume = flow.volume else { return }
        let level = flow.isoLevels.isEmpty ? (volume.vmin + volume.vmax) / 2 : volume.vmin + 0.25 * (volume.vmax - volume.vmin)
        let iso = IsoLevel(level: level, opacity: flow.isoLevels.isEmpty ? 1 : 0.5)
        flow.isoLevels.append(iso)
        computeIsosurface(iso.id)
    }

    // MARK: Calibration files

    func saveFlowCalibrationAs() {
        let panel = NSSavePanel()
        panel.title = "Save Calibration"
        panel.nameFieldStringValue = "cp0_calibration.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try flow.calibration.save(url) } catch { show("Could not save the calibration", error) }
    }

    func loadFlowCalibration() {
        let panel = NSOpenPanel()
        panel.title = "Load Calibration"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var cal = try FlowCalibration.load(url)
            if let size = flow.calibration.sourceSize { cal.sourceSize = size }
            flow.calibration = cal
        } catch {
            show("Could not load the calibration", error)
        }
    }

    func importPlanePositionsCSV() {
        let panel = NSOpenPanel()
        panel.title = "Plane Positions"
        panel.message = "One x position per frame, in mm, one per line (or the first column)."
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .text]
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let values = text.split(whereSeparator: \.isNewline).compactMap { line -> Double? in
            let first = line.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\t" || $0 == " " }).first
            return first.flatMap { Double($0) }.map { $0 / 1000 }
        }
        guard values.count >= 2 else {
            alert = AppAlert(title: "No positions found", message: "The file needs at least two numbers, one per line.")
            return
        }
        flow.calibration.planes.mode = "csv"
        flow.calibration.planes.positions = values
    }

    // MARK: Export

    enum FlowExport { case isoGLB, isoOBJ, volumeNPZ, volumeVTI }

    func exportFlow(_ kind: FlowExport) {
        guard let folder = flow.volumeFolder else { return }
        let volumePath = folder.appendingPathComponent("volume.npz").path
        switch kind {
        case .volumeNPZ:
            saveCopy(of: folder.appendingPathComponent("volume.npz"), suggested: "cp0_volume.npz")
        case .volumeVTI:
            _ = jobs.submit(command: "flow-export", params: ["volume": .string(volumePath)], in: jobsRoot) { [weak self] item in
                guard item.status == .succeeded else { return }
                self?.saveCopy(of: item.workdir.appendingPathComponent("volume.vti"), suggested: "cp0_volume.vti")
            }
        case .isoGLB, .isoOBJ:
            let levels = flow.isoLevels.filter(\.visible).map { JSONValue.double($0.level) }
            guard !levels.isEmpty else {
                alert = AppAlert(title: "No isosurfaces", message: "Add at least one visible isosurface to export.")
                return
            }
            let glb = kind == .isoGLB
            _ = jobs.submit(command: "flow-iso", params: ["volume": .string(volumePath), "levels": .array(levels)], in: jobsRoot) { [weak self] item in
                guard item.status == .succeeded else { return }
                self?.saveCopy(of: item.workdir.appendingPathComponent(glb ? "iso.glb" : "iso.obj"),
                               suggested: glb ? "cp0_isosurfaces.glb" : "cp0_isosurfaces_mm.obj")
            }
        }
    }

    private func saveCopy(of source: URL, suggested: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            show("Could not export", error)
        }
    }

    // MARK: Project persistence

    func saveFlowState(toProject project: URL) throws {
        let folder = ProjectStore.toolURL(for: project, tool: "flow")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try flow.calibration.save(folder.appendingPathComponent("calibration.json"))
        let state = ["source": flow.sourceURL?.path ?? ""]
        try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("state.json"), options: .atomic)
    }

    func loadFlowState(fromProject project: URL) {
        flow.reset()
        let folder = ProjectStore.toolURL(for: project, tool: "flow")
        flow.calibration = (try? FlowCalibration.load(folder.appendingPathComponent("calibration.json"))) ?? FlowCalibration()
        if let data = try? Data(contentsOf: folder.appendingPathComponent("state.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let path = obj["source"], !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            Task { await flow.open(URL(fileURLWithPath: path)) }
        }
        if let job = jobs.jobs.first(where: { $0.command == "flow-reconstruct" && $0.status == .succeeded }) {
            loadFlowVolume(from: job)
        }
        self.project?.isDirty = false
    }
}
