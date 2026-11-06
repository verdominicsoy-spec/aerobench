import AeroBenchKit
import AppKit
import SwiftUI
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
    /// Every section's maximum lift and best L/D at the main element's
    /// Reynolds number: a few seconds for the whole library.
    func computeLibraryPolars() {
        let re = wingLab.libraryRe
        wingLab.polarsJob = jobs.submit(command: "airfoil-polars", params: ["re": .double(re), "n_crit": .double(wingLab.nCrit)],
                                        in: jobsRoot) { [weak self] item in
            guard let self, item.status == .succeeded, let dir = self.settings.engineDirectory else { return }
            self.wingLab.libraryPolars = AirfoilLibrary.Polars.load(AirfoilLibrary.Polars.url(engineDirectory: dir))
            if self.wingLab.librarySort == .name { self.wingLab.librarySort = .clMax }
        }
    }

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

    /// Deletes the user's own imported sections, after asking.
    func deleteAirfoils(_ airfoils: [Airfoil]) {
        let mine = airfoils.filter { $0.source == "mine" }
        guard !mine.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = mine.count == 1 ? "Delete \(mine[0].name) from My Airfoils?" : "Delete \(mine.count) sections from My Airfoils?"
        alert.informativeText = "The imported .dat file is removed. Wings already using it keep their copy."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let keys = JSONValue.array(mine.map { .string($0.key) })
        wingLab.libraryJob = jobs.submit(command: "airfoil-delete", params: ["keys": keys], in: jobsRoot) { [weak self] item in
            guard let self, item.status == .succeeded else { return }
            for a in mine { self.wingLab.favourites.remove(a.key) }
            self.wingLab.loadLibrary(engineDirectory: self.settings.engineDirectory)
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

    /// One A4 PDF page with the wing, its conditions and every solver's latest answer.
    func exportWingReport() {
        let lab = wingLab
        guard !lab.wing.elements.isEmpty else { return }
        let field = lab.ransField
        let scalar = field?.scalars.first { $0.key == lab.fieldScalar } ?? field?.scalars.first
        let title = project.map { "\($0.url.deletingPathExtension().lastPathComponent): wing" } ?? "Wing"
        let page = WingReportView(title: title, wing: lab.wing, preview: lab.preview, estimate: lab.estimate,
                                  rans: lab.ransResult, field: field, fieldScalar: scalar,
                                  fieldImage: scalar.flatMap { lab.fieldImage($0.key) })
        let panel = NSSavePanel()
        panel.title = "Export Wing Report"
        panel.nameFieldStringValue = "wing_report.pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let renderer = ImageRenderer(content: page)
        var ok = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            pdf.beginPDFPage(nil)
            draw(pdf)
            pdf.endPDFPage()
            pdf.closePDF()
            ok = true
        }
        if !ok { show("Could not export the report", WingLabError("The PDF could not be written to \(url.path).")) }
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

    /// A quick viscous polar of the selected element (NeuralFoil), at its own
    /// chord's Reynolds number, over the angle range set in the inspector.
    func runWingPolar() {
        let lab = wingLab
        guard let i = lab.selection, lab.wing.elements.indices.contains(i) else { return }
        let e = lab.wing.elements[i]
        let coords = JSONValue.array(e.airfoil.coords.map { .array([.double($0.x), .double($0.y)]) })
        let params: [String: JSONValue] = [
            "coords": coords, "re": .double(lab.wing.reynolds(chord: e.chord)), "n_crit": .double(lab.nCrit),
            "alpha_start": .double(lab.alphaStart), "alpha_end": .double(lab.alphaEnd), "alpha_step": .double(lab.alphaStep),
            "inverted": .bool(e.inverted),
        ]
        lab.polar = nil
        lab.polarElement = i
        lab.resultsTab = .polar
        lab.polarJob = jobs.submit(command: "wing-polar", params: params, in: jobsRoot, onFinish: forThisProject { [weak self] item in
            guard let self, item.status == .succeeded, let text = item.resultText else { return }
            self.wingLab.polar = try? WingPolar.decode(resultFile: Data(text.utf8))
        })
    }

    /// Meshes the wing and runs SU2 on it (on the Solvers mesh, or `mesh`).
    func runWingRANS(mesh: String? = nil) {
        let lab = wingLab
        let wing = lab.wing
        guard !wing.elements.isEmpty else { return }
        var params = ransParams()
        params["elements"] = elementsParam()
        if let mesh { params["mesh"] = .string(mesh) }
        lab.ransResult = nil
        lab.ransField = nil
        lab.resultsTab = .cfd
        lab.ransJob = jobs.submit(command: "wing-rans", params: params, in: jobsRoot, onFinish: forThisProject { [weak self] in self?.showRans($0) })
    }

    /// Shows a finished wing-rans run and keeps it with the project, so a reopened project shows it again.
    private func showRans(_ item: JobItem) {
        guard item.status == .succeeded, let text = item.resultText else { return }
        wingLab.ransResult = try? WingRansResult.decode(resultFile: Data(text.utf8))
        wingLab.ransFolder = item.workdir
        wingLab.ransField = wingLab.ransResult?.fieldView == nil ? nil : try? WingField.load(from: item.workdir)
        if let project, wingLab.ransResult != nil { try? WingRansResult.saveRun(folder: item.workdir, project: project.url) }
    }

    /// The mesh a RANS run would use, for the Mesh canvas: same settings, no SU2.
    func runWingMesh() {
        let lab = wingLab
        let wing = lab.wing
        guard !wing.elements.isEmpty else { return }
        var params = ransParams()
        params["elements"] = elementsParam()
        let level = lab.meshLevel
        lab.meshJob = jobs.submit(command: "wing-mesh", params: params, in: jobsRoot, onFinish: forThisProject { item in
            guard item.status == .succeeded else { return }
            let url = item.workdir.appendingPathComponent("wing.su2")
            let stats = item.resultData?["mesh"] as? [String: Any]
            Task.detached {
                guard let text = try? String(contentsOf: url, encoding: .utf8), let mesh = try? SU2Mesh.parse(text) else { return }
                let path = CGMutablePath()
                for cell in mesh.cells where cell.allSatisfy(mesh.points.indices.contains) {
                    path.addLines(between: cell.map { CGPoint(x: mesh.points[$0].x, y: mesh.points[$0].y) })
                    path.closeSubpath()
                }
                let shape = path.copy()
                await MainActor.run {
                    lab.mesh = mesh
                    lab.meshPath = shape
                    lab.meshOf = wing
                    let n = { (k: String) in (stats?[k] as? Int).map { $0.formatted() } ?? "?" }
                    lab.meshInfo = "\(level.capitalized) mesh: \(n("cells")) cells (\(n("quads")) quads, \(n("triangles")) triangles), \(n("layers")) wall layers"
                }
            }
        })
    }

    /// Flow and solver settings shared by a RANS run and every optimiser trial
    /// (the canvas wing's, or another's: A when comparing).
    func ransParams(_ other: Wing? = nil) -> [String: JSONValue] {
        let lab = wingLab
        let wing = other ?? lab.wing
        return [
            "speed": .double(wing.speed), "rho": .double(wing.rho), "mu": .double(wing.mu),
            "alpha": .double(wing.alpha), "ref_chord": .double(wing.refChord),
            "model": .string(lab.turbulenceModel.rawValue), "mesh": .string(lab.meshLevel),
            "transition": lab.predictTransition ? .string("auto") : .array(wing.elements.map { _ in .array([.double(0), .double(0)]) }),
            "turbulence_intensity": .double(lab.turbulenceIntensity / 100), "n_crit": .double(lab.nCrit),
            "ride_height": wing.rideHeight.map { .double($0) } ?? .null,
        ]
    }

    /// The placed and unit coordinates of every element, as the RANS,
    /// sweep and estimate commands read them.
    private func elementsParam(_ other: Wing? = nil) -> JSONValue {
        func points(_ p: [SIMD2<Double>]) -> JSONValue { .array(p.map { .array([.double($0.x), .double($0.y)]) }) }
        return .array((other ?? wingLab.wing).elements.map { e in
            .object(["coords": points(e.placed()), "unit": points(e.airfoil.coords), "angle": .double(e.angle),
                     "inverted": .bool(e.inverted), "chord": .double(e.chord)])
        })
    }

    /// Starts the optimiser, or resumes the study of the same name: the
    /// engine picks up where the study file left off.
    func runWingOptimise() {
        let lab = wingLab
        let wing = lab.wing
        if let problem = lab.optimiseProblem {
            show("The study cannot start", WingLabError(problem))
            return
        }
        saveProject()
        func pair(_ p: SIMD2<Double>) -> JSONValue { .array([.double(p.x), .double(p.y)]) }
        let setup = lab.optimise
        var params = ransParams()
        params["elements"] = .array(wing.elements.map { e in
            .object(["unit": .array(e.airfoil.coords.map(pair)), "chord": .double(e.chord), "angle": .double(e.angle),
                     "leading_edge": pair(e.leadingEdge), "inverted": .bool(e.inverted)])
        })
        params["min_gap"] = .double(wing.minGap)
        if let b = wing.rulesBox {
            params["rules_box"] = .array([.double(b.minX), .double(b.minY), .double(b.maxX), .double(b.maxY)])
        }
        params["variables"] = .array(setup.variables.map { v in
            var o: [String: JSONValue] = ["element": .int(v.element), "kind": .string(v.kind.rawValue),
                                          "low": .double(v.low * v.engineScale), "high": .double(v.high * v.engineScale)]
            if let c = v.choices { o["choices"] = .array(c.map { .string($0) }) }
            return .object(o)
        })
        params["objective"] = .string(setup.objective.rawValue)
        params["cd_cap"] = .double(setup.cdCap)
        params["cl_target"] = .double(setup.clTarget)
        params["sampler"] = .string(setup.sampler)
        params["trials"] = .int(setup.trials)
        params["parallel"] = .int(settings.parallelTrials)
        params["solver"] = .string(setup.solver)
        params["check"] = .int(setup.solver == "estimate" ? setup.checkBest : 0)
        // Stop checking once RANS confirms a design (the next is only a fallback).
        // No calibration run: the check measures the estimate on the wing that
        // matters, and waiting for it cost a minute without changing the pick.
        params["until_pass"] = .bool(setup.untilPass)
        if setup.objective == .minLapTime {
            do {
                params["lap"] = try lapObjectiveParams()
            } catch {
                show("The study cannot start", error)
                return
            }
        }
        let file = WingLabModel.studyFile(project: workFolder, name: setup.studyName)
        // The wing it starts from, once: a resumed study keeps its first start.
        let start = WingLabModel.startFile(project: workFolder, name: setup.studyName)
        if !FileManager.default.fileExists(atPath: start.path), let data = try? AeroJSON.encoder().encode(wing) {
            try? FileManager.default.createDirectory(at: start.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: start, options: .atomic)
        }
        params["storage"] = .string(file.path)
        params["name"] = .string(file.deletingPathExtension().lastPathComponent)
        lab.resultsTab = .study
        let job = jobs.submit(command: "wing-optimise", params: params, in: jobsRoot, onFinish: forThisProject { [weak self] item in
            guard let self else { return }
            if item.status == .succeeded, let text = item.resultText, let s = try? WingStudy.decode(resultFile: Data(text.utf8)) {
                self.wingLab.study = s
            } else {
                self.wingLab.reloadStudy(project: self.workFolder)
            }
            self.wingLab.designStage = nil
            if setup.loadBest { self.loadStudyBest(succeeded: item.status == .succeeded) }
        })
        lab.optimiseJob = job
        // The engine rewrites the export after every trial; follow it.
        let export = file.deletingPathExtension().appendingPathExtension("json")
        let folder = workFolder
        Task { @MainActor [weak self] in
            var seen: Date?
            while !job.status.isFinished {
                try? await Task.sleep(for: .seconds(2))
                guard self?.workFolder == folder else { return }  // another project is open: its study is not this
                let date = (try? FileManager.default.attributesOfItem(atPath: export.path)[.modificationDate]) as? Date
                guard let self, let date, date != seen else { continue }
                seen = date
                if let data = try? Data(contentsOf: export), let s = try? WingStudy.decode(exportFile: data) {
                    self.wingLab.study = s
                }
            }
        }
    }

    func estimateParams(_ other: Wing? = nil) -> [String: JSONValue] {
        let lab = wingLab
        let wing = other ?? lab.wing
        var params = ransParams(wing)
        params["elements"] = elementsParam(wing)
        var angles = lab.estimateAngles
        if !angles.contains(where: { abs($0 - wing.alpha) < 1e-9 }) { angles = (angles + [wing.alpha]).sorted() }
        params["alphas"] = .array(angles.map { .double($0) })
        return params
    }

    /// Live estimate: the same estimate through the warm engine (about 30 ms
    /// once loaded), at most one request at a time; changes made while one
    /// runs are picked up by the next, so dragging shows the latest wing.
    func scheduleLiveEstimate() {
        let lab = wingLab
        guard lab.liveEstimate, !lab.wing.elements.isEmpty,
              lab.wing.issues.allSatisfy({ $0.kind == .outsideRules }) else { return }
        if lab.liveBusy {
            lab.liveDirty = true
            return
        }
        guard let executable = settings.engineExecutable else {
            lab.liveStatus = "Set the engine folder in Settings"
            return
        }
        if lab.warmEngine == nil { lab.warmEngine = WarmEngine(executableURL: executable) }
        guard let engine = lab.warmEngine else { return }
        lab.liveBusy = true
        if lab.estimate == nil { lab.liveStatus = "Loading the engine (a few seconds, once)" }
        Task { @MainActor in
            repeat {
                lab.liveDirty = false
                let params = JSONValue.object(estimateParams())
                do {
                    let data = try await engine.request("wing-estimate", params: params)
                    lab.estimate = try WingEstimate.decode(resultFile: data)
                    lab.liveStatus = nil
                } catch {
                    lab.liveStatus = error.localizedDescription
                }
            } while lab.liveDirty && lab.liveEstimate
            lab.liveBusy = false
        }
    }

    /// RANS on the quick mesh over a sweep of wing angles (inside 5 minutes;
    /// the engine skips angles that would run past it), or at the wing's angle.
    /// The one Run CFD: the wing's own angle, or the sweep of angles when Vary the angle is ticked.
    func runCFD() {
        if wingLab.sweepOn { runWingQuickEstimate() } else { runWingRANS() }
    }

    func runWingQuickEstimate() {
        let lab = wingLab
        let wing = lab.wing
        guard !wing.elements.isEmpty else { return }
        var params = ransParams()
        params["elements"] = elementsParam()
        params["mesh"] = .string(lab.sweepRising ? lab.meshLevel : "quick")
        lab.ransResult = nil
        lab.ransField = nil
        lab.resultsTab = .cfd
        guard lab.sweepOn else {
            lab.sweep = nil
            lab.ransJob = jobs.submit(command: "wing-rans", params: params, in: jobsRoot, onFinish: forThisProject { [weak self] in self?.showRans($0) })
            return
        }
        params["alphas"] = .array(lab.sweepAngles.map { .double($0) })
        params["time_limit"] = .double(lab.sweepRising ? 0 : wing.rideHeight == nil ? 300 : 900)  // over a ground each angle is meshed and solved from rest
        if lab.sweepRising { params["order"] = .string("rising") }
        lab.sweep = nil
        lab.sweepRow = nil
        lab.sweepJob = jobs.submit(command: "wing-sweep", params: params, in: jobsRoot, onFinish: forThisProject { [weak self] item in
            guard let self, item.status == .succeeded, let text = item.resultText,
                  let s = try? WingSweep.decode(resultFile: Data(text.utf8)) else { return }
            self.wingLab.sweep = s
            self.wingLab.sweepFolder = item.workdir
            // Start on the angle nearest the wing's own.
            let near = s.rows.indices.min { abs((s.rows[$0].alpha ?? 0) - wing.alpha) < abs((s.rows[$1].alpha ?? 0) - wing.alpha) }
            if let near { self.wingLab.showSweepRow(near) }
        })
    }

    /// Builds SU2 from source into the repo's build/su2 (once, 10 to 20 minutes).
    func installSU2() {
        wingLab.su2Job = jobs.submit(command: "su2-install", in: jobsRoot)
    }

    /// Car B becomes car A with this wing in place of the one it replaces,
    /// and the Lap Sim compares the two.
    // MARK: Design a wing

    private struct ShortlistResult: Decodable {
        struct Entry: Decodable {
            var key: String
            var name: String
        }
        var shortlists: [[Entry]]
    }

    /// Each element's sections to choose between: its own, then the library's
    /// best by maximum lift at that element's Reynolds number (a few seconds an element).
    func findShortlists() {
        let lab = wingLab
        let wing = lab.wing
        guard !wing.elements.isEmpty, !(lab.shortlistJob.map { !$0.status.isFinished } ?? false) else { return }
        let params: [String: JSONValue] = [
            "chords": .array(wing.elements.map { .double($0.chord) }),
            "current": .array(wing.elements.map { .string($0.airfoil.key) }),
            "speed": .double(wing.speed), "rho": .double(wing.rho), "mu": .double(wing.mu),
            "n_crit": .double(lab.nCrit), "min_thickness": .double(lab.design.minThickness / 100),
        ]
        lab.shortlistJob = jobs.submit(command: "wing-shortlist", params: params, in: jobsRoot, onFinish: forThisProject { [weak self] item in
            guard let self else { return }
            let d = JSONDecoder()
            d.keyDecodingStrategy = .convertFromSnakeCase
            struct Wrapper: Decodable { var data: ShortlistResult }
            guard item.status == .succeeded, let text = item.resultText,
                  let r = try? d.decode(Wrapper.self, from: Data(text.utf8)).data else {
                if item.status == .failed { self.show("Could not find sections", WingLabError(item.message ?? "The shortlist failed.")) }
                return
            }
            self.wingLab.setShortlists(Dictionary(uniqueKeysWithValues: r.shortlists.enumerated().map { ($0.offset, $0.element.map(\.key)) }))
        })
    }

    // MARK: Start against best

    /// The wing a study started from: saved beside it, or for a study from
    /// before that, rebuilt from its first optimise job's input on the canvas wing.
    func studyStartWing(_ name: String) -> Wing? {
        let file = WingLabModel.startFile(project: workFolder, name: name)
        if let data = try? Data(contentsOf: file), let wing = try? AeroJSON.decoder().decode(Wing.self, from: data) { return wing }
        struct Job: Decodable {
            struct Element: Decodable { var unit: [[Double]]; var chord, angle: Double; var leading_edge: [Double]; var inverted: Bool }
            struct Params: Decodable { var name: String?; var alpha: Double?; var elements: [Element]? }
            var command: String
            var params: Params
        }
        let folders = (try? FileManager.default.contentsOfDirectory(at: jobsRoot, includingPropertiesForKeys: nil)) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {  // ids start with the date: first run first
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("job.json")),
                  let job = try? JSONDecoder().decode(Job.self, from: data),
                  job.command == "wing-optimise", job.params.name == name, let elements = job.params.elements else { continue }
            var wing = wingLab.wing
            wing.alpha = job.params.alpha ?? wing.alpha
            wing.elements = elements.enumerated().map { i, e in
                let coords = e.unit.compactMap { $0.count == 2 ? SIMD2($0[0], $0[1]) : nil }
                // The canvas section's name when it is the same shape, else a plain one.
                let same = wingLab.wing.elements.indices.contains(i) && wingLab.wing.elements[i].airfoil.coords == coords
                let airfoil = same ? wingLab.wing.elements[i].airfoil : Airfoil(
                    key: "start/\(name)/\(i)", name: "\(WingIssue.label(i)) at the start", family: "", source: "study",
                    thickness: (coords.map(\.y).max() ?? 0) - (coords.map(\.y).min() ?? 0), thicknessX: 0.3,
                    camber: 0, camberX: 0.4, teThickness: 0, coords: coords)
                return WingElement(airfoil: airfoil, chord: e.chord, angle: e.angle,
                                   leadingEdge: SIMD2(e.leading_edge[0], e.leading_edge[1]), inverted: e.inverted)
            }
            return wing
        }
        return nil
    }

    /// The start as A and the best as B: every A/B view (outlines, Cp, the
    /// estimate charts, the A card's differences) then shows what changed.
    func compareStartAndBest() {
        let lab = wingLab
        guard let s = lab.study, let start = studyStartWing(s.study) else {
            show("No starting wing", WingLabError("The study's starting wing was not saved and no optimise job for it was found."))
            return
        }
        let pick = s.bestCheck.flatMap { c in s.trials.first { $0.number == c.number } } ?? s.bestTrial
        guard let best = pick else { return }
        lab.edit { $0 = start }
        lab.markOrigin("\(s.study) · start")
        lab.pinCurrent()
        lab.load(trial: best)
        estimate(for: start) { [weak self] est in
            guard let self, self.wingLab.pinned?.wing == start else { return }
            self.wingLab.pinned?.estimate = est
        }
    }

    /// One estimate of any wing through the warm engine (A's, when B is on the canvas).
    private func estimate(for wing: Wing, then done: @escaping (WingEstimate) -> Void) {
        let lab = wingLab
        guard let executable = settings.engineExecutable else { return }
        if lab.warmEngine == nil { lab.warmEngine = WarmEngine(executableURL: executable) }
        guard let engine = lab.warmEngine else { return }
        let params = JSONValue.object(estimateParams(wing))
        Task { @MainActor in
            if let data = try? await engine.request("wing-estimate", params: params),
               let est = try? WingEstimate.decode(resultFile: data) { done(est) }
        }
    }

    /// RANS on A and on B at once, on the quick mesh (within 0.3% of medium,
    /// about a minute and a half each), for their fields and the change between them.
    func runCFDOnBoth() {
        let lab = wingLab
        guard let a = lab.pinned else { return }
        runWingRANS(mesh: "quick")
        var params = ransParams(a.wing)
        params["elements"] = elementsParam(a.wing)
        params["mesh"] = .string("quick")
        lab.pinnedRansJob = jobs.submit(command: "wing-rans", params: params, in: jobsRoot, onFinish: forThisProject { [weak self] item in
            guard let self, item.status == .succeeded, let text = item.resultText,
                  self.wingLab.pinned?.wing == a.wing else { return }
            let r = try? WingRansResult.decode(resultFile: Data(text.utf8))
            self.wingLab.pinned?.rans = r
            self.wingLab.pinned?.field = r?.fieldView == nil ? nil : try? WingField.load(from: item.workdir)
        })
    }

    /// The study's best on the canvas: RANS's pick if it checked any, else the estimate's.
    func loadStudyBest(succeeded: Bool) {
        let lab = wingLab
        guard succeeded, let s = lab.study else { return }
        let pick = s.bestCheck.flatMap { c in s.trials.first { $0.number == c.number } } ?? s.bestTrial
        if let pick { lab.load(trial: pick) }
    }

    func nextDesignName() -> String {
        var n = 1
        // A design run writes its starting wing beside the study before the study exists: a name with either is taken.
        func taken(_ n: Int) -> Bool {
            let db = WingLabModel.studyFile(project: workFolder, name: "design-\(n)")
            return FileManager.default.fileExists(atPath: db.path)
                || FileManager.default.fileExists(atPath: db.deletingPathExtension().appendingPathExtension("design.json").path)
        }
        while taken(n) { n += 1 }
        return "design-\(n)"
    }

    /// Every finished RANS run of the wing as drawn (each element within a millimetre, the same ride
    /// height and model), one point per wing angle, the latest run at each: the CFD tab's polar when
    /// no sweep has run. Single runs at a few angles draw the curves.
    var ransPolar: [PolarCharts.Point] {
        let lab = wingLab
        let done = jobs.jobs.filter { $0.command == "wing-rans" && $0.status == .succeeded }
        let key = "\(done.count)|\(done.last?.id ?? "")|\(lab.turbulenceModel.rawValue)|\(lab.wing.rideHeight ?? -1)"
        if let c = lab.ransPolarCache, c.key == key, c.wing == lab.wing.elements { return c.points }
        let outlines = lab.wing.elements.map { $0.placed() }
        var byAngle: [Double: PolarCharts.Point] = [:]
        for job in done.sorted(by: { $0.created < $1.created }) {
            guard let text = job.resultText, let r = try? WingRansResult.decode(resultFile: Data(text.utf8)),
                  r.model == lab.turbulenceModel.rawValue, r.matches(outlines) else { continue }
            let a = ((r.alpha ?? 0) * 10).rounded() / 10
            byAngle[a] = .init(alpha: a, cl: r.cl, cd: r.cd, good: r.converged)
        }
        let points = byAngle.values.sorted { $0.alpha < $1.alpha }
        lab.ransPolarCache = (key, lab.wing.elements, points)
        return points
    }

    /// Whether more cells would make this run more accurate or reliable: its wall y+, and this wing's
    /// finished runs at the same angle on other mesh levels.
    func meshAdvice(_ r: WingRansResult) -> MeshAdvice {
        let lab = wingLab
        let done = jobs.jobs.filter { $0.command == "wing-rans" && $0.status == .succeeded }
        let key = "\(done.count)|\(done.first?.id ?? "")|\(r.meshLevel)|\(r.cl)|\(r.cd)|\(r.alpha ?? 0)"
        if let c = lab.meshAdviceCache, c.key == key { return c.advice }
        let outlines = lab.wing.elements.map { $0.placed() }
        let others = done.compactMap { job -> WingRansResult? in
            guard let text = job.resultText, let o = try? WingRansResult.decode(resultFile: Data(text.utf8)) else { return nil }
            return o.meshLevel != r.meshLevel && o.converged && r.sameCase(as: o, sameWing: o.matches(outlines)) ? o : nil
        }
        let advice = r.meshAdvice(others: others)
        lab.meshAdviceCache = (key, advice)
        return advice
    }

    /// The same wing again on `level`: one finer, to compare the two, or its own, to mesh the walls again.
    func runCFDOnMesh(_ level: String) {
        wingLab.meshLevel = level
        runCFD()
    }

    /// The fastest-lap objective races the Lap Sim's car A, with this wing in
    /// place of the one it replaces, around the Lap Sim's track.
    func lapObjectiveParams() throws -> JSONValue {
        let wing = wingLab.wing
        let lap = try lapSim.jobParams(lapsimFolder: lapSimFolder)
        var out: [String: JSONValue] = [
            "car": lap["car"] ?? .null, "track": lap["track"] ?? .null,
            "ds": lap["ds"] ?? .double(0.5), "start_speed": lap["start_speed"] ?? .double(0), "span": .double(wing.span),
            "factor": .double(wing.factor3D), "replaced_cla": .double(wingLab.replacedCla),
            "replaced_cda": .double(wingLab.replacedCda),
        ]
        if let h = wing.endplateHeight { out["endplate"] = .double(h) }
        return .object(out)
    }

    /// Puts this wing on a Lap Sim car in place of the one it replaces: car
    /// `index`, or a new car copied from A when nil. Returns the car's label.
    @discardableResult
    func sendWingToLapSim(cl: Double, cd: Double, replacedCla: Double, replacedCda: Double, into index: Int?) -> String {
        let add = wingLab.wing.carContribution(cl: cl, cd: cd)
        let i = index ?? lapSim.cars.count
        var car = index.map { lapSim.cars[$0] } ?? lapSim.carA
        car.cla = max(car.cla - replacedCla + add.cla, 0)
        car.cda = max(car.cda - replacedCda + add.cda, 0)
        if i < lapSim.cars.count { lapSim.cars[i] = car } else { lapSim.cars.append(car) }
        return LapSimSetup.labels[i]
    }
}

struct WingLabError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
