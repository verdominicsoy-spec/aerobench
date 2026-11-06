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
        let saved = car.card(lab.cardID).flatMap { $0.position == lab.wing.rulesFor ? $0 : nil }
        if let saved, saved.wing == lab.wing { return saved }  // unchanged: the card's own numbers
        guard !lab.wing.elements.isEmpty, let n = lab.bestNumbers else { return nil }
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
    var carDraftAt: Placement? { carDraft.flatMap { draftPlacement(of: $0) } }

    private func draftPlacement(of d: WingCard) -> Placement? {
        guard let s = car.setup else { return nil }
        var combo = car.selectedCombo ?? Combination(id: "", name: "")
        if wingLab.carX != nil || wingLab.carHeight != nil {  // moved on the car: held here until Save puts it in the combination
            let slot = d.position == .front ? combo.front : combo.rear
            let p = Placement(card: d.id, x: wingLab.carX ?? slot?.x ?? 0, height: wingLab.carHeight ?? slot?.height ?? 0)
            if d.position == .front { combo.front = p } else { combo.rear = p }
        }
        return combo.draftPlacement(d, setup: s)
    }

    /// The selected combination's full result no longer describes what is shown: its own rule,
    /// or the wing being edited differs from what ran.
    func fullStale(_ combo: Combination) -> Bool {
        guard combo.full != nil else { return false }
        if combo.isStale(cards: car.cards, baseRevision: car.baseRevision) { return true }
        return combo.id == car.selected && (carDraftUnsaved || shownCombo != car.selectedCombo)
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
        // Only the selected combination carries the wing being edited; it is never re-estimated
        // (it sits at its own ride height), and never takes its saved card's cached estimate.
        let cards = combo.id == car.selected ? shownCards : car.cards
        return quick(base: base, combo: combo, cards: cards, setup: setup) { [estimates = car.estimates] card, h in
            card.revision < 0 ? nil : estimates["\(card.id)@\(Int((h * 1000).rounded()))"]
        }
    }

    /// With a base car, the wing's rules box is the car's box for its end, where the wing sits
    /// (no undo step: it follows the wing and its placement). Every wing edit calls this, so it
    /// only moves a box that is on; `picked` (a combination was just picked) also turns the box
    /// and the ground on. Either can then be turned off and stays off.
    func syncCarRulesBox(picked: Bool = false) {
        let lab = wingLab
        guard let s = rulesSetup, !lab.wing.elements.isEmpty else { return }
        let d = carDraft ?? WingCard.make(wing: lab.wing, cl: 0, cd: 0, solver: "", id: "draft", name: "", revision: -1)
        // On a car, an edit that isn't a pick either moved the wing on the canvas
        // (it moves on the car; the box stays) or moved its placement elsewhere
        // (Car view, ride height, span: the box moves). Only a pick re-clamps.
        if !picked, car.setup != nil, let box = lab.wing.rulesBox, let stored = storedPlacement(of: d, setup: s) {
            let implied = CarRules.placement(for: d, in: box, setup: s)
            let last = lab.rulesAnchor, now = anchor(lab.wing)
            lab.rulesAnchor = now
            guard abs(implied.x - stored.x) > 0.01 || abs(implied.height - stored.height) > 0.01 else { return }
            if let last, last != now {
                lab.carX = implied.x
                // the height goes to the ground only when the ground is on
                if lab.wing.rideHeight != nil { lab.live { $0.rideHeight = implied.height / 1000 } } else { lab.carHeight = implied.height }
            } else {
                let next = CarRules.wingBox(d, placement: stored, setup: s)
                lab.live { $0.rulesBox = next }
            }
            return
        }
        defer { lab.rulesAnchor = anchor(lab.wing) }
        guard let at = rulesPlacement(of: d) else { return }
        let box = CarRules.wingBox(d, placement: at, setup: s)
        // Without a base car, a box someone typed stays; Wing Lab's old fixed one is replaced
        let typed = car.setup == nil && lab.wing.rulesBox.map { $0 != Wing.defaultRulesBox(lab.wing.rulesFor) } ?? false
        // Off unless turned on: a pick only re-places a box that's already there
        if lab.wing.rulesBox != nil, !typed, lab.wing.rulesBox != box { lab.live { $0.rulesBox = box } }
    }

    /// The wing's lowest and most upstream point: where it sits in its own frame
    private func anchor(_ wing: Wing) -> SIMD2<Double> {
        let pts = wing.elements.flatMap { $0.placed() }
        return SIMD2(pts.map(\.x).min() ?? 0, pts.map(\.y).min() ?? 0)
    }

    /// Where the wing is on the car as stored (combination, carX, ride height), not clamped into its box
    private func storedPlacement(of d: WingCard, setup s: CarSetup) -> Placement? {
        let combo = car.selectedCombo ?? Combination(id: "", name: "")
        var p = (d.position == .front ? combo.front : combo.rear) ?? Placement.start(card: d, setup: s)
        p.card = d.id
        if let x = wingLab.carX { p.x = x }
        if let h = wingLab.carHeight { p.height = h }
        if let h = d.wing.rideHeight { p.height = h * 1000 }
        return p
    }

    // MARK: Rules box without a base car

    private static let lastSetupKey = "car.lastSetup"

    /// The base car most recently set up in any project
    var lastCarSetup: CarSetup? {
        UserDefaults.standard.data(forKey: Self.lastSetupKey).flatMap { try? JSONDecoder().decode(CarSetup.self, from: $0) }
    }

    func rememberCarSetup() {
        guard let s = car.setup, let data = try? JSONEncoder().encode(s) else { return }
        UserDefaults.standard.set(data, forKey: Self.lastSetupKey)
    }

    /// The car the FS 2027 box comes from: this project's base car, else the last one used
    var rulesSetup: CarSetup? { car.setup ?? lastCarSetup }

    /// Where the wing sits for its rules box: on the selected combination, or at its end's start place
    func rulesPlacement(of d: WingCard) -> Placement? {
        if car.setup != nil { return draftPlacement(of: d) }
        return lastCarSetup.map { Combination(id: "", name: "").draftPlacement(d, setup: $0) }
    }

    /// The box a wing at `position` gets when its rules box is switched on
    func rulesBox(for position: WingPosition) -> RulesBox {
        var wing = wingLab.wing
        wing.rulesFor = position
        guard let s = rulesSetup, !wing.elements.isEmpty else { return Wing.defaultRulesBox(position) }
        let d = WingCard.make(wing: wing, cl: 0, cd: 0, solver: "", id: "draft", name: "", revision: -1)
        guard let at = rulesPlacement(of: d) else { return Wing.defaultRulesBox(position) }
        return CarRules.wingBox(d, placement: at, setup: s)
    }

    /// The fastest-lap goal's car with a base car: car A with the base car and the other end's wing,
    /// at the balance the combination has now (the trial wing's numbers are added by the engine).
    func lapGoalCar() -> (car: CarParameters, note: String)? {
        guard car.base != nil, let combo = shownCombo, let d = carDraft else { return nil }
        guard let others = quickResult(combo.without(d.position)), let now = quickResult(combo) else { return nil }
        var c = lapSim.carA
        c.cla = max(others.cla, 0)
        c.cda = max(others.cda, 0)
        if let r = now.rearShare { c.aeroBalanceDriven = min(max(r, 0), 1) }
        let other = (d.position == .front ? combo.rear : combo.front).flatMap { p in car.card(p.card)?.name }
        let note = "this wing on the car with " + (other ?? "no other wing")
            + String(format: "; balance kept at %.0f %% rear", c.aeroBalanceDriven * 100)
        return (c, note)
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
        guard carDraftAt != nil else { return }
        syncCarRulesBox(picked: true)  // the ground stays as it is: on only when turned on
    }

    /// Moves the draft on the car: its height is Wing Lab's ride height and its x Wing Lab's carX,
    /// both through Wing Lab's undo (one step per gesture).
    func moveDraft(to p: Placement, live: Bool) {
        guard carDraft != nil else { return }
        let h = p.height / 1000
        // Held in Wing Lab (its undo) until Save: the combination's own wing stays where it was.
        let ground = wingLab.wing.rideHeight != nil  // the height goes to the ground only when it's on
        if live {
            if ground { wingLab.live { $0.rideHeight = h } } else { wingLab.carHeight = p.height }
            wingLab.carX = p.x
        } else {
            wingLab.editStep {
                if ground { $0.wing.rideHeight = h } else { $0.carHeight = p.height }
                $0.carX = p.x
            }
        }
        syncCarRulesBox()
    }

    /// Saves the edited wing as a card (the one it came from, or a new one), puts it on its end
    /// of the selected combination where the draft sits, and returns it.
    @discardableResult
    func saveWingCard(asNew: Bool, numbers: (cl: Double, cd: Double, name: String)? = nil) -> WingCard? {
        let lab = wingLab
        guard let n = numbers ?? lab.bestNumbers else { return nil }
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
            lab.carX = nil
            lab.carHeight = nil
        }
        car.estimates = car.estimates.filter { !$0.key.hasPrefix("\(card.id)@") }  // made of the old numbers
        saveCar()
        return card
    }

    func loadCar() {
        car.load(project: workFolder)
        rememberCarSetup()
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
        rememberCarSetup()
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

    private func runParams(wings: [JSONValue]) -> [String: JSONValue]? {
        guard let s = car.setup, let setup = try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(s)) else { return nil }
        var p: [String: JSONValue] = ["setup": setup, "flow": car.flow, "preset": .string(car.mesh), "wings": .array(wings)]
        if let su2 = settings.su2Path.nilIfEmpty { p["su2"] = .string(su2) }
        return p
    }

    func runBareCar() {
        guard let params = runParams(wings: []) else { return }
        car.baseJob = jobs.submit(command: "car-strips", params: params, in: jobsRoot) { [weak self] item in
            guard let self, item.status == .succeeded, let text = item.resultText else { return }
            do {
                var r = try CarResult.decode(resultFile: Data(text.utf8))
                r.folder = item.workdir.lastPathComponent
                self.car.bases[r.mesh] = r
                try CarStore.save(base: r, self.workFolder)
                self.car.baseRevision += 1
                self.saveCar()
            } catch {
                self.show("Could not read the bare car's result", error)
            }
        }
    }

    /// Full: the section again with the placed wings, at the baseline's mesh.
    func runFull(_ id: String) {
        // The wing being edited is saved to its card first, so the full result belongs to saved cards.
        if id == car.selected, carDraft != nil, carDraftUnsaved || shownCombo != car.selectedCombo { saveWingCard(asNew: false) }
        guard let combo = car.combos.first(where: { $0.id == id }), car.base != nil,
              let params = runParams(wings: car.placedWings(combo)) else { return }
        // Recorded against what ran: anything changed while it runs leaves it out of date.
        let ranCards = car.cards, ranBase = car.baseRevision
        car.fullJob = jobs.submit(command: "car-strips", params: params, in: jobsRoot) { [weak self] item in
            guard let self, item.status == .succeeded, let text = item.resultText,
                  let i = self.car.combos.firstIndex(where: { $0.id == id }) else { return }
            do {
                var r = try CarResult.decode(resultFile: Data(text.utf8))
                r.folder = item.workdir.lastPathComponent
                self.car.combos[i].recordFull(r, ran: combo, cards: ranCards, baseRevision: ranBase)
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
            if fullStale(combo) { warnings.append("the full result is out of date") }
        } else {
            // The selected combination is sent as shown: with the wing being edited on it.
            let q = quickResult(id == car.selected ? shownCombo ?? combo : combo)
            if id == car.selected, carDraftUnsaved { warnings.append("the edited wing is not saved") }
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
