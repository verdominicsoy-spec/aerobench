# Live field matched to RANS — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wing Lab's live flow (field, streamlines, surface Cp) carries the live estimate's lift instead of the inviscid panel method's, and its wakes spread as RANS's do, with a committed RANS fixture that pins the gains.

**Architecture:** `PanelSolver` gains a solve that replaces each element's Kutta row with a prescribed circulation, scaled until each element's lift equals the estimate's. `WingLabModel` uses it when the estimate is of the wing as drawn, over the ground as in free air. `Wake.sigma` grows three times faster. Three RANS fields, decimated, live in `docs/validation/live-field/` with a Kit test of field, streamline, wake and surface metrics.

**Tech Stack:** Swift (AeroBenchKit, Accelerate LAPACK `dgetrf_`/`dgetrs_`), SwiftUI (Wing Lab), Python 3.12 engine (`uv run`) for the fixture script, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-07-live-field-vs-rans-design.md`

## Global Constraints

- Fixture cases, exactly: `20261106-171046-1b32` (2 elements, free air), `20261104-173556-baec` (3, free air), `20261106-120151-c003` (5, ride height 0.707 m).
- Circulation passes: 3; each scales Γe by the element's target / achieved Cl, clamped to 0.3…1.5, only when |achieved Cl| > 0.02.
- Targets apply only when the estimate was made for `wing` as drawn (`estimateWing == wing`), its nearest row is within 0.6° of `wing.alpha`, and it has one entry per element; otherwise the Kutta solution as today.
- Over the ground: the image solver (`PanelSolver(elements:refChord:ground:)` at alpha 0) takes the targets directly; `groundCorrected(free:)` stays only for the Kutta fallback.
- Surface Cp charts leave out nodes within 5% of the element's chord of its trailing edge when `liftMatched`.
- Wake width: `sigma = 0.255 * sqrt(theta * (3 * s + 4 * theta))`.
- Live field build stays under 100 ms at `nx: 400` for 5 elements in release (`swift test -c release`); the matched solve adds at most 15 ms for 805 nodes.
- Never hand-build `build/DerivedData` Release (it blanks the update check's commit stamp); verify with the Debug build in `build/DebugDD`.
- Every commit ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; run `graphify update .` after each.

## Review Focus

- **Stale estimate after an edit:** while the next estimate is in flight (or blocked because elements overlap, `scheduleLiveEstimate` returns early), the old estimate must not steer the new geometry: the preview falls back to Kutta (`testLiftTargetsNeedTheSameWingTheRowAndElementCount`, Task 3; dragging check in Task 3 Step 5).
- **Swap A and B:** `swapWithPinned()` moves the estimate; the wing it was made for must move with it, or B is matched to A's lift (app check, Task 3 Step 5).
- **An element with near-zero lift** (a 3-element wing's last flap, Cl −0.005 in RANS): no division blow-up; that element keeps its Kutta circulation (`testANearZeroLiftElementKeepsItsCirculation`, Task 2).
- **Bad targets or a failed matched factorisation:** the Kutta solution, never a NaN field (`testMismatchedTargetsGiveTheKuttaSolution`, Task 2; the factorisation guard has no test: none of the 12 cases made it fail).
- **Separated wing:** the estimate row flags `separating`; the field legend must say the live field cannot show it rather than look confident (app check with Flap 1 at 40°, Task 3 Step 5).

---

### Task 1: RANS fixtures and the validation harness

**Files:**
- Create: `docs/validation/live-field/make_fixtures.py`
- Create: `docs/validation/live-field/<case>/field.json`, `field.bin`, `case.json` for the three cases (generated)
- Create: `app/AeroBenchKit/Tests/AeroBenchKitTests/LiveFieldValidationTests.swift`

**Interfaces:**
- Produces (test target, file-private where possible):
  - `struct ValidationCase { let id: String; let elements: [[SIMD2<Double>]]; let alpha: Double; let rideHeight: Double?; let refChord: Double; let rans: WingField; let ransSurface: [(x: [Double], y: [Double], cp: [Double])]; let estimateCl: [Double]; let estimateCdOwn: [Double]; static func load(_ id: String) throws -> ValidationCase }` reading `docs/validation/live-field/<id>/` via `#filePath`.
  - `func preview(_ c: ValidationCase, matched: Bool) -> PanelSolution` — as `WingLabModel.recompute()`; `matched` is false until Task 3.
  - `func fieldCp(_ live: WingField, _ c: ValidationCase) -> (nearRMS: Double, nearBias: Double, outerRMS: Double)` — on the RANS grid, cells where both are finite; "near" within 0.25 `refChord` of any element node and RANS Cp0 ≥ −0.02, "outer" the rest outside wakes.
  - `func streamlineError(_ s: PanelSolution, _ c: ValidationCase) -> (p50: Double, p95: Double)` — trace `VortexPanels(s)` (RK2, step 0.002 `refChord`) from each RANS streamline's first point for its arc length; end distance ÷ `refChord`; skip traces that stop or enter a body.
  - `func wakeMoments(_ f: WingField, x: Double) -> (yc: Double, sd: Double)?` — over a vertical line at x, step 0.5 mm, weight −Cp0 where Cp0 < −0.005: centroid and second-moment width.
  - `func surfaceCpMidRMS(_ s: PanelSolution, _ c: ValidationCase) -> Double` — panel nodes between 5% and 95% of chord from the trailing edge against the nearest RANS surface point of the same element.
  - `func stations(_ c: ValidationCase) -> [Double]` — x = last trailing edge x + {0.25, 0.5} × `refChord`.

