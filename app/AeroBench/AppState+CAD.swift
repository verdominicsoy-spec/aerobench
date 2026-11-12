import AeroBenchKit
import AppKit
import UniformTypeIdentifiers

extension AppState {
    /// `adding` keeps the open files and shows the chosen ones with them.
    func openCADPanel(adding: Bool = false) {
        let panel = NSOpenPanel()
        panel.title = adding ? "Add Models" : "Open Models"
        panel.message = "STEP, IGES, STL, OBJ or glb. Several files open together."
        panel.allowedContentTypes = CADViewerModel.openableExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        openCAD((adding ? cad.fileURLs : []) + panel.urls.filter { !(adding && cad.fileURLs.contains($0)) })
    }

    func openCAD(_ url: URL) { openCAD([url]) }

    /// Opens models together in one scene: STL, OBJ and glb load directly;
    /// STEP and IGES are tessellated by the engine once per preset and cached.
    func openCAD(_ urls: [URL]) {
        if let bad = urls.first(where: { !CADViewerModel.openableExtensions.contains($0.pathExtension.lowercased()) }) {
            alert = AppAlert(title: "Cannot open \(bad.lastPathComponent)",
                             message: "The CAD Viewer opens STEP, IGES, STL, OBJ and glb files.")
            return
        }
        guard !urls.isEmpty else { return }
        // Edit Part works on the open STEP: leave it before other files take its place.
        if partEdit.on { exitPartEdit(reload: false) }
        cad.setFiles(urls)
        load(urls, done: [])
    }

    /// Takes a part out of the scene. With several files open, deleting a
    /// file's own part closes that file, so check and repair come back at one.
    func deleteCADPart(_ id: Int) {
        if cad.fileURLs.count > 1, let k = cad.model?.roots.firstIndex(where: { $0.id == id }) {
            var urls = cad.fileURLs
            urls.remove(at: k)
            openCAD(urls)
        } else {
            cad.remove(id)
        }
    }

    /// Re-opens the current files, after a preset or unit change.
    func reloadCAD() {
        if !cad.fileURLs.isEmpty { openCAD(cad.fileURLs) }
    }

    /// Loads the files one after another, then shows them together.
    private func load(_ urls: [URL], done: [(name: String, model: Model3D, fromCache: Bool)]) {
        guard cad.fileURLs == urls else { return }  // other files were opened meanwhile
        guard done.count < urls.count else {
            cad.setModel(Model3D.merged(done.map { ($0.name, $0.model) }), fromCache: done.allSatisfy(\.fromCache))
            return
        }
        let url = urls[done.count]
        let of = urls.count > 1 ? " (\(done.count + 1) of \(urls.count))" : ""
        let next: (Model3D, Bool) -> Void = { [weak self] model, cached in
            self?.load(urls, done: done + [(url.lastPathComponent, model, cached)])
        }
        if CADViewerModel.tessellatedExtensions.contains(url.pathExtension.lowercased()) {
            tessellate(url, among: urls, of, then: next)
        } else {
            loadModel(url, units: cad.meshUnits, fromCache: false, among: urls, of, then: next)
        }
    }

    private func tessellate(_ url: URL, among urls: [URL], _ of: String, then next: @escaping (Model3D, Bool) -> Void) {
        let preset = cad.preset
        if let cached = CADViewerModel.cacheURL(for: url, preset: preset),
           FileManager.default.fileExists(atPath: cached.path) {
            loadModel(cached, units: .metre, fromCache: true, among: urls, of, then: next)
            return
        }
        cad.status = .loading("Tessellating \(url.lastPathComponent) (\(preset.rawValue))\(of)…")
        cad.job = jobs.submit(
            command: "tessellate",
            params: ["path": .string(url.path), "preset": .string(preset.rawValue)],
            in: jobsRoot
        ) { [weak self] item in
            guard let self, self.cad.fileURLs == urls else { return }
            guard item.status == .succeeded else {
                self.cad.status = .failed(item.message ?? "Tessellation of \(url.lastPathComponent) \(item.status.rawValue)", item.detail)
                return
            }
            let glb = item.workdir.appendingPathComponent("model.glb")
            if let cached = CADViewerModel.cacheURL(for: url, preset: preset) {
                try? FileManager.default.createDirectory(at: CADViewerModel.cacheFolder, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: cached)
                try? FileManager.default.copyItem(at: glb, to: cached)
            }
            self.loadModel(glb, units: .metre, fromCache: false, among: urls, of, then: next)
        }
    }

