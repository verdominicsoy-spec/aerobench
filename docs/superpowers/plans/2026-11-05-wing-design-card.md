# Wing Lab Design card Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Design card in Wing Lab that runs one `wing-design` job, from the rules box to finalists checked by RANS, filling the box and scoring in car terms, with the user picking the final wing.

**Architecture:** The engine gains four things: a layout that fills the box, a ground frame with height and fore-aft variables, scoring in car terms (`CarScore`), and a RANS separation verdict from skin friction. A new `wing-design` command chains the existing starter, estimate study, calibration and RANS checks. In the app, Kit decodes the result and converts box-frame positions to car placements. Wing Lab gets the card; the existing Study settings are its More.

**Tech Stack:** Python (numpy, Optuna, NeuralFoil, SU2 8.5, gmsh), pytest; Swift 6, SwiftUI, AeroBenchKit, xcodebuild.

**Spec:** `docs/superpowers/specs/2026-11-05-wing-design-card-design.md`

## Global Constraints

- No new dependencies.
- Engine tests: `cd engine && uv run pytest -q`. RANS tests need `AEROBENCH_SU2=/Users/warthog/aerobench/build/su2/bin/SU2_CFD` and skip without it.
- Kit: `cd app/AeroBenchKit && swift test`. App: `cd app && xcodebuild -scheme AeroBench -destination 'platform=macOS' build` → `** BUILD SUCCEEDED **`.
- sage37 (`S37.C.*`, no `ochreInk`, no `sageThin` in this app); one prominent button per view (Design).
- **The design frame**, used everywhere in this plan: metres, x downstream from the box's front edge, y up from the ground (ground at y = 0, along the flow, wing angle 0). Without a base car it is Wing Lab's own box, with the ground at `rideHeight` below the wing's lowest point.
- The goals and their engine keys: `max_cla`, `max_efficiency`, `min_lap_time`, `max_cla_cda_cap`, `balance`. With a base car, efficiency, the drag limit and balance use the whole car; without one, the wing alone. Balance needs a base car and counts within ±0.01 of the target as on it.
- Old objectives (`max_cl`, `max_ld`, `max_cl_cd_cap`, `min_cd_cl_target`) keep working for existing studies.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Run `graphify update .` after the last task.

## Review Focus

1. **A box too small for the element count** (5 elements in a 150 mm box). The job fails with a plain message naming the box, not a crash or an empty finalists list.
2. **Every finalist separated or not converged in RANS.** The card says "none held in RANS" and offers Check 3 More, and it never marks an estimate-only design as the winner.
3. **Start from the canvas with a wing outside the box,** for example after the base car changed. The job moves or scales it inside, or refuses with a reason. It is never silently clamped by the car afterwards.
4. **Balance with no base car,** or a base car with no downforce: the Balance chip is unavailable and says why, and the engine refuses `balance` without `car`.
5. **Cancelling a run midway, then Design again with the same settings.** It resumes the same study (same name), not a fresh one, and does not repeat RANS checks already done.

---

### Task 1: Layout fills the box

**Files:**
- Modify: `engine/src/aeroengine/wing/design.py` (`layout`, `starter`)
- Test: `engine/tests/test_wing_design.py`

**Interfaces:**
- Produces: `layout(units, chord_total, inverted, rules_box=None, min_gap=0.005, fill=False) -> Wing`. With `fill=True` and a box, the arrangement is scaled to the largest size with no issues: bisection on the scale, 12 steps, from the bounding box's fit. Its bounding box sits at the box's front (min x) and bottom (min y), and `chord_total` is ignored. `starter(..., fill: bool = False)` passes `fill` through to `layout`.

- [ ] **Step 1: Write the failing test**