- [ ] **Step 1: Write `make_fixtures.py`**

Run from `engine/` with `uv run python -I ../docs/validation/live-field/make_fixtures.py`. For each case, read `~/Library/Application Support/AeroBench/Scratch/jobs/<id>/{job,result,field}.json` and `field.bin`. Write `field.json`/`field.bin` in the same format (`WingField.load` must read it) keeping every third cell in x and y (`i % 3 == 1`), only the scalars `cp`, `speed`, `cp0`, and the streamlines and outlines unchanged. Write `case.json`: `{"elements": [[[x, y], …], …], "alpha", "ride_height", "ref_chord", "rans": {"cl", "cd", "surface": [{"x", "y", "cp"}]}, "estimate": {"el_cl", "cd_own", "cl", "cd"}}`, the estimate from `aeroengine.wing.estimate.estimate(...)` with the job's speed, rho, mu, ref_chord and ride_height. Each case folder stays under 400 kB.

- [ ] **Step 2: Run it**

Run: `cd engine && uv run python -I ../docs/validation/live-field/make_fixtures.py && du -sh ../docs/validation/live-field/*`
Expected: three folders, each under 400K.

- [ ] **Step 3: Write the harness test that pins today's (Kutta) numbers, proving the metrics reproduce the spec**

```swift
func testTheHarnessReproducesTheMeasurements() throws {
    let c = try ValidationCase.load("20261106-171046-1b32")
    let s = preview(c, matched: false)
    let live = try XCTUnwrap(s.field(nx: 400, wakeCd: c.estimateCdOwn))
    let f = fieldCp(live, c)
    XCTAssertEqual(f.nearRMS, 0.146, accuracy: 0.04)
    XCTAssertEqual(f.nearBias, -0.055, accuracy: 0.03)
    XCTAssertEqual(streamlineError(s, c).p50, 0.021, accuracy: 0.008)
    let g = try ValidationCase.load("20261106-120151-c003")
    XCTAssertEqual(fieldCp(try XCTUnwrap(preview(g, matched: false).field(nx: 400, wakeCd: g.estimateCdOwn)), g).nearRMS, 0.77, accuracy: 0.15)
}
```

- [ ] **Step 4: Run it**

