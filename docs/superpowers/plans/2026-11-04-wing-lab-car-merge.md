# Wing Lab and Car merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Car tool's features move into Wing Lab, with the wing being edited on the car live, and the Car dock tool goes away.

**Architecture:** New pure logic goes in AeroBenchKit's `CarBuilder.swift`, tested with `swift test`: the card built from a wing, the default placement, the draft overlay on a combination, the car's rules box in the wing's frame, and a combination without one end. `CarModel` gains a draft card and its placement, and `shownCombo`/`shownCards`, which every car view reads. The Car tool's panes move out of `CarView.swift` into Wing Lab's canvas, results pane, inspector and library sidebar.

**Tech Stack:** Swift 6, SwiftUI (macOS), AeroBenchKit (SwiftPM), xcodebuild.

**Spec:** `docs/superpowers/specs/2026-11-04-wing-lab-car-merge-design.md`

## Global Constraints

- No engine changes and no changes to the project-folder files (cards, `combinations.json`, car state).
- sage37 (`S37.C.*`, `.s37Pane()`, `.s37Region()`); no `ochreInk`.
- Reuse the Car tool's panes; don't rewrite them.
- Wing Lab's inspector is 320 to 440 points wide.
- Kit tests: `cd app/AeroBenchKit && swift test`. App: `cd app && xcodebuild -scheme AeroBench -destination 'platform=macOS' build`, which must print `** BUILD SUCCEEDED **`.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Run `graphify update .` after the last task.

## Review Focus

1. **Editing a wing that is not on the selected combination, then Undo.** The car view follows Wing Lab's undo, and the combination is not changed until Save.
2. **Opening a card while the wing being edited has unsaved changes.** Ask before discarding, as loading a project does.
3. **A front wing with Ground off, put on the car.** Ground turns on at the placed height, and the car and Wing Lab show the same numbers.
4. **The base car removed or reset mid-edit.** The rules box unlocks, the Car tab says what is missing, and nothing crashes on `setup == nil`.
5. **Run Full or Send to Lap Sim with an unsaved draft.** Run Full saves first. Send sends what is shown and warns that the wing is not saved.

---

### Task 1: Kit: card, start placement, overlay, wing-frame box

**Files:**
- Modify: `app/AeroBenchKit/Sources/AeroBenchKit/CarBuilder.swift`
- Test: `app/AeroBenchKit/Tests/AeroBenchKitTests/CarBuilderTests.swift`

**Interfaces:**
- Produces:
  - `WingCard.make(wing: Wing, cl: Double, cd: Double, solver: String, id: String, name: String, revision: Int) -> WingCard`: position `wing.rulesFor`; `cla`/`cda` from `wing.carContribution(cl:cd:)`; `xcp = wing.refChord / 4`; `rideHeight = wing.rideHeight`; `speed = wing.speed`.
  - `Placement.start(card: WingCard, setup: CarSetup) -> Placement`: today's Put on Car spot, clamped. `x = box.maxX - axle - 10`, `height = max(rideHeight mm ?? 0, box.minZ - groundZ) + 10`.
  - `Combination.draftPlacement(_ draft: WingCard, setup: CarSetup) -> Placement`: the draft end's slot x if there is one, else `start`. Height is `draft.wing.rideHeight * 1000` when set, else the slot's or start's. The result is clamped and `card` is `draft.id`.
  - `Combination.overlaying(_ draft: WingCard, at: Placement) -> Combination`: a copy with the draft's end set to `at`.
  - `Combination.without(_ position: WingPosition) -> Combination`
  - `CarRules.wingBox(_ card: WingCard, placement: Placement, setup: CarSetup) -> RulesBox`: the car's box in the frame `Wing.issues` checks (`elements.placed()`, m). The anchor is the placed elements' min x and min y. Exact at alpha 0.

