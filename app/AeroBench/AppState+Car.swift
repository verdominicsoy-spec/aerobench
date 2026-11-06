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
    /// (same end) or "draft". Never saved; the car shows it in place of its end's card.
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
        saveCar()
        return card
    }

    func loadCar() {
        car.load(project: workFolder)
        rememberCarSetup()
    }

    func saveCar() {
        rememberCarSetup()
        do {
            if let s = car.setup { try CarStore.save(s, workFolder) }
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
        car.setupJob = jobs.submit(command: "car-setup", params: ["path": .string(url.path)], in: jobsRoot, onFinish: forThisProject { [weak self] item in
            guard let self else { return }
            guard item.status == .succeeded, let text = item.resultText else {
                self.car.status = item.message ?? "The car could not be read"
                return
            }
            do {
                var s = try CarSetup.decode(resultFile: Data(text.utf8))
                s.headRestraint = self.car.setup?.headRestraint
                self.car.setup = s
                self.saveCar()
                self.refreshSections()
            } catch {
                self.show("Could not read the car setup", error)
            }
        })
    }

    func setupChanged() {
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
}