Run: `cd app/AeroBenchKit && swift test --filter LiveFieldValidationTests`
Expected: PASS (if a number sits outside its band, the decimation or a metric differs from the spec's harness: fix the harness, not the band).

- [ ] **Step 5: Commit** — `git add docs/validation/live-field app/AeroBenchKit/Tests/AeroBenchKitTests/LiveFieldValidationTests.swift` with message "Live field: three RANS fields and a harness that measures the live field against them".

---

### Task 2: Prescribed-circulation solve

**Files:**
- Modify: `app/AeroBenchKit/Sources/AeroBenchKit/PanelSolver.swift`
- Test: `app/AeroBenchKit/Tests/AeroBenchKitTests/WingTests.swift` (class `PanelSolverTests`)

**Interfaces:**
- Produces:
  - `PanelSolution.liftMatched: Bool` (stored `public var`, default `false`).
  - `PanelSolver.solve(alphaDeg: Double, targetCl: [Double]) -> PanelSolution` — `liftMatched = true` on success; the plain Kutta solution (`liftMatched = false`) when `targetCl.count != elements.count`, any target is not finite, or the factorisation fails.
  - The force integration moves to `private func forces(_ gamma: [Double], alphaDeg: Double) -> PanelSolution`, shared by both solves.

- [ ] **Step 1: Write the failing tests**

```swift
func testTargetsEqualToKuttaLiftChangeNothing() throws {
    let s = try XCTUnwrap(PanelSolver(elements: [naca("4412").coords]))
    let k = s.solve(alphaDeg: 5), m = s.solve(alphaDeg: 5, targetCl: k.cl)
    XCTAssertTrue(m.liftMatched)
    XCTAssertEqual(m.cl[0], k.cl[0], accuracy: 1e-6)
    for (a, b) in zip(k.cp[0][10..<150], m.cp[0][10..<150]) { XCTAssertEqual(a, b, accuracy: 1e-4) }
}

func testEachElementReachesItsTargetLift() throws {
    let main = WingElement(airfoil: naca("6412"), chord: 0.3, angle: 3)
    let flap = WingElement(airfoil: naca("4412"), chord: 0.12, angle: 20, leadingEdge: main.trailingEdge + SIMD2(-0.01, 0.015))
    let s = try XCTUnwrap(PanelSolver(elements: [main.placed(), flap.placed()]))
    let k = s.solve(alphaDeg: 0)
    let target = k.cl.map { 0.8 * $0 }
    let m = s.solve(alphaDeg: 0, targetCl: target)
    for (a, t) in zip(m.cl, target) { XCTAssertEqual(a, t, accuracy: 0.02 * abs(t)) }
    // Still no flow through the surface: at each panel middle the velocity is along the panel.
    let v = VortexPanels(m)
    for e in m.elements { for j in stride(from: 5, to: e.count - 6, by: 7) {
        let d = simd_normalize(e[j + 1] - e[j]), mid = 0.5 * (e[j] + e[j + 1]) + 1e-4 * SIMD2(d.y, -d.x)
        XCTAssertLessThan(abs(simd_dot(v.velocity(at: mid), SIMD2(d.y, -d.x))), 0.05)
    } }
}

func testANearZeroLiftElementKeepsItsCirculation() throws { /* flap target 0.001: no NaN, its cl within 0.02 of Kutta's */ }
func testMismatchedTargetsGiveTheKuttaSolution() throws { /* count 1 for 2 elements, and a NaN target: liftMatched false, cl == Kutta */ }
func testTargetsWorkOverTheGround() throws { /* ground solver at alpha 0, target 0.7 × Kutta: within 2% */ }
```

- [ ] **Step 2: Run them**

Run: `cd app/AeroBenchKit && swift test --filter PanelSolverTests`
Expected: FAIL to compile (`solve(alphaDeg:targetCl:)`, `liftMatched` missing).

- [ ] **Step 3: Implement**

In `init`, keep a copy of the unfactorised matrix with each Kutta row `m + e` replaced by the circulation row (entries ½|Δsj| on γj and γj+1 over the element's panels), factorised lazily on first use behind an `OSAllocatedUnfairLock` (the solver is `@unchecked Sendable` and the live field reads it off the main thread). The matched solve: start Γe from the Kutta solution's ∮γ ds, then 3 passes of the rule in Global Constraints, each a `dgetrs_` back substitution with the freestream ψ rows, the sharp-edge rows as in `solve(alphaDeg:)`, and Γe in rows `m + e`.

- [ ] **Step 4: Run them, then the release timing**

Run: `swift test --filter PanelSolverTests` → PASS. Add a timing line to `testEachElementReachesItsTargetLift` printing the matched solve's milliseconds for a 5-element wing (5 × 161 nodes); `swift test -c release --filter PanelSolverTests` → under 15 ms.

- [ ] **Step 5: Commit** — "Panel solver: a solve with each element's lift prescribed, for the live flow".

---

### Task 3: The preview takes the estimate's lift

**Files:**
- Modify: `app/AeroBenchKit/Sources/AeroBenchKit/WingRans.swift` (`WingEstimate`)
- Modify: `app/AeroBenchKit/Sources/AeroBenchKit/PanelSolver.swift` (chart helper)
- Modify: `app/AeroBench/WingLabModel.swift` (`recompute()`, `estimate` didSet, `Pinned`, `swapWithPinned()`)
- Modify: `app/AeroBench/AppState+Wing.swift` (`scheduleLiveEstimate()`)
- Modify: `app/AeroBench/Views/WingLabView.swift` (`CpPlot`, field legend at "live, rough"), `app/AeroBench/Views/WingReportView.swift` (its Cp chart)
- Test: `app/AeroBenchKit/Tests/AeroBenchKitTests/LiveFieldValidationTests.swift`, `WingTests.swift`

**Interfaces:**
- Consumes: `PanelSolver.solve(alphaDeg:targetCl:)`, `PanelSolution.liftMatched` (Task 2).
- Produces:
  - `WingEstimate.liftTargets(madeFor: Wing?, wing: Wing) -> [Double]?` — nil unless `madeFor == wing`; then the nearest row to `wing.alpha`'s per-element `cl` when within 0.6° and one per element, else nil.
  - `PanelSolution.chartCp(element i: Int, chord: Double) -> [Double?]` — `cp[i]` with nil for nodes within 0.05 `chord` of the element's trailing edge when `liftMatched`; all values otherwise.
  - `WingLabModel.estimateWing: Wing?` — the wing the current `estimate` was made for; `Pinned.estimateWing: Wing?` likewise.

- [ ] **Step 1: Write the failing tests**

In `LiveFieldValidationTests` (switch `preview(_:matched:)` to use `liftTargets` and the matched solve when `matched` is true, exactly as `recompute()` will):

```swift
func testMatchedLiftBringsTheFlowToRans() throws {
    for (id, near, outer, p50, p95) in [("20261106-171046-1b32", 0.08, 0.04, 0.015, 0.03),
                                        ("20261104-173556-baec", 0.08, 0.04, 0.015, 0.03),
                                        ("20261106-120151-c003", 0.15, 0.07, 0.03, 0.06)] {
        let c = try ValidationCase.load(id)
        let s = preview(c, matched: true)
        XCTAssertTrue(s.liftMatched, id)
        let f = fieldCp(try XCTUnwrap(s.field(nx: 400, wakeCd: c.estimateCdOwn)), c)
        XCTAssertLessThan(f.nearRMS, near, id); XCTAssertLessThan(f.outerRMS, outer, id)
        let e = streamlineError(s, c); XCTAssertLessThan(e.p50, p50, id); XCTAssertLessThan(e.p95, p95, id)
        XCTAssertLessThan(surfaceCpMidRMS(s, c), id.hasSuffix("c003") ? 0.6 : 0.25, id)
    }
}

func testMatchedWakesSitWhereRansPutsThem() throws {
    // At both stations of every case: |live centroid − RANS centroid| < 0.02 refChord.
}
```

In `WingTests.swift`: `testLiftTargetsNeedTheSameWingTheRowAndElementCount` (`madeFor` nil or a wing with one element moved 1 mm → nil; row 3° away → nil; 2 entries for 3 elements → nil; same wing within 0.6° → the row's element cls) and `testChartCpLeavesOutTheTrailingEdgeOnlyWhenMatched`.

- [ ] **Step 2: Run them**

Run: `swift test --filter "LiveFieldValidationTests|WingTests"`
Expected: FAIL (`liftTargets`, `chartCp` missing; the harness thresholds fail on Kutta).

- [ ] **Step 3: Implement the Kit pieces** (`liftTargets`, `chartCp`), then run the Kit tests → PASS.

- [ ] **Step 4: Wire the app**

- `scheduleLiveEstimate()`: capture `let asked = lab.wing` just before each `estimateParams()`; on success set `lab.estimateWing = asked` before `lab.estimate = …`.
- `recompute()`: `let targets = estimate?.liftTargets(madeFor: estimateWing, wing: wing)`; free air `solver.solve(alphaDeg: wing.alpha, targetCl: t)`; ground `solver.solve(alphaDeg: 0, targetCl: t)` on the image solver with no `groundCorrected`; nil targets keep today's code.
- `estimate` didSet calls `recompute()` (it ends in `traceStreamlines`, which makes the field) instead of `makeLiveField()`.
- `Pinned` stores `estimateWing`; `current` (the `Pinned` that `pinCurrent()` keeps) and `swapWithPinned()` move it with `estimate`.
- `CpPlot` and `WingReportView` plot `chartCp(element:chord:)`; the title reads "Surface pressure, inviscid, lift from the live estimate (−Cp up)" when `liftMatched`.
- Field legend: "live, lift from the estimate" when the preview is matched, "live, inviscid" when not, plus "; separating, not shown" when the estimate row at `wing.alpha` has `separating == true`.

- [ ] **Step 5: Verify in the app**

Run: `xcodebuild -project app/AeroBench.xcodeproj -scheme AeroBench -configuration Debug -derivedDataPath build/DebugDD -destination 'platform=macOS,arch=arm64' build` → `BUILD SUCCEEDED`. Launch it; add 2element Main then 2element Flap 1. Expected: the legend changes from "live, inviscid" to "live, lift from the estimate" once the estimate arrives; the Cl in the live estimate and the preview agree; dragging the flap shows "live, inviscid" until the next estimate lands; Pin as A, change B, Swap A and B: each design keeps its own legend and Cl; set Flap 1's angle to 40°: the legend adds "separating, not shown".

- [ ] **Step 6: Commit** — "Wing Lab: the live flow carries the estimate's lift".

---

### Task 4: Wakes spread as RANS's do

**Files:**
- Modify: `app/AeroBenchKit/Sources/AeroBenchKit/PanelField.swift` (`Wake.sigma` and the `Wake` doc comment)
- Test: `app/AeroBenchKit/Tests/AeroBenchKitTests/LiveFieldValidationTests.swift`

**Interfaces:**
- Consumes: the matched `preview` (Task 3).

- [ ] **Step 1: Write the failing test**

```swift
func testWakesSpreadAsRansDoes() throws {
    var logs: [Double] = []
    for id in ["20261106-171046-1b32", "20261104-173556-baec", "20261106-120151-c003"] {
        let c = try ValidationCase.load(id)
        let live = try XCTUnwrap(preview(c, matched: true).field(nx: 400, wakeCd: c.estimateCdOwn))
        for x in stations(c) {
            let l = try XCTUnwrap(wakeMoments(live, x: x)), r = try XCTUnwrap(wakeMoments(c.rans, x: x))
            logs.append(abs(log(l.sd / r.sd)))
        }
    }
    XCTAssertLessThan(logs.reduce(0, +) / Double(logs.count), 0.30)  // 0.36 at k = 1, 0.22 at k = 3
}
```

- [ ] **Step 2: Run it** → FAIL (about 0.36).

- [ ] **Step 3: Implement** `sigma` per Global Constraints; the doc says the growth is three times the zero-pressure-gradient law's, fitted to six RANS wakes behind high-lift wings (mean width error 24%, was 62%).

- [ ] **Step 4: Run every Kit test** — `swift test` → all pass, including `PanelFieldTests` (momentum still θ: the amplitude follows σ) and `testFieldIsQuick`; `swift test -c release --filter PanelFieldTests/testFieldIsQuick` under 100 ms.

- [ ] **Step 5: Commit** — "Live field: wakes spread three times the flat-plate rate, as RANS behind a high-lift wing".

---

## Not in this plan (from the spec)

- Wake loss magnitude: follows the estimate's drag (0.60–1.33 of RANS, RANS itself ±40% between meshes) — the estimate's work.
- The slot jet between a main wake and the next element: 2–8 mm, below the app's grid; clearance was tried and rejected.
- Separated and extreme-ground cases (`2ed3`: estimate Cl −2.51 vs −1.81, Cd 0.086 vs 0.51): an estimate and ground-model question; Task 3 only labels them.