```python
def test_a_filled_layout_uses_the_box():
    from aeroengine.wing.airfoils import naca4
    from aeroengine.wing.design import layout
    box = (0.0, 0.03, 0.70, 0.35)  # the front wing's box in the design frame: 700 mm long, 30 to 350 mm up
    for n in (2, 3, 5):
        w = layout([naca4("6412")] * n, 0.44, True, box, fill=True)
        pts = np.vstack([e.placed() for e in w.elements])
        assert not w.issues()
        width, height = np.ptp(pts[:, 0]), np.ptp(pts[:, 1])
        assert width >= 0.95 * 0.70 or height >= 0.95 * 0.32  # grown until one side of the box stops it
        assert pts[:, 0].min() == pytest.approx(0.0, abs=0.002) and pts[:, 1].min() == pytest.approx(0.03, abs=0.002)
```

- [ ] **Step 2:** `uv run pytest -q tests/test_wing_design.py -k filled`. Expected: FAIL (`fill` is unexpected).
- [ ] **Step 3:** Implement `fill` in `layout`. Build at scale 1 with the origin at 0 and measure the bounding box. Start the bisection on [0, the bounding box's fit to the box × 1.2], positioning each candidate's bounding box at the box's (x0, y0). Keep the largest scale with no issues. Gaps and overlaps stay absolute (`GAP`, `OVERLAP`), as now.
- [ ] **Step 4:** `uv run pytest -q tests/test_wing_design.py`. Expected: PASS, including the old tests.
- [ ] **Step 5:** Commit: "Wing design: a layout that fills the box".

### Task 2: Design frame, height and fore-aft variables, chord bounds from the box

**Files:**
- Modify: `engine/src/aeroengine/wing/geometry.py` (`Wing.ground_frame`, `apply`), `engine/src/aeroengine/wing/design.py` (`variables`)
- Test: `engine/tests/test_wing_design.py`

**Interfaces:**
- Produces:
  - `Wing.ground_frame: bool = False`. When set, `apply` places the wing in the design frame. `height_0` (m) moves the whole wing up or down so its lowest point is at that y. `x_0` (m) moves it so its most upstream point is at that x. `ride_height` is then the lowest point's y.
  - `variables(wing, shortlists=None, box=None) -> list[Variable]`. With `box` (design frame), each chord's high is `box width`. The list gains `Variable(0, "height", box.y0, box.y1)` and `Variable(0, "x", box.x0, box.x1)`. `"x"` joins the kinds `Spec` accepts.

- [ ] **Step 1: Write the failing tests**

```python
def test_the_wing_moves_in_the_design_frame():
    from aeroengine.wing.airfoils import naca4
    from aeroengine.wing.design import layout
    from aeroengine.wing.geometry import apply
    w = layout([naca4("6412")] * 2, 0.44, True, (0.0, 0.03, 0.70, 0.35), fill=True)
    w.ground_frame = True
    moved = apply(w, {"height_0": 0.08, "x_0": 0.10})
    pts = np.vstack([e.placed() for e in moved.elements])
    assert pts[:, 1].min() == pytest.approx(0.08, abs=1e-9) and moved.ride_height == pytest.approx(0.08, abs=1e-9)
    assert pts[:, 0].min() == pytest.approx(0.10, abs=1e-9)

def test_chords_may_grow_to_the_box():
    from aeroengine.wing.airfoils import naca4
    from aeroengine.wing.design import layout, variables
    w = layout([naca4("6412")] * 2, 0.30, True)
    vs = {v.name: v for v in variables(w, box=(0.0, 0.03, 0.70, 0.35))}
    assert vs["chord_0"].high == pytest.approx(0.70) and vs["chord_1"].high == pytest.approx(0.70)
    assert vs["height_0"].low == pytest.approx(0.03) and vs["x_0"].high == pytest.approx(0.70)
```

- [ ] **Step 2:** Run `-k "design_frame or grow_to_the_box"`. Expected: FAIL.
- [ ] **Step 3:** Implement. `apply` applies the translation last, after the slots. Check `Variable.name` for `"x"` (it reads `f"{kind}_{element}"`).
- [ ] **Step 4:** `uv run pytest -q tests/test_wing_design.py tests/test_wing_optimise.py`. Expected: PASS.
- [ ] **Step 5:** Commit: "Wing design: the wing moves in the box, chords grow to it".

### Task 3: Scoring in car terms

**Files:**
- Modify: `engine/src/aeroengine/wing/optimise.py` (`OBJECTIVES`, `Spec`, `score`, `LapScore`, the calls to `score` in `run`, `check` and `summary`)
- Test: `engine/tests/test_wing_optimise.py`

**Interfaces:**
- Produces:
  - `CarScore(span, endplate: float | None, factor, ref_chord, base: tuple[float, float, float] | None, axles: tuple[float, float] | None, cda_cap: float | None = None, rear_target: float | None = None)`.
    - `base` is (ClA, CdA, rear ClA) of the base car with the other end's wing.
    - `axles` is (front, rear) axle x in the design frame (m downstream).
    - `CarScore.wing(load, cd, wing) -> (cla, cda, xcp)` turns a coefficient on `ref_chord` into the wing's own ClA and CdA on its total chord `c`. It takes `cl_c = load · ref / c` and `cd_c = cd · ref / c`, then `car_contribution(-cl_c, cd_c, span, c, endplate, factor)`. `xcp` is the most upstream x + c / 4.
  - `Spec.car: CarScore | None`.
  - `score(spec, load, cd, wing=None) -> (value, feasible)` for the new objectives:
    - `max_cla`: the wing's ClA.
    - `max_efficiency`: (base ClA + cla) / (base CdA + cda) with a base, else cla / cda.
    - `max_cla_cda_cap`: over = max(0, CdA_used / cap − 1), where CdA_used is the whole car's with a base, else the wing's. Value cla − PENALTY · over.
    - `balance`: rear share = (base rear + cla · (xcp − xf) / (xr − xf)) / (base ClA + cla); off = max(0, |share − target| − 0.01). Value cla − PENALTY · off.
    - `min_lap_time`: `LapScore.lap_time(load, cd, chord=c)`, which uses the trial's chord.
  - `Spec.__post_init__` refuses `balance` without `car.base`, `car.axles` and `rear_target`, and refuses `max_cla_cda_cap` without `cda_cap`.

- [ ] **Step 1: Write the failing tests**

```python
def test_a_bigger_wing_scores_more_downforce():
    from aeroengine.wing.finite import car_contribution
    from aeroengine.wing.optimise import CarScore, Spec, score
    car = CarScore(span=1.2, endplate=0.25, factor=1.0, ref_chord=0.44, base=None, axles=None)
    spec = Spec([_var()], objective="max_cla", car=car)
    small, big = _wing(chord=0.44), _wing(chord=0.66)
    v_small = score(spec, 2.0, 0.05, small)[0]
    v_big = score(spec, 2.0 * 0.66 / 0.44 * 0.95, 0.05, big)[0]  # nearly the same section Cl on its own chord
    assert v_big > 1.3 * v_small
    cla, _ = car_contribution(-2.0, 0.05, 1.2, 0.44, 0.25)
    assert v_small == pytest.approx(cla)

def test_efficiency_is_the_whole_cars_with_a_base():
    from aeroengine.wing.optimise import CarScore, Spec, score
    on = CarScore(1.2, 0.25, 1.0, 0.44, base=(-0.2, 1.1, -0.1), axles=(0.9, 2.45))
    off = CarScore(1.2, 0.25, 1.0, 0.44, base=None, axles=None)
    w = _wing(chord=0.44)
    cla, cda, _ = on.wing(2.0, 0.05, w)
    assert score(Spec([_var()], objective="max_efficiency", car=on), 2.0, 0.05, w)[0] == pytest.approx((cla - 0.2) / (cda + 1.1))
    assert score(Spec([_var()], objective="max_efficiency", car=off), 2.0, 0.05, w)[0] == pytest.approx(cla / cda)

def test_balance_is_on_target_within_a_percent():
    from aeroengine.wing.optimise import CarScore, Spec, score
    car = CarScore(1.2, 0.25, 1.0, 0.44, base=(1.0, 1.1, 0.6), axles=(0.9, 2.45), rear_target=0.5)
    w = _wing(chord=0.44)  # its centre of pressure ahead of the front axle: it moves the balance forward
    value, ok = score(Spec([_var()], objective="balance", car=car), 2.0, 0.05, w)
    cla, _, xcp = car.wing(2.0, 0.05, w)
    share = (0.6 + cla * (xcp - 0.9) / (2.45 - 0.9)) / (1.0 + cla)
    assert ok == (abs(share - 0.5) <= 0.01)
    with pytest.raises(Exception, match="balance"):
        Spec([_var()], objective="balance", car=CarScore(1.2, 0.25, 1.0, 0.44, None, None))
```

`_var()` and `_wing(chord)` are test helpers in the file. `_var()` is `Variable(0, "angle", -4, 12)`. `_wing(chord)` is a one-element NACA 6412 `Wing` at the origin with that chord.

- [ ] **Step 2:** `uv run pytest -q tests/test_wing_optimise.py -k "bigger_wing or whole_cars or balance"`. Expected: FAIL.
- [ ] **Step 3:** Implement. `run` and `check` already build the trial's wing with `apply`; pass it to `score`. `summary` stores `cla`, `cda` and `cla_cda` for each trial, plus `car_cla`, `car_cda` and `rear_share` when there is a base.
- [ ] **Step 4:** `uv run pytest -q tests/test_wing_optimise.py tests/test_wing_design.py`. Expected: PASS, including the old objectives.
- [ ] **Step 5:** Commit: "Wing study: goals in car terms".

### Task 4: RANS says when the flow separates

**Files:**
- Modify: `engine/src/aeroengine/wing/su2.py` (`VOLUME_OUTPUT`), `engine/src/aeroengine/wing/rans.py` (`surface_cf`, `separation`, `solve`'s result), `engine/src/aeroengine/wing/optimise.py` (`check`)
- Test: `engine/tests/test_wing_rans.py`, fixture `engine/tests/data/surface_cf.csv`

**Interfaces:**
- Produces:
  - `surface_cf(path, placed) -> list[np.ndarray]`: each element's surface points with their tangential skin friction along the flow, from SU2's surface file.
  - `separation(cf_by_element, chords) -> (bool, str | None)`: separated when Cf_x < 0 over more than `SEPARATED_SHARE` of any element's surface length, leaving out the first 5% of chord.
  - `solve` returns `separated` and `separation` (the reason).
  - `check` treats a converged but separated run as not feasible, with reason "separated in RANS", and does the same when RANS Cd > 3 × the estimate's.

- [ ] **Step 1:** Add `SKIN_FRICTION` to `VOLUME_OUTPUT` in `su2.py`. Rerun one finished case, the NACA 4412 main alone at 100 mm (attached, Cd 0.0226), on the quick mesh. Read `surface.csv`'s header and confirm it holds `Skin_Friction_Coefficient_x`. If SU2 8.5 leaves it out of the CSV, read it from the wall points of `flow.vtu` instead, and note the ruling. Copy the 4412 surface file to `tests/data/surface_cf.csv`.
- [ ] **Step 2:** Rerun the stalled study wing (`tests/data/stalled_wing.json`, 30 mm, 20 m/s), and record each element's reversed-flow share. Set `SEPARATED_SHARE` between the 4412's share and the stalled wing's. Write both shares in a comment above the constant.
- [ ] **Step 3: Write the failing tests**

```python
def test_an_attached_wing_reads_attached():
    from aeroengine.wing.rans import separation, surface_cf
    els = _4412_main_at_100mm()  # the same placed coords as the fixture run
    sep, why = separation(surface_cf(DATA / "surface_cf.csv", els), [0.272])
    assert not sep and why is None

@needs_su2
def test_the_stalled_study_wing_reads_separated(tmp_path):
    r = _solve_stalled(tmp_path)  # tests/data/stalled_wing.json at 30 mm, quick mesh
    assert r["converged"] and r["separated"] and r["separation"].startswith("Main")
```

- [ ] **Step 4:** Run both. Expected: FAIL (`separation` is not defined).
- [ ] **Step 5:** Implement `surface_cf`, `separation`, the result fields and `check`'s rule.
- [ ] **Step 6:** `AEROBENCH_SU2=… uv run pytest -q tests/test_wing_rans.py tests/test_wing_optimise.py`. Expected: PASS.
- [ ] **Step 7:** Commit: "RANS: skin friction says when a wing separates".

### Task 5: The `wing-design` job

**Files:**
- Modify: `engine/src/aeroengine/commands/wing.py` (new `@command("wing-design")`)
- Test: `engine/tests/test_wing_design.py`

**Interfaces:**
- Consumes: `starter(fill=True)`, `layout`, `variables(box=)`, `Wing.ground_frame`, `CarScore`, `score`, `optimise.run`, `optimise.check`, the anchor calibration (Tasks 1 to 4).
- Produces: `wing-design` with these params:
  - `box` [x0, y0, x1, y1] in the design frame, plus `elements`, `inverted`, `goal` and the flow (as `wing-rans`).
  - `start`: elements as `wing-optimise` takes them, or absent for from scratch.
  - `span`, `endplate`, `factor`, `car` {base_cla, base_cda, base_rear_cla, axle_front, axle_rear} or absent, `cda_cap`, `rear_target`, `lap` (as `wing-optimise`).
  - `trials`, `checks` (1, 3 or 5), `min_thickness`, `storage`, `name`, `sampler`, `variables` (More's ranges; absent means the defaults from `variables`).

  The result is `{"base": <starter-shaped elements>, "study": <summary>, "finalists": [...]}`. Each finalist has `number`, `params`, `cla`, `cda`, `cla_cda`, `car_cla`, `car_cda`, `rear_share`, `ride_height`, `x` and `rans` {`cl`, `cd`, `converged`, `separated`, `reason`, `value`}, ranked by `rans.value` for the goal. Finalists whose RANS did not hold come after, unranked. A resumed run (same `storage` and `name`) skips the layout and the trials and checks already done.

- [ ] **Step 1: Write the failing tests**

```python
def test_design_without_rans_returns_ranked_finalists(tmp_path):
    out = _run_command("wing-design", {"box": [0.0, 0.03, 0.70, 0.35], "elements": 2, "inverted": True,
                                        "goal": "max_cla", "span": 1.2, "endplate": 0.25, "speed": 15.0,
                                        "trials": 30, "checks": 0, "storage": str(tmp_path / "d.db"), "name": "d"})
    f = out["finalists"]
    assert f and all(x["rans"] is None for x in f)
    pts = np.vstack([np.asarray(e["coords"]) for e in out["base"]["elements"]])
    assert np.ptp(pts[:, 0]) >= 0.6 or np.ptp(pts[:, 1]) >= 0.3  # the starting wing fills the box

def test_design_refuses_a_box_too_small():
    with pytest.raises(EngineError, match="box"):
        _run_command("wing-design", {"box": [0.0, 0.03, 0.15, 0.08], "elements": 5, "goal": "max_cla",
                                     "span": 1.2, "trials": 5, "checks": 0, "storage": "/tmp/x.db", "name": "x"})

def test_a_start_wing_outside_the_box_is_moved_inside(tmp_path):
    start = _elements_at(x=0.9, y=0.5)  # a 2-element wing beyond the box's back and top
    out = _run_command("wing-design", {"box": [0.0, 0.03, 0.70, 0.35], "elements": 2, "goal": "max_cla", "span": 1.2,
                                        "start": start, "trials": 5, "checks": 0, "storage": str(tmp_path / "s.db"), "name": "s"})
    pts = np.vstack([np.asarray(e["coords"]) for e in out["base"]["elements"]])
    assert pts[:, 0].max() <= 0.70 + 1e-9 and pts[:, 1].max() <= 0.35 + 1e-9

def test_design_again_resumes_the_same_study(tmp_path):
    p = {"box": [0.0, 0.03, 0.70, 0.35], "elements": 2, "goal": "max_cla", "span": 1.2, "trials": 12, "checks": 0,
         "storage": str(tmp_path / "r.db"), "name": "r"}
    first = _run_command("wing-design", p)
    again = _run_command("wing-design", p)
    assert again["study"]["complete"] == first["study"]["complete"]  # nothing new to run: the same 12 trials

@needs_su2
def test_design_with_rans_ranks_by_rans(tmp_path):
    out = _run_command("wing-design", {... "trials": 40, "checks": 3, "mesh": "quick"})
    held = [x for x in out["finalists"] if x["rans"] and x["rans"]["value"] is not None]
    assert [x["rans"]["value"] for x in held] == sorted((x["rans"]["value"] for x in held), reverse=True)
```

`_run_command` builds a `JobContext` the way `test_wing_optimise.py` does.

- [ ] **Step 2:** Run them. Expected: FAIL (unknown command).
- [ ] **Step 3:** Implement the command from the existing parts. Use `starter` with `fill=True` when there is no `start`; otherwise use the given wing, moved inside the box with `x_0`/`height_0` and scaled down if it is too big. Set `ground_frame` and `variables(box=)`. Run the estimate study with the calibration anchor, then `check(count=checks, until_pass=False)`, then rank. Report progress as 0 to 10 % layout, 10 to 60 % study, 60 to 100 % checks.
- [ ] **Step 4:** `AEROBENCH_SU2=… uv run pytest -q tests/test_wing_design.py`. Expected: PASS.
- [ ] **Step 5:** Commit: "Wing design: one job from the box to RANS finalists".

### Task 6: Kit: the design result and the design frame on the car

**Files:**
- Create: `app/AeroBenchKit/Sources/AeroBenchKit/WingDesign.swift`
- Test: `app/AeroBenchKit/Tests/AeroBenchKitTests/WingDesignTests.swift`

**Interfaces:**
- Produces:
  - `WingDesignResult: Decodable`, holding `base: [StarterElement]`, `study: WingStudy` and `finalists: [Finalist]`. `Finalist` holds `number`, `cla`, `cda`, `claCda`, `carCla?`, `carCda?`, `rearShare?`, `rideHeight`, `x` and `rans: RansVerdict?`. `RansVerdict` holds `cl`, `cd`, `converged`, `separated`, `reason?` and `value?`.
  - `WingDesignResult.decode(resultFile:)`.
  - `CarRules.designBox(_ position, setup) -> RulesBox`: the car's box in the design frame (m). Its x runs from 0 to the box length, and its y from (minZ − groundZ) to (maxZ − groundZ).
  - `Placement.fromDesign(card: WingCard, x: Double, setup: CarSetup) -> Placement`: the leading edge at car x = `box.maxX − x · 1000`, so `Placement.x` = that minus the axle. The height is `card.wing.rideHeight · 1000`.

- [ ] **Step 1: Write the failing tests**

```swift
func testDecodesADesignResult() throws {
    let r = try WingDesignResult.decode(resultFile: Data(Self.sample.utf8))  // a two-finalist sample in the file
    XCTAssertEqual(r.finalists.count, 2)
    XCTAssertEqual(r.finalists[0].rans?.separated, false)
    XCTAssertNil(r.finalists[1].rans?.value)
}

func testTheDesignBoxIsTheCarsBoxFromTheGround() {
    let b = CarRules.designBox(.front, setup: setup())  // CarBuilderTests' setup: front box x -402...298, z -18...302, ground -48
    XCTAssertEqual(b.minX, 0, accuracy: 1e-12); XCTAssertEqual(b.maxX, 0.700, accuracy: 1e-12)
    XCTAssertEqual(b.minY, 0.030, accuracy: 1e-12); XCTAssertEqual(b.maxY, 0.350, accuracy: 1e-12)
}

func testADesignPositionBecomesAPlacement() {
    var c = card(.front, rideHeight: 0.05)
    let p = Placement.fromDesign(card: c, x: 0.10, setup: setup())
    XCTAssertEqual(p.x, 298 - 100 + 629, accuracy: 1e-9)  // leading edge 100 mm behind the box front, from the front axle
    XCTAssertEqual(p.height, 50, accuracy: 1e-9)
    c.wing.rideHeight = nil
    XCTAssertEqual(Placement.fromDesign(card: c, x: 0.10, setup: setup()).height, 30, accuracy: 1e-9)  // no height: the clearance
}
```

- [ ] **Step 2:** `swift test --filter WingDesignTests`. Expected: FAIL (types missing).
- [ ] **Step 3:** Implement, reusing the starter element shape (`StarterResult`'s element) by moving it into Kit if it lives in the app.
- [ ] **Step 4:** `swift test`. Expected: all pass.
- [ ] **Step 5:** Commit: "Kit: wing design result and the design frame on the car".

### Task 7: App: the Design card

**Files:**
- Modify: `app/AeroBench/WingLabModel.swift` (`DesignSetup` gains `end`, `goal`, `checks`, `cdaCap`, `rearTarget`; `designResult`; `selectedFinalist`), `app/AeroBench/AppState+Wing.swift` (`runDesign()`, `useFinalist(_:)`, `designParams()`), `app/AeroBench/Views/WingLabView.swift` (new `DesignCard` at the top of `WingInspector`, replacing the old from-scratch/existing starter controls)
- Create: `app/AeroBench/Views/DesignCard.swift`

**Interfaces:**
- Consumes: Task 6's types, `lapObjectiveParams()`, `lapGoalCar()`, `quickResult(_:)`, `saveWingCard(asNew:)`, `putDraftOnCar()`, `syncCarRulesBox()`.
- Produces:
  - `AppState.runDesign()`: submits `wing-design` with:
    - `box`: `CarRules.designBox` with a base car, otherwise Wing Lab's box moved so the ground sits at y = 0;
    - `car`: from `quickResult(shownCombo.without(end))` and the axles in the design frame;
    - More's settings from `lab.optimise` (the same values the Study section edits);
    - `storage` and `name` from `lab.optimise.studyName`, so Design again resumes.
  - `AppState.useFinalist(_ f: Finalist)`: puts the finalist on the canvas (base wing + `applying(trial)`), sets `rideHeight` to `f.rideHeight`, saves it as a new card, and puts it on the selected combination at `Placement.fromDesign`. One undo step in Wing Lab.

- [ ] **Step 1:** `DesignCard` follows mockup A:
  - **The chips**, each a `Menu` whose current value is its label:
    - End: Front wing or Rear wing.
    - Elements: 2 to 5, locked to the canvas count under From This Wing.
    - Goal: Most Downforce, Best Efficiency, Fastest Lap, Downforce Under a Drag Limit (with a CdA field), Hit a Balance (with a rear % field; unavailable without a base car, with a `.help` saying why).
    - Start: From Scratch or From This Wing.
    - RANS check: best 1, 3 or 5.
    - More: a popover with the Study's settings (trials, sampler, ranges, sections, mesh, model, speed).
  - **Design**: the one prominent button, with an estimated time beside it.
  - **While running**: one progress line (`JobItem.progress`, `progressMessage`) and Cancel.
- [ ] **Step 2: Finalists.** Each row shows ClA, CdA and ClA/CdA, with the car's numbers when there is a base car. It also shows RANS's verdict: "held", "separated" or "did not converge". Selecting a row shows it on the canvas (undoable). The primary row action is Use This Wing. With no row held in RANS, show "None held in RANS" and a Check 3 More button (Design again with `checks` + 3).
- [ ] **Step 3:** Remove the old starter controls the card replaces, and point any "Set Up a Wing" entry at the card.
- [ ] **Step 4:** Build. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 5:** Commit: "Wing Lab: the Design card".

### Task 8: Record it

**Files:**
- Modify: `docs/DECISIONS.md`

- [ ] **Step 1:** Add a "Design card" entry. It should cover:
  - one job from the box to RANS finalists, which you pick from;
  - the box filled, and the wing free to move in it;
  - goals in car terms;
  - separation from skin friction, with the shares measured in Task 4.
- [ ] **Step 2:** Run the full engine suite, `swift test` and the app build, then `graphify update .`. Expected: all pass and the build succeeds.
- [ ] **Step 3:** Commit: "Design card recorded".