- [ ] **Step 1: Write the failing tests** (use the file's `setup()` and `card(_:)` helpers)

```swift
func testACardIsMadeFromTheWingAsSaveDoes() {
    var w = card(.front).wing; w.rulesFor = .front; w.rideHeight = 0.05
    let c = WingCard.make(wing: w, cl: -1.2, cd: 0.05, solver: "CFD", id: "a", name: "Front 1", revision: 3)
    let add = w.carContribution(cl: -1.2, cd: 0.05)
    XCTAssertEqual(c.cla, add.cla, accuracy: 1e-12); XCTAssertEqual(c.cda, add.cda, accuracy: 1e-12)
    XCTAssertEqual(c.xcp, 0.075, accuracy: 1e-12)
    XCTAssertEqual(c.position, .front); XCTAssertEqual(c.rideHeight, 0.05); XCTAssertEqual(c.revision, 3)
}

func testANewWingStartsAtTheFrontOfItsBox() {
    let p = Placement.start(card: card(.front), setup: setup())
    XCTAssertEqual(p.x, 917, accuracy: 1e-9)       // 298 + 629 - 10
    XCTAssertEqual(p.height, 40, accuracy: 1e-9)   // 30 mm clearance + 10
}

func testTheDraftTakesItsEndsSlotAtItsOwnRideHeight() {
    var combo = Combination(id: "k", name: "K")
    combo.front = Placement(card: "cfront", x: 600, height: 60)
    combo.rear = Placement(card: "crear", x: -100, height: 700)
    var d = card(.front, rideHeight: 0.08); d.id = "draft"
    let at = combo.draftPlacement(d, setup: setup())
    XCTAssertEqual(at, Placement(card: "draft", x: 600, height: 80))
    let shown = combo.overlaying(d, at: at)
    XCTAssertEqual(shown.front, at); XCTAssertEqual(shown.rear, combo.rear)
    XCTAssertEqual(combo.front?.card, "cfront")  // the stored combination is untouched
    XCTAssertNil(combo.without(.front).front)
}

func testAnEmptyEndGivesTheDraftTheStartSpot() {
    var d = card(.front); d.id = "draft"
    XCTAssertEqual(Combination(id: "k", name: "K").draftPlacement(d, setup: setup()), Placement(card: "draft", x: 917, height: 40))
}

func testTheCarsBoxInTheWingsFrame() {
    let c = card(.front)
    let b = CarRules.wingBox(c, placement: Placement(card: c.id, x: 600, height: 60), setup: setup())
    XCTAssertEqual(b.minX, -0.327, accuracy: 1e-9); XCTAssertEqual(b.maxX, 0.373, accuracy: 1e-9)
    XCTAssertEqual(b.minY, -0.033, accuracy: 1e-9); XCTAssertEqual(b.maxY, 0.287, accuracy: 1e-9)
}
```

- [ ] **Step 2:** `swift test --filter CarBuilderTests`. Expected: the build fails because `make`, `start`, `draftPlacement`, `overlaying`, `without` and `wingBox` aren't defined.
- [ ] **Step 3:** Implement the six functions above in `CarBuilder.swift`. `wingBox` maps a car point to the wing frame as `xw = minX + (axle + p.x - carX)/1000` and `yw = minY + (carZ - groundZ - p.height)/1000`. The front of the car box gives the smallest `xw`.
- [ ] **Step 4:** `swift test`. Expected: everything passes, the old 143 tests plus 5 new ones.
- [ ] **Step 5:** Commit: "Car: draft overlay, start placement and the car's box in the wing frame".

### Task 2: App: the draft on the car

**Files:**
- Modify: `app/AeroBench/CarModel.swift`, `app/AeroBench/AppState+Car.swift`, `app/AeroBench/WingLabModel.swift`, `app/AeroBench/Views/WingLabView.swift` (`saveCard` and `lapSimSection` only)

**Interfaces:**
- Consumes: everything Task 1 produces.
- Produces:
  - `WingLabModel.bestNumbers: (cl: Double, cd: Double, name: String)?`: converged CFD, then the live estimate, then the preview with `cdEstimate`, the order `lapSimSection` uses now. `lapSimSection` and `saveCard` use it.
  - `CarModel.draft: WingCard?`, `CarModel.draftAt: Placement?`
  - `CarModel.shownCombo: Combination?`: the selected combination overlaid with the draft.
  - `CarModel.shownCards: [WingCard]`: the cards, with the draft added or replacing its id.
  - `CarModel.quickResult(_:)` reads `shownCards`.
  - `AppState.syncDraft()`: rebuilds `draft` from `wingLab.wing` and `bestNumbers`, with id `wingLab.cardID ?? "draft"` and revision -1. It sets `draftAt = selectedCombo.draftPlacement(...)`. With a base car and no combination, it adds "Combination 1" and selects it. With no setup, it clears both.
  - `AppState.putDraftOnCar()`: if the ground is off or the ride height differs from `draftAt.height`, it calls `lab.edit { $0.rideHeight = draftAt.height / 1000 }`. This is one undo step.
  - `AppState.moveDraft(to: Placement, live: Bool)`: sets the ride height through `lab.live` (or `lab.edit` when the move ends) and writes x and height into the stored slot if that end has one, then `saveCar()`.
  - `saveCard` (existing): after it saves, sets the selected combination's slot for that end to the saved card at `draftAt`.

- [ ] **Step 1:** Call `syncDraft()` from Wing Lab's `onChange(of: lab.wing)`, from the change of `bestNumbers`, and from `onChange(of: app.car.selected)`. Debounce wing changes by 150 ms with `LatestOnly`-style cancellation, so typing never waits on the car sum.
- [ ] **Step 2:** Make `saveCard` build its card with `WingCard.make` and put it in the slot. Make `lapSimSection` read `lab.bestNumbers`.
- [ ] **Step 3:** Build. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 4:** Commit: "Wing Lab: the wing being edited sits on the car".

### Task 3: App: canvas Wing | Car switch with the side view

**Files:**
- Create: `app/AeroBench/Views/CarPanes.swift`, holding the panes moved out of `CarView.swift` with `private` removed: `BaseCarPane`, `CarFrame`, `SideViewPane`, `SectionPane`, `CardsPane`, `CardRow`, `CombinationsPane`
- Modify: `app/AeroBench/Views/WingLabView.swift` (`WingCanvas` host in `WingLabView.body`), `app/AeroBench/WingLabModel.swift` (`canvasMode`)

**Interfaces:**
- Consumes: `shownCombo`, `shownCards`, `draft`, `draftAt`, `moveDraft`, `putDraftOnCar` (Task 2).
- Produces: `WingLabModel.canvasMode: CanvasMode` (`.wing`, `.car`), saved in UserDefaults as `showLibrary` is.

- [ ] **Step 1:** Above the canvas, add a segmented Wing | Car picker. In Car mode, show `SideViewPane` in place of `WingCanvas`.
- [ ] **Step 2:** `SideViewPane` draws and drags from `shownCombo`/`shownCards`. Dragging the draft's end calls `moveDraft`, whose ride-height sync goes through Wing Lab's undo, and the other end keeps today's path. The placement fields for the draft's end call `moveDraft(live: false)`. The draft is drawn in `S37.C.sage` with "(editing)" next to its fields. Switching to Car with the draft not yet on the car calls `putDraftOnCar()`.
- [ ] **Step 3:** Build. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 4:** Commit: "Wing Lab: car side view on the canvas".

### Task 4: App: Car results tab

**Files:**
- Modify: `app/AeroBench/WingLabModel.swift` (`ResultsTab.car = "Car"`), `app/AeroBench/Views/WingLabView.swift` (new `CarResults` view, `WingResultsPane` switch), `app/AeroBench/AppState+Car.swift` (`runFull`)

**Interfaces:**
- Consumes: `quickResult(shownCombo)`, `car.base`, the selected combination's `full` and `isStale`.
- Produces: `runFull(_:)` saves the draft first through `saveCard` (Update, or a new card when `cardID == nil`), then runs the stored combination.

- [ ] **Step 1:** `CarResults` shows ClA, CdA and the rear share, with "using the wing being edited (not saved)" when `draft.id == "draft"` or the draft differs from its saved card. It shows the change against the bare car and against the saved card's quick sum, which is `quickResult` of the stored combination. It shows the full result with its stale, not-converged, failed-strips and gaps notes moved from `CombinationsPane`, and Run Full. Without a base car it says "Set up the base car in the inspector's Car section".
- [ ] **Step 2:** Build. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 3:** Commit: "Wing Lab: Car results tab".

### Task 5: App: Car inspector section and Lap Sim send

**Files:**
- Modify: `app/AeroBench/Views/WingLabView.swift` (`WingInspector`, `lapSimSection`), `app/AeroBench/Views/CarPanes.swift`

**Interfaces:**
- Consumes: `BaseCarPane`, `SectionPane`, `CombinationsPane`, `sendCarToLapSim` (existing).
- Produces: `sendCarToLapSim` reads `shownCombo` for quick sends and adds the warning "the edited wing is not saved" when the draft is unsaved.

- [ ] **Step 1:** Add a "Car" inspector section holding `BaseCarPane`, `SectionPane` and `CombinationsPane`, made to fit within 320 points: drop their `maxWidth: 420` and let rows wrap.
- [ ] **Step 2:** In `lapSimSection`, with `car.setup != nil && car.base != nil`, replace "Put in a Lap Sim Car" with the combination's Send to Lap Sim menu (quick and full) and its warnings. Otherwise keep today's per-wing send.
- [ ] **Step 3:** Build. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 4:** Commit: "Wing Lab: Car section and combination send".

### Task 6: App: Cards in the library sidebar

**Files:**
- Modify: `app/AeroBench/Views/WingLabView.swift` (`AirfoilLibraryPanel`), `app/AeroBench/WingLabModel.swift` (`open(card:)`, `libraryTab`)

**Interfaces:**
- Produces: `WingLabModel.open(card: WingCard)`. It is undoable through `edit { $0 = card.wing }`, sets `cardID = card.id`, and marks the origin as "card <name>".

- [ ] **Step 1:** Add an Airfoils | Cards segmented picker at the top of the sidebar. Cards lists `CardRow`s with Open and Put on Car. Opening a card while there are unsaved changes since the last save or open (track `savedWing: Wing?`) asks for confirmation with a confirmation dialog: "Discard the changes to this wing?"
- [ ] **Step 2:** Build. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 3:** Commit: "Wing Lab: cards in the library".

### Task 7: App: rules box lock and the Study's lap goal

**Files:**
- Modify: `app/AeroBench/AppState+Car.swift` (`syncDraft`), `app/AeroBench/Views/WingLabView.swift` (rules box fields and footer), `app/AeroBench/AppState+Wing.swift` (`lapObjectiveParams`)

**Interfaces:**
- Consumes: `CarRules.wingBox`, `Combination.without`, `quick`.

- [ ] **Step 1:** In `syncDraft`, with a setup, set `lab.live { $0.rulesBox = CarRules.wingBox(draft, placement: draftAt, setup:) }`. It must not create an undo step, and it is skipped when the box is already equal. The rules box toggle and the box fields are disabled, with the footer "The car's box for the <front/rear> wing, from the base car." The Box for picker stays enabled, since it picks the end.
- [ ] **Step 2:** With a base car, `lapObjectiveParams` takes Lap Sim car A and sets `cla` and `cda` to `quickResult(shownCombo.without(draft end))`. It sets `aeroBalanceDriven` to `quickResult(shownCombo).rearShare` (clamped 0 to 1), and `replaced_cla` and `replaced_cda` to 0. Without a base car it does what it does now. Add a line to the Study pane: "Lap goal: this wing on the car with <other wing or no other wing>; balance kept at <n> %."
- [ ] **Step 3:** Build. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 4:** Commit: "Wing Lab: the car's rules box and lap goal".

### Task 8: App: remove the Car dock tool

**Files:**
- Modify: `app/AeroBench/Views/ContentView.swift` (remove `case car` and its labels, icon and motif), `docs/DECISIONS.md`
- Delete: `app/AeroBench/Views/CarView.swift` (its `takeaway` joins Wing Lab's takeaway when a base car exists, as one more sentence)

- [ ] **Step 1:** Remove the dock entry and `CarView`. Move the `app.loadCar(); app.refreshSections()` from `onAppear` into `WingLabView`'s `onAppear`. Rename the hints that point at the Car tool, such as "Put it on the car in the Car tool" and "Save a wing as a card in Wing Lab", to point at the Car view and Cards.
- [ ] **Step 2:** Add a `DECISIONS.md` entry: the Car tool merged into Wing Lab, with the five calls from the spec.
- [ ] **Step 3:** Build, run `swift test`, and run `graphify update .`. Expected: the build succeeds and all Kit tests pass.
- [ ] **Step 4:** Commit: "Car tool merged into Wing Lab".
