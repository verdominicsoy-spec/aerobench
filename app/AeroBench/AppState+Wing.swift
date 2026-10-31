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
        lab.polarJob = jobs.submit(command: "wing-polar", params: params, in: jobsRoot) { [weak self] item in
            guard let self, item.status == .succeeded, let text = item.resultText else { return }
            self.wingLab.polar = try? WingPolar.decode(resultFile: Data(text.utf8))
        }
    }

    /// Meshes the wing and runs SU2 on it.
    func runWingRANS() {
        let lab = wingLab
        let wing = lab.wing
        guard !wing.elements.isEmpty else { return }
        func points(_ p: [SIMD2<Double>]) -> JSONValue { .array(p.map { .array([.double($0.x), .double($0.y)]) }) }
        let elements = JSONValue.array(wing.elements.map { e in
            .object(["coords": points(e.placed()), "unit": points(e.airfoil.coords), "angle": .double(e.angle),
                     "inverted": .bool(e.inverted), "chord": .double(e.chord)])
        })
        var params = ransParams()
        params["elements"] = elements
        lab.ransResult = nil
        lab.ransField = nil
        lab.resultsTab = .cfd
        lab.ransJob = jobs.submit(command: "wing-rans", params: params, in: jobsRoot) { [weak self] item in
            guard let self, item.status == .succeeded, let text = item.resultText else { return }
            self.wingLab.ransResult = try? WingRansResult.decode(resultFile: Data(text.utf8))
            self.wingLab.ransFolder = item.workdir
            self.wingLab.ransField = self.wingLab.ransResult?.fieldView == nil ? nil : try? WingField.load(from: item.workdir)
        }
    }

    /// Flow and solver settings shared by a RANS run and every optimiser trial.
    private func ransParams() -> [String: JSONValue] {
        let lab = wingLab
        let wing = lab.wing
        return [
            "speed": .double(wing.speed), "rho": .double(wing.rho), "mu": .double(wing.mu),
            "alpha": .double(wing.alpha), "ref_chord": .double(wing.refChord),
            "model": .string(lab.turbulenceModel.rawValue), "mesh": .string(lab.meshLevel),
            "transition": lab.predictTransition ? .string("auto") : .array(wing.elements.map { _ in .array([.double(0), .double(0)]) }),
            "turbulence_intensity": .double(lab.turbulenceIntensity / 100), "n_crit": .double(lab.nCrit),
        ]
    }

    /// Starts the optimiser, or resumes the study of the same name: the
    /// engine picks up where the study file left off.
    func runWingOptimise() {
        let lab = wingLab
        let wing = lab.wing
        guard let project else {
            show("Save the project first", WingLabError("Studies are stored in the project, so they can be resumed."))
            return
        }
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
            .object(["element": .int(v.element), "kind": .string(v.kind.rawValue),
                     "low": .double(v.low * v.engineScale), "high": .double(v.high * v.engineScale)])
        })
        params["objective"] = .string(setup.objective.rawValue)
        params["cd_cap"] = .double(setup.cdCap)
        params["cl_target"] = .double(setup.clTarget)
        params["sampler"] = .string(setup.sampler)
        params["trials"] = .int(setup.trials)
        params["parallel"] = .int(settings.parallelTrials)
        params["solver"] = .string(setup.solver)
        params["check"] = .int(setup.solver == "estimate" ? setup.checkBest : 0)
        if setup.objective == .minLapTime {
            do {
                params["lap"] = try lapObjectiveParams()
            } catch {
                show("The study cannot start", error)
                return
            }
        }
        let file = WingLabModel.studyFile(project: project.url, name: setup.studyName)
        params["storage"] = .string(file.path)
        params["name"] = .string(file.deletingPathExtension().lastPathComponent)
        lab.resultsTab = .study
        let job = jobs.submit(command: "wing-optimise", params: params, in: jobsRoot) { [weak self] item in
            guard let self else { return }
            if item.status == .succeeded, let text = item.resultText, let s = try? WingStudy.decode(resultFile: Data(text.utf8)) {
                self.wingLab.study = s
            } else {
                self.wingLab.reloadStudy(project: self.project?.url)
            }
            if self.wingLab.designAwaitingStudy { self.finishDesign(succeeded: item.status == .succeeded) }
        }
        lab.optimiseJob = job
        // The engine rewrites the export after every trial; follow it.
        let export = file.deletingPathExtension().appendingPathExtension("json")
        Task { @MainActor [weak self] in
            var seen: Date?
            while !job.status.isFinished {
                try? await Task.sleep(for: .seconds(2))
                let date = (try? FileManager.default.attributesOfItem(atPath: export.path)[.modificationDate]) as? Date
                guard let self, let date, date != seen else { continue }
                seen = date
                if let data = try? Data(contentsOf: export), let s = try? WingStudy.decode(exportFile: data) {
                    self.wingLab.study = s
                }
            }
        }
    }

    /// Quick estimate in seconds: the panel method and NeuralFoil, over the angle range.
    func runWingEstimate() {
        let lab = wingLab
        guard !lab.wing.elements.isEmpty else { return }
        lab.estimate = nil
        lab.resultsTab = .estimate
        lab.estimateJob = jobs.submit(command: "wing-estimate", params: estimateParams(), in: jobsRoot) { [weak self] item in
            guard let self, item.status == .succeeded, let text = item.resultText else { return }
            self.wingLab.estimate = try? WingEstimate.decode(resultFile: Data(text.utf8))
        }
    }

    private func estimateParams() -> [String: JSONValue] {
        let lab = wingLab
        let wing = lab.wing
        func points(_ p: [SIMD2<Double>]) -> JSONValue { .array(p.map { .array([.double($0.x), .double($0.y)]) }) }
        var params = ransParams()
        params["elements"] = .array(wing.elements.map { e in
            .object(["coords": points(e.placed()), "unit": points(e.airfoil.coords), "angle": .double(e.angle),
                     "inverted": .bool(e.inverted), "chord": .double(e.chord)])
        })
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

    func setLiveEstimate(_ on: Bool) {
        let lab = wingLab
        lab.liveEstimate = on
        if on {
            lab.resultsTab = .estimate
            scheduleLiveEstimate()
        } else {
            lab.warmEngine?.stop()
            lab.warmEngine = nil
            lab.liveStatus = nil
        }
    }

    /// RANS on the quick mesh over a sweep of wing angles (inside 5 minutes;
    /// the engine skips angles that would run past it), or at the wing's angle.
    func runWingQuickEstimate() {
        let lab = wingLab
        let wing = lab.wing
        guard !wing.elements.isEmpty else { return }
        func points(_ p: [SIMD2<Double>]) -> JSONValue { .array(p.map { .array([.double($0.x), .double($0.y)]) }) }
        var params = ransParams()
        params["elements"] = .array(wing.elements.map { e in
            .object(["coords": points(e.placed()), "unit": points(e.airfoil.coords), "angle": .double(e.angle),
                     "inverted": .bool(e.inverted), "chord": .double(e.chord)])
        })
        params["mesh"] = .string(lab.sweepRising ? lab.meshLevel : "quick")
        lab.ransResult = nil
        lab.ransField = nil
        lab.resultsTab = .cfd
        guard lab.sweepOn else {
            lab.sweep = nil
            lab.ransJob = jobs.submit(command: "wing-rans", params: params, in: jobsRoot) { [weak self] item in
                guard let self, item.status == .succeeded, let text = item.resultText else { return }
                self.wingLab.ransResult = try? WingRansResult.decode(resultFile: Data(text.utf8))
                self.wingLab.ransFolder = item.workdir
                self.wingLab.ransField = self.wingLab.ransResult?.fieldView == nil ? nil : try? WingField.load(from: item.workdir)
            }
            return
        }
        params["alphas"] = .array(lab.sweepAngles.map { .double($0) })
        params["time_limit"] = .double(lab.sweepRising ? 0 : 300)
        if lab.sweepRising { params["order"] = .string("rising") }
        lab.sweep = nil
        lab.sweepRow = nil
        lab.sweepJob = jobs.submit(command: "wing-sweep", params: params, in: jobsRoot) { [weak self] item in
            guard let self, item.status == .succeeded, let text = item.resultText,
                  let s = try? WingSweep.decode(resultFile: Data(text.utf8)) else { return }
            self.wingLab.sweep = s
            self.wingLab.sweepFolder = item.workdir
            // Start on the angle nearest the wing's own.
            let near = s.rows.indices.min { abs((s.rows[$0].alpha ?? 0) - wing.alpha) < abs((s.rows[$1].alpha ?? 0) - wing.alpha) }
            if let near { self.wingLab.showSweepRow(near) }
        }
    }

    /// Builds SU2 from source into the repo's build/su2 (once, 10 to 20 minutes).
    func installSU2() {
        wingLab.su2Job = jobs.submit(command: "su2-install", in: jobsRoot)
    }

    /// Car B becomes car A with this wing in place of the one it replaces,
    /// and the Lap Sim compares the two.
    // MARK: Design a wing

    private struct StarterResult: Decodable {
        struct Element: Decodable {
            var key: String
            var name: String
            var unit: [[Double]]
            var chord: Double
            var angle: Double
            var leadingEdge: [Double]
            var inverted: Bool
        }
        struct Variable: Decodable {
            var element: Int
            var kind: String
            var low: Double
            var high: Double
        }
        var elements: [Element]
        var variables: [Variable]
    }

    /// From whatever is on the canvas to an optimised wing: the engine picks a
    /// starting wing from the library (seconds), a quick-estimate study tunes
    /// it (about a minute), the best few run with RANS on the quick mesh
    /// (about 1½ minutes each) and RANS's pick is loaded.
    func designWing() {
        let lab = wingLab
        guard project != nil else {
            show("Save the project first", WingLabError("The design's study is stored in the project."))
            return
        }
        let wing = lab.wing
        var params: [String: JSONValue] = [
            "elements": .int(lab.design.elements), "chord_total": .double(wing.elements.isEmpty ? 0.44 : wing.refChord),
            "inverted": .bool(wing.elements.first?.inverted ?? true), "speed": .double(wing.speed), "rho": .double(wing.rho),
            "mu": .double(wing.mu), "n_crit": .double(lab.nCrit), "min_thickness": .double(lab.design.minThickness / 100),
            "min_gap": .double(wing.minGap),
        ]
        if let b = wing.rulesBox {
            params["rules_box"] = .array([.double(b.minX), .double(b.minY), .double(b.maxX), .double(b.maxY)])
        }
        lab.designStage = "Choosing sections from the library"
        lab.designJob = jobs.submit(command: "wing-starter", params: params, in: jobsRoot) { [weak self] item in
            guard let self else { return }
            let lab = self.wingLab
            let d = JSONDecoder()
            d.keyDecodingStrategy = .convertFromSnakeCase
            struct Wrapper: Decodable { var data: StarterResult }
            guard item.status == .succeeded, let text = item.resultText,
                  let r = try? d.decode(Wrapper.self, from: Data(text.utf8)).data else {
                lab.designStage = nil
                if item.status == .failed { self.show("Could not start the design", WingLabError(item.message ?? "The starting wing failed.")) }
                return
            }
            var elements: [WingElement] = []
            for e in r.elements {
                let coords = e.unit.compactMap { $0.count == 2 ? SIMD2($0[0], $0[1]) : nil }
                guard e.leadingEdge.count == 2, coords.count > 10 else {
                    lab.designStage = nil
                    self.show("Could not start the design", WingLabError("The engine sent an unreadable section."))
                    return
                }
                // The library's own entry when there is one; else (the NACA set without
                // a library) the section as the engine sent it.
                let airfoil = lab.airfoil(e.key) ?? Airfoil(
                    key: e.key, name: e.name, family: "NACA", source: "naca",
                    thickness: (coords.map(\.y).max() ?? 0) - (coords.map(\.y).min() ?? 0), thicknessX: 0.3,
                    camber: 0, camberX: 0.4, teThickness: 0, coords: coords)
                elements.append(WingElement(airfoil: airfoil, chord: e.chord, angle: e.angle,
                                            leadingEdge: SIMD2(e.leadingEdge[0], e.leadingEdge[1]), inverted: e.inverted))
            }
            lab.edit { $0.elements = elements; $0.alpha = 0 }
            lab.optimise.variables = r.variables.compactMap { v in
                guard let kind = WingLabModel.DesignVariable.Kind(rawValue: v.kind) else { return nil }
                var dv = WingLabModel.DesignVariable(element: v.element, kind: kind, low: 0, high: 0)
                dv.low = v.low / dv.engineScale
                dv.high = v.high / dv.engineScale
                return dv
            }
            lab.optimise.objective = lab.design.objective
            lab.optimise.solver = "estimate"
            lab.optimise.trials = lab.design.trials
            let checks = self.settings.su2Executable == nil ? 0 : lab.design.checks
            lab.optimise.checkBest = checks
            lab.meshLevel = "quick"
            lab.optimise.studyName = self.nextDesignName()
            lab.designStage = checks > 0
                ? "Tuning \(lab.design.trials) designs on quick estimates, then checking the best \(checks) with RANS"
                : "Tuning \(lab.design.trials) designs on quick estimates (SU2 is not installed, so no RANS check)"
            lab.designAwaitingStudy = true
            let before = lab.optimiseJob
            self.runWingOptimise()
            if lab.optimiseJob === before {  // it could not start (the reason has been shown)
                lab.designAwaitingStudy = false
                lab.designStage = nil
            }
        }
    }

    /// Loads RANS's pick (or the estimate's best without a check) once the study ends.
    func finishDesign(succeeded: Bool) {
        let lab = wingLab
        lab.designAwaitingStudy = false
        lab.designStage = nil
        guard succeeded, let s = lab.study else { return }
        let pick = s.bestCheck.flatMap { c in s.trials.first { $0.number == c.number } } ?? s.bestTrial
        if let pick { lab.load(trial: pick) }
    }

    private func nextDesignName() -> String {
        guard let project else { return "design-1" }
        var n = 1
        while FileManager.default.fileExists(atPath: WingLabModel.studyFile(project: project.url, name: "design-\(n)").path) { n += 1 }
        return "design-\(n)"
    }

    /// The fastest-lap objective races the Lap Sim's car A, with this wing in
    /// place of the one it replaces, around the Lap Sim's track.
    func lapObjectiveParams() throws -> JSONValue {
        let wing = wingLab.wing
        let lap = try lapSim.jobParams(lapsimFolder: lapSimFolder)
        var out: [String: JSONValue] = [
            "car": lap["car"] ?? .null, "track": lap["track"] ?? .null, "ds": lap["ds"] ?? .double(0.5),
            "start_speed": lap["start_speed"] ?? .double(0), "span": .double(wing.span),
            "factor": .double(wing.factor3D), "replaced_cla": .double(wingLab.replacedCla),
            "replaced_cda": .double(wingLab.replacedCda),
        ]
        if let h = wing.endplateHeight { out["endplate"] = .double(h) }
        return .object(out)
    }

    func sendWingToLapSim(cl: Double, cd: Double, replacedCla: Double, replacedCda: Double) {
        let add = wingLab.wing.carContribution(cl: cl, cd: cd)
        var b = lapSim.carA
        b.cla = max(b.cla - replacedCla + add.cla, 0)
        b.cda = max(b.cda - replacedCda + add.cda, 0)
        lapSim.carB = b
        lapSim.compare = true
    }
}

struct WingLabError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
