import AeroBenchKit
import AppKit
import Foundation
import UniformTypeIdentifiers

extension AppState {
    private func carEngine() -> WarmEngine? {
        if car.engine == nil, let exe = settings.engineExecutable { car.engine = WarmEngine(executableURL: exe) }
        if car.sectionRunner == nil, let engine = car.engine {
            car.sectionRunner = LatestOnly { params in try CarSection.decode(try await engine.request("car-section", params: params)) }
        }
        return car.engine
    }

    func loadCar() { car.load(project: workFolder) }

    func saveCar() {
        do {
            if let s = car.setup { try CarStore.save(s, workFolder) }
            try CarStore.save(car.combos, workFolder)
            for c in car.cards { try CarStore.save(c, workFolder) }
        } catch {
            show("Could not save the car", error)
        }
    }

    func chooseCarSTEP() {
        let panel = NSOpenPanel()
        panel.title = "Base Car"
        panel.allowedContentTypes = ["step", "stp"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runCarSetup(url)
    }

    func runCarSetup(_ url: URL) {
        car.status = nil
        car.setupJob = jobs.submit(command: "car-setup", params: ["path": .string(url.path)], in: jobsRoot) { [weak self] item in
            guard let self else { return }
            guard item.status == .succeeded, let text = item.resultText else {
                self.car.status = item.message ?? "The car could not be read"
                return
            }
            do {
                var s = try CarSetup.decode(resultFile: Data(text.utf8))
                s.headRestraint = self.car.setup?.headRestraint
                self.car.setup = s
                self.car.baseRevision += 1
                self.saveCar()
                self.refreshSections()
            } catch {
                self.show("Could not read the car setup", error)
            }
        }
    }

    func setupChanged() {
        car.baseRevision += 1
        saveCar()
    }

    /// The live section at the slider, and the centreline for the side view.
    func refreshSections() {
        guard let s = car.setup, let runner = carEngine().flatMap({ _ in car.sectionRunner }),
              let setup = try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(s)) else { return }
        let y = car.sectionY
        Task { @MainActor in
            if car.centreline == nil,
               case .success(let c)? = await runner.submit(.object(["setup": setup, "y": .double(0)])) { car.centreline = c }
            if case .success(let c)? = await runner.submit(.object(["setup": setup, "y": .double(y)])) {
                car.section = c
                car.status = c.open.isEmpty ? nil : "The cut does not close in \(c.open.count / 2) places (shown in clay): a gap in the CAD"
            }
        }
    }

    private func stripsParams(wings: [JSONValue]) -> [String: JSONValue]? {
        guard let s = car.setup, let setup = try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(s)) else { return nil }
        var p: [String: JSONValue] = ["setup": setup, "flow": car.flow, "preset": .string(car.mesh), "n": .int(car.strips), "wings": .array(wings)]
        if let su2 = settings.su2Path.nilIfEmpty { p["su2"] = .string(su2) }
        return p
    }

    func runBareCar() {
        guard let params = stripsParams(wings: []) else { return }
        car.baseJob = jobs.submit(command: "car-strips", params: params, in: jobsRoot) { [weak self] item in
            guard let self, item.status == .succeeded, let text = item.resultText else { return }
            do {
                let r = try CarResult.decode(resultFile: Data(text.utf8))
                self.car.bases[r.mesh] = r
                try CarStore.save(base: r, self.workFolder)
                self.car.baseRevision += 1
                self.saveCar()
            } catch {
                self.show("Could not read the bare car's result", error)
            }
        }
    }

    /// Full: the strips again with the placed wings, at the baseline's mesh.
    func runFull(_ id: String) {
        guard let combo = car.combos.first(where: { $0.id == id }), car.base != nil,
              let params = stripsParams(wings: car.placedWings(combo)) else { return }
        car.fullJob = jobs.submit(command: "car-strips", params: params, in: jobsRoot) { [weak self] item in
            guard let self, item.status == .succeeded, let text = item.resultText,
                  let i = self.car.combos.firstIndex(where: { $0.id == id }) else { return }
            do {
                self.car.combos[i].full = try CarResult.decode(resultFile: Data(text.utf8))
                self.saveCar()
            } catch {
                self.show("Could not read the full result", error)
            }
        }
    }

    /// Re-estimates a card at a placed height (the warm engine's quick estimate), for the quick sum.
    func estimateCard(_ card: WingCard, height: Double) {
        let key = "\(card.id)@\(Int((height * 1000).rounded()))"
        guard car.estimates[key] == nil, let engine = carEngine() else { return }
        var wing = card.wing
        wing.rideHeight = height
        let params = JSONValue.object(estimateParams(wing))
        Task { @MainActor in
            guard let data = try? await engine.request("wing-estimate", params: params),
                  let est = try? WingEstimate.decode(resultFile: data), let row = est.row(nearest: wing.alpha) else { return }
            let add = wing.carContribution(cl: row.cl, cd: row.cd)
            car.estimates[key] = (cla: add.cla, cda: add.cda)
        }
    }

    /// A combination onto Lap Sim car `index` (a new one when nil): ClA, CdA and the rear share as the driven axle's.
    @discardableResult
    func sendCarToLapSim(_ id: String, full: Bool, into index: Int?) -> String? {
        guard let combo = car.combos.first(where: { $0.id == id }) else { return nil }
        let numbers: (cla: Double, cda: Double, rear: Double?)?
        if full, let f = combo.full { numbers = (f.cla, f.cda, f.rearShare) } else {
            numbers = car.quickResult(combo).map { ($0.cla, $0.cda, $0.rearShare) }
        }
        guard let n = numbers else { return nil }
        let i = index ?? lapSim.cars.count
        var target = index.map { lapSim.cars[$0] } ?? lapSim.carA
        target.cla = max(n.cla, 0)
        target.cda = max(n.cda, 0)
        if let r = n.rear { target.aeroBalanceDriven = min(max(r, 0), 1) }  // rear-wheel drive: the rear share
        if i < lapSim.cars.count { lapSim.cars[i] = target } else if i < LapSimSetup.maxCars { lapSim.cars.append(target) } else { return nil }
        return LapSimSetup.labels[i]
    }
}

private extension String {
    var nilIfEmpty: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}