    private func loadModel(_ url: URL, units: LengthUnit, fromCache: Bool, among urls: [URL], _ of: String,
                           then next: @escaping (Model3D, Bool) -> Void) {
        cad.status = .loading("Reading \(url.lastPathComponent)\(of)…")
        Task {
            do {
                let model = try await Task.detached(priority: .userInitiated) {
                    try ModelLoader.load(url, units: units)
                }.value
                guard self.cad.fileURLs == urls else { return }  // other files were opened meanwhile
                next(model, fromCache)
            } catch {
                guard self.cad.fileURLs == urls else { return }
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
            self.saveRepaired(item, name: name, beside: url)
        }
    }

    /// Asks where to save a repair job's output, then opens it.
    /// `beforeOpen` runs only once the file is saved, just before it opens.
    func saveRepaired(_ item: JobItem, name: String, beside source: URL, beforeOpen: (() -> Void)? = nil) {
        let panel = NSSavePanel()
        panel.title = "Save Repaired File"
        panel.nameFieldStringValue = name
        panel.directoryURL = source.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: item.workdir.appendingPathComponent(name), to: dest)
            beforeOpen?()
            openCAD(dest)
        } catch {
            show("Could not save the repaired file", error)
        }
    }

    // MARK: Repair to one body

    /// Saved accept and skip choices live beside the source, so the next
    /// revision of the same CAD needs almost no clicking.
    private func bodyDecisionsURL(_ source: URL) -> URL {
        source.deletingPathExtension().appendingPathExtension("repair.json")
    }

    /// The plan run: fixes what is safe, returns the queue. With nothing
    /// to review its output is final, so it goes straight to saving.
    func planBodyRepair() {
        guard let url = cad.fileURL, cad.isStep else { return }
        cad.setBodyPlan(nil)
        var params: [String: JSONValue] = ["path": .string(url.path), "limit_mm": .double(cad.bodyLimitMM)]
        let saved = bodyDecisionsURL(url)
        if FileManager.default.fileExists(atPath: saved.path) { params["decisions"] = .string(saved.path) }
        cad.bodyJob = jobs.submit(command: "cad-repair-body", params: params, in: jobsRoot) { [weak self] item in
            guard let self, self.cad.fileURL == url, item.status == .succeeded, let text = item.resultText else { return }
            do {
                let plan = try BodyRepairResult.decode(resultFile: Data(text.utf8))
                self.cad.setBodyPlan(plan)
                if self.cad.pendingBodyItems == 0 {  // nothing to decide: this output is final
                    self.cad.bodySummary = Self.describe(plan)
                    self.saveRepaired(item, name: plan.output, beside: url)
                }
            } catch {
                self.show("Could not read the repair plan", error)
            }
        }
    }

    /// Saves the decisions beside the source, then reruns from the
    /// original file with the accepted items.
    func applyBodyRepair() {
        guard let url = cad.fileURL, cad.isStep, let plan = cad.bodyPlan else { return }
        let decided = plan.items.filter(\.reviewable).compactMap { item -> [String: Any]? in
            guard let accepted = cad.bodyDecisions[item.id] else { return nil }
            return ["kind": item.kind, "part": item.part, "centre_mm": item.centreMM, "size_mm": item.sizeMM as Any,
                    "decision": accepted ? "accept" : "skip"]
        }
        // Keep decisions for things not in this run (another part, a gap fixed since), replacing only
        // the ones this run decided again: same kind and part within 3 mm.
        var kept: [[String: Any]] = []
        if let data = try? Data(contentsOf: bodyDecisionsURL(url)),
           let old = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["decisions"] as? [[String: Any]] {
            kept = old.filter { o in
                guard let c = o["centre_mm"] as? [Double], c.count == 3 else { return false }
                return !decided.contains { d in
                    guard (d["kind"] as? String) == (o["kind"] as? String), (d["part"] as? String) == (o["part"] as? String),
                          let e = d["centre_mm"] as? [Double], e.count == 3 else { return false }
                    return sqrt(zip(c, e).map { ($0 - $1) * ($0 - $1) }.reduce(0, +)) <= 3
                }
            }
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "decisions": kept + decided],
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: bodyDecisionsURL(url))
        } catch {
            show("Could not save the repair decisions", error)  // the repair itself still runs
        }
        let accept = plan.items.filter { cad.bodyDecisions[$0.id] == true }.map { JSONValue.string($0.id) }
        // The plan's own limit, so gaps are sorted as they were when the user decided.
        cad.bodyJob = jobs.submit(command: "cad-repair-body", params: [
            "path": .string(url.path), "limit_mm": .double(plan.limitMM), "accept": .array(accept),
        ], in: jobsRoot) { [weak self] item in
            guard let self, item.status == .succeeded, let text = item.resultText else { return }
            do {
                let done = try BodyRepairResult.decode(resultFile: Data(text.utf8))
                self.cad.setBodyPlan(done)
                self.cad.bodySummary = Self.describe(done)
                // Closing a gap can uncover a new one: show it rather than save past it.
                if self.cad.pendingBodyItems == 0 {
                    self.saveRepaired(item, name: done.output, beside: url)
                }
            } catch {
                self.show("Could not read the repair result", error)
            }
        }
    }

    private static func describe(_ r: BodyRepairResult) -> String {
        var fixed: [String] = []
        if r.auto.partsSewn > 0 {
            fixed.append("\(r.auto.partsSewn) of \(r.auto.parts) parts sewn"
                         + (r.auto.maxSewMM.map { String(format: " (up to %.2g mm)", $0) } ?? ""))
        }
        if r.auto.smallEdgesRemoved > 0 { fixed.append("\(r.auto.smallEdgesRemoved) tiny edges removed") }
        if r.auto.smallFacesRemoved > 0 { fixed.append("\(r.auto.smallFacesRemoved) sliver faces removed") }
        let head = fixed.isEmpty ? "Nothing needed fixing automatically." : fixed.joined(separator: ", ") + "."
        if r.result.closed {
            return head + " One closed body, \(r.result.solids) solid\(r.result.solids == 1 ? "" : "s")."
        }
        var left: [String] = []
        if !r.result.fused { left.append("the fuse failed, so overlapping parts are not merged") }
        if !r.result.openParts.isEmpty { left.append("open: " + r.result.openParts.joined(separator: ", ")) }
        if r.result.nonmanifoldEdges > 0 { left.append("\(r.result.nonmanifoldEdges) edges shared by 3+ faces") }
        if !r.result.valid { left.append("fails OpenCascade's validity check") }
        return head + " Not one closed body: " + left.joined(separator: "; ") + "."
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
