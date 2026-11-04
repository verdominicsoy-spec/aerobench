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

    // MARK: The wing being edited, on the car

    /// The wing Wing Lab is editing, as a card with its best numbers: the card it came from
    /// (same end) or "draft". Never saved; the quick sum uses it in place of its end's card.
    var carDraft: WingCard? {
        let lab = wingLab
        guard !lab.wing.elements.isEmpty, let n = lab.bestNumbers else { return nil }
        let saved = car.card(lab.cardID).flatMap { $0.position == lab.wing.rulesFor ? $0 : nil }
        return WingCard.make(wing: lab.wing, cl: n.cl, cd: n.cd, solver: n.name, id: saved?.id ?? "draft",
                             name: saved?.name ?? "This wing", revision: -1)
    }

    /// The draft differs from its saved card (or has none).
    var carDraftUnsaved: Bool {
        guard let d = carDraft else { return false }
        guard let c = car.card(d.id) else { return true }
        return c.wing != d.wing || abs(c.cla - d.cla) > 1e-9 || abs(c.cda - d.cda) > 1e-9
    }

    /// Where the draft sits on the selected combination.
    var carDraftAt: Placement? {
        guard let d = carDraft, let s = car.setup else { return nil }
        var combo = car.selectedCombo ?? Combination(id: "", name: "")
        if (d.position == .front ? combo.front : combo.rear) == nil, let x = car.draftX {
            let p = Placement(card: d.id, x: x, height: 0)
            if d.position == .front { combo.front = p } else { combo.rear = p }
        }
        return combo.draftPlacement(d, setup: s)
    }

    /// The selected combination as shown: the draft on its end.
    var shownCombo: Combination? {
        guard let combo = car.selectedCombo else { return nil }
        guard let d = carDraft, let at = carDraftAt else { return combo }
        return combo.overlaying(d, at: at)
    }

    /// The cards, with the draft in place of its saved card.
    var shownCards: [WingCard] {
        guard let d = carDraft else { return car.cards }
        return car.cards.filter { $0.id != d.id } + [d]
    }

    var shownQuick: QuickResult? { shownCombo.flatMap { quickResult($0) } }

    /// The quick sum over the shown cards (the draft included).
    func quickResult(_ combo: Combination) -> QuickResult? {
        guard let base = car.base, let setup = car.setup else { return nil }
        return quick(base: base, combo: combo, cards: shownCards, setup: setup) { [estimates = car.estimates] card, h in
            estimates["\(card.id)@\(Int((h * 1000).rounded()))"]
        }
    }

    /// The quick sum over the saved cards only (the draft left out).
    func quickResultSaved(_ combo: Combination) -> QuickResult? {
        guard let base = car.base, let setup = car.setup else { return nil }
        return quick(base: base, combo: combo, cards: car.cards, setup: setup) { [estimates = car.estimates] card, h in
            estimates["\(card.id)@\(Int((h * 1000).rounded()))"]
        }
    }

    /// Puts the draft on the car: makes the first combination if there is none, and turns on
    /// Wing Lab's ground at the placed height (one undo step) so both show the same numbers.
    func putDraftOnCar() {
        guard car.setup != nil else { return }
        if car.selectedCombo == nil {
            if car.combos.isEmpty { car.combos.append(Combination(id: UUID().uuidString, name: "Combination 1")) }
            car.selected = car.combos.first?.id
            saveCar()
        }
        guard let at = carDraftAt else { return }
        if wingLab.wing.rideHeight.map({ abs($0 * 1000 - at.height) > 0.01 }) ?? true {
            wingLab.edit { $0.rideHeight = at.height / 1000 }
        }
    }

    /// Moves the draft on the car: its height is Wing Lab's ride height (through Wing Lab's undo,
    /// one step per gesture), its x goes to its end's slot, or is kept here while the end is empty.
    func moveDraft(to p: Placement, live: Bool) {
        guard let d = carDraft else { return }
        let h = p.height / 1000
        if live { wingLab.live { $0.rideHeight = h } } else { wingLab.edit { $0.rideHeight = h } }
        if let i = car.combos.firstIndex(where: { $0.id == car.selected }),
           let slot = d.position == .front ? car.combos[i].front : car.combos[i].rear {
            let moved = Placement(card: slot.card, x: p.x, height: p.height)
            if d.position == .front { car.combos[i].front = moved } else { car.combos[i].rear = moved }
            if !live { saveCar() }
        } else {
            car.draftX = p.x
        }
    }

    /// Saves the edited wing as a card (the one it came from, or a new one), puts it on its end
    /// of the selected combination where the draft sits, and returns it.
    @discardableResult
    func saveWingCard(asNew: Bool) -> WingCard? {
        let lab = wingLab
        guard let n = lab.bestNumbers else { return nil }
        let at = carDraftAt
        let position = lab.wing.rulesFor
        // Updating keeps the card's place on cars: never turn a front card into a rear one.
        let old = asNew ? nil : car.card(lab.cardID).flatMap { $0.position == position ? $0 : nil }
        let count = car.cards.filter { $0.position == position }.count
        let card = WingCard.make(wing: lab.wing, cl: n.cl, cd: n.cd, solver: n.name, id: old?.id ?? UUID().uuidString,
                                 name: old?.name ?? "\(position == .front ? "Front" : "Rear") \(count + 1)",
                                 revision: (old?.revision ?? 0) + 1)
        do {
            try CarStore.save(card, workFolder)
        } catch {
            show("Could not save the card", error)
            return nil
        }
        if let i = car.cards.firstIndex(where: { $0.id == card.id }) { car.cards[i] = card } else { car.cards.append(card) }
        lab.cardID = card.id
        if let at, let i = car.combos.firstIndex(where: { $0.id == car.selected }) {
            let p = Placement(card: card.id, x: at.x, height: at.height)
            if position == .front { car.combos[i].front = p } else { car.combos[i].rear = p }
            car.draftX = nil
        }
        saveCar()
        return card
    }

    func loadCar() {
        car.load(project: workFolder)
        requestEstimates()
    }

    /// Asks for every placed card's re-estimate the quick sums need (after loading, assigning, moving).
    func requestEstimates() {
        for combo in car.combos {
            for p in [combo.front, combo.rear].compactMap({ $0 }) {
                if let c = car.card(p.card), needsEstimate(c, height: p.height / 1000) { estimateCard(c, height: p.height / 1000) }
            }
        }
    }

    func saveCar() {
        do {
            if let s = car.setup { try CarStore.save(s, workFolder) }
            try CarStore.save(car.state, workFolder)
            if !car.combosUnreadable { try CarStore.save(car.combos, workFolder) }
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
        // The wing being edited is saved to its card first, so the full result belongs to saved cards.
        if id == car.selected, carDraft != nil, carDraftUnsaved || shownCombo != car.selectedCombo { saveWingCard(asNew: false) }
        guard let combo = car.combos.first(where: { $0.id == id }), car.base != nil,
              let params = stripsParams(wings: car.placedWings(combo)) else { return }
        car.fullJob = jobs.submit(command: "car-strips", params: params, in: jobsRoot) { [weak self] item in
            guard let self, item.status == .succeeded, let text = item.resultText,
                  let i = self.car.combos.firstIndex(where: { $0.id == id }) else { return }
            do {
                let r = try CarResult.decode(resultFile: Data(text.utf8))
                self.car.combos[i].recordFull(r, cards: self.car.cards, baseRevision: self.car.baseRevision)
                self.saveCar()
            } catch {
                self.show("Could not read the full result", error)
            }
        }
    }

    /// Re-estimates a card at a placed height (the warm engine's quick estimate), for the quick sum.
    func estimateCard(_ card: WingCard, height: Double) {
        guard needsEstimate(card, height: height) else { return }
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

    /// A combination onto Lap Sim car `index` (a new one when nil): ClA, CdA and the rear share as
    /// the driven axle's (rear-wheel drive). Returns the car's label and what the user should know
    /// about the numbers sent (not converged, clamped, unverified moving ground, balance kept).
    func sendCarToLapSim(_ id: String, full: Bool, into index: Int?) -> (label: String, warnings: [String])? {
        guard let combo = car.combos.first(where: { $0.id == id }) else { return nil }
        var warnings: [String] = []
        let numbers: (cla: Double, cda: Double, rear: Double?)?
        if full, let f = combo.full {
            numbers = (f.cla, f.cda, f.rearShare)
            if !f.converged { warnings.append("the full run did not converge") }
            if f.groundMoving == true { warnings.append("it ran over a moving ground, which is unverified") }
            if combo.isStale(cards: car.cards, baseRevision: car.baseRevision) { warnings.append("the full result is out of date") }
        } else {
            let q = quickResult(combo)
            numbers = q.map { ($0.cla, $0.cda, $0.rearShare) }
            if let b = car.base, !b.converged { warnings.append("the bare car's run did not converge") }
            if !(q?.pendingEstimate.isEmpty ?? true) { warnings.append("a re-estimate was not back yet") }
        }
        guard let n = numbers else { return nil }
        let i = index ?? lapSim.cars.count
        guard i < LapSimSetup.maxCars else { return nil }
        var target = index.map { lapSim.cars[$0] } ?? lapSim.carA
        if n.cla < 0 { warnings.append(String(format: "ClA %.2f is lift: sent as 0", n.cla)) }
        target.cla = max(n.cla, 0)
        target.cda = max(n.cda, 0)
        if let r = n.rear {
            if r < 0 || r > 1 { warnings.append(String(format: "the rear share %.0f %% is outside 0 to 100: clamped", r * 100)) }
            target.aeroBalanceDriven = min(max(r, 0), 1)
        } else {
            warnings.append("no rear share (no net downforce): the car's balance is kept")
        }
        if i < lapSim.cars.count { lapSim.cars[i] = target } else { lapSim.cars.append(target) }
        return (LapSimSetup.labels[i], warnings)
    }
}

private extension String {
    var nilIfEmpty: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}
