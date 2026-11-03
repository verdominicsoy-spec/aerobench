# Car Builder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Car tool where Wing Lab wings become front and rear cards placed on the user's base car, judged quickly (sums) or fully (2D SU2 strips of the car with the wings in it), and sent to Lap Sim.

**Architecture:** A new engine package `engine/src/aeroengine/car/`: car setup (wheels, ground), sections on a plane, a gmsh car mesher that fuses wing outlines into the cut (wing through nose), an SU2 case with moving ground and rotating wheels, and a strips job that sums sections into ClA, CdA and an axle split. AeroBenchKit gets the shared types and the quick sum; the app gets Save as Card in Wing Lab and a new Car tool.

**Tech Stack:** Python 3, `cadquery-ocp`, gmsh, SU2 (as Wing Lab's RANS), pytest; Swift, SwiftUI, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-03-car-builder-design.md`

## Global Constraints

- STEP in mm; car axes set by the user (default +x forward, z up); sections are in the car's (x, z) plane at a chosen y.
- In SU2 the flow runs along +x, so the car's forward axis points to −x in the section (x_su2 = −x_car); results are mapped back.
- Wall layers: y+ target 50 (wall functions) on body and wheels, y+ 1 on wings.
- Ground moving or fixed, wheels rotating or fixed, each with its own speed, both defaulting to the car speed (default 15 m/s).
- Strips: default 7 planes over half the car, doubled by symmetry.
- Wings: a wing is present in a section when |y| ≤ span / 2. A front wing may overlap the nose; outlines are fused, and the wing's own curves keep their own marker.
- Rear-wheel drive: Lap Sim's `aeroBalanceDriven` = the rear axle's share of downforce.
- Full mode compares only with a bare-car baseline at the same mesh setting.
- Results labelled `quick` or `full` everywhere; combinations are marked stale when a card or the base car changes.
- No new dependencies. UI in the app's style (sage37).

## Review Focus

1. A section plane that cuts nothing (outside the car): an empty outline and a clear message, not a crash. (Task 2)
2. A cut whose edges do not close into loops (a gap in the CAD): the open bits are reported with their positions, and the closed loops still mesh. (Task 2)
3. SU2 that does not converge on a strip: the strip is marked not converged and the car total says so, never shown as a clean number. (Task 5)
4. A wing dragged outside its rules box: the placement stops at the box edge, typed values are clamped with a message. (Task 7)
5. A card edited in Wing Lab after it was placed: every combination using it shows "out of date". (Task 7)

## Data shapes

- `CarSetup` (JSON, project `car/setup.json`): `{"step": path, "forward": "+x", "up": "+z", "wheels": [{"name": "FL"|"FR"|"RL"|"RR", "centre": [x,y,z] mm, "radius": mm, "width": mm}], "ground_z": mm, "head_restraint": [x, z] mm | null, "speed": m/s}`.
- Section reply: `{"y": mm, "loops": [{"kind": "body"|"wheel", "wheel": "FL"?, "points": [[x, z] mm …]}], "open": [[x, z] mm …]}`.
- Placed wing (sent to the engine): `{"position": "front"|"rear", "elements": [[[x, z] m …] …] (already in car coordinates), "span": m, "factor3d": float, "endplate": m | null}`.
- Strip result: `{"y": mm, "width": mm, "lift": N/m (up +), "drag": N/m, "x_cp": mm (car x), "converged": bool, "wing_lift": {"front": N/m, "rear": N/m}, "wing_drag": {…}}`.
- Car result: `{"mesh": "coarse"|"medium"|"maxed", "speed": m/s, "cla": m², "cda": m², "rear_share": 0..1, "cla_2d_wings": m², "strips": [Strip], "converged": bool, "wings": [{"position", "cla", "cda"}]}` where `cla` = −2Σ(lift·width)/q (downforce positive) with each wing's share 3D-corrected; `cla_2d_wings` is the same without the correction.

---

### Task 1: Car setup — wheels and ground

**Files:** Create `engine/src/aeroengine/car/__init__.py`, `engine/src/aeroengine/car/setup.py`; Test `engine/tests/test_car.py`

**Interfaces:**
- Produces: `find_wheels(shape) -> list[dict]` (solids whose bounding box is round in x–z: |dx − dz| < 10 % and min(dx, dz) ≥ 250 mm, and narrow in y; merged per wheel when several solids share a centre within 20 mm; named FL/FR/RL/RR by x then y with +x forward); `ground_z(wheels) -> float` (lowest wheel bottom); `setup(path, forward="+x", up="+z") -> dict` (CarSetup without head restraint; speed 15). Command `car-setup` (job) returning it.

- [ ] **Step 1: Failing tests**: a synthetic car (`write_parts`: a 2000×600×400 box plus four cylinders r=230 w=200 at x = −400 and −1950) → 4 wheels named correctly, radius 230 ± 1, ground_z = −230 + their centre z; `pytest.mark.skipif` not exists `~/Downloads/basemodel.stp`: 4 wheels, front centre x ≈ −629 ± 15, rear ≈ −2179 ± 15, ground ≈ −48 ± 5.
- [ ] **Step 2: Run** `cd engine && uv run pytest -q tests/test_car.py`, expect FAIL (`ModuleNotFoundError`)
- [ ] **Step 3: Implement `setup.py` and the `car-setup` command (in a new `commands/car.py`, imported by `commands/__init__.py`)**
- [ ] **Step 4: Run, expect pass**
- [ ] **Step 5: Commit** (`Car: setup, wheels and ground`)

---

### Task 2: Sections

**Files:** Create `engine/src/aeroengine/car/section.py`; Modify `engine/src/aeroengine/serve.py`; Test `engine/tests/test_car.py`

**Interfaces:**
- Produces: `cut(shape, y_mm: float, setup: dict, min_area_mm2: float = 25.0) -> dict` (the section reply): `BRepAlgoAPI_Section` with the plane y = c, edges joined into wires (`ShapeAnalysis_FreeBounds.ConnectEdgesToWires_s`, tolerance 0.05 mm), closed wires sampled to polygons in (x, z) (curves at 0.5 mm chord error), loops under `min_area_mm2` dropped, a loop inside a wheel's circle (centre and radius from setup, at that y within the wheel's width) tagged `wheel`, open wires' end points in `open`. Serve handler `car-section` `{setup, y}` → `cut(...)` (part cached on path as `cad.edit.refs.load_part` does).

- [ ] **Step 1: Failing tests**: synthetic car at y = 0 → one body loop (area 2000×400 ± 1 %); at y through a wheel → a body loop and a wheel loop tagged with its name; y beyond the car → `loops == []` (Review Focus 1); a box with one face removed → `open` non-empty and other closed loops still returned (Review Focus 2); basemodel (skip if missing) at y = 0: ≥ 1 body loop, x extent ≈ −1728..282 ± 20.
- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement `cut` and the serve handler; update `tests/test_serve.py`'s command list**
- [ ] **Step 4: Run, expect pass**
- [ ] **Step 5: Commit** (`Car: sections on a plane`)

---

### Task 3: Car mesh

**Files:** Create `engine/src/aeroengine/car/mesh.py`; Test `engine/tests/test_car.py`

**Interfaces:**
- Consumes: section reply (Task 2); placed wings (Data shapes); `wing.mesh.first_cell_height`.
- Produces: `PRESETS = {"coarse": …, "medium": …, "maxed": …}` (surface sizes, growth, refinement box); `build(section: dict, wings: list[dict], setup: dict, preset: str, out: Path, re_body: float) -> dict` (stats incl. `markers`). gmsh OCC: each loop and each wing element is a plane surface (x_su2 = −x_car, y_su2 = z − ground_z, metres); wing surfaces fused with body surfaces they overlap (`occ.fuse`, keep the out-map so curves that came from a wing get marker `wing_front` / `wing_rear`); domain rectangle from 3 car lengths upstream to 6 downstream, 4 car heights up, floor on y = 0; boundary-layer fields: first cell for y+ 50 on `body`/`wheel_*`, y+ 1 (Wing Lab's rule) on `wing_*`; markers `body`, `wheel_FL`…, `wing_front`, `wing_rear`, `ground`, `inlet`, `outlet`, `top`. Wheel loops that touch the floor are lifted 1 mm (a contact patch cannot be meshed) — document it in the module docstring.

- [ ] **Step 1: Failing tests**: synthetic car section at y = 0 meshes with markers `{body, ground, inlet, outlet, top}` and > 0 quads; with a front wing overlapping the nose → markers include `wing_front` and the mesh has one fused body (no curve inside another); a section through a wheel → `wheel_FL` marker; `preset="maxed"` has more cells than `"coarse"`.
- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement `mesh.py`**
- [ ] **Step 4: Run, expect pass**
- [ ] **Step 5: Commit** (`Car: 2D car mesh with fused wings`)

---

### Task 4: SU2 car case

**Files:** Create `engine/src/aeroengine/car/case.py`; Test `engine/tests/test_car.py`

**Interfaces:**
- Consumes: Task 3 markers; `wing.su2.find_su2`, `run`, `read_history`, `judge`.
- Produces: `config(markers: list[str], setup: dict, flow: dict, mesh_file: str) -> str` where `flow = {"speed": m/s, "ground": {"moving": bool, "speed": m/s}, "wheels": {"rotating": bool, "speed": m/s}}`: SST, incompressible as Wing Lab's case, `MARKER_WALL_FUNCTIONS` on body and wheels, wings no-slip resolved, `SURFACE_MOVEMENT` with `MOVING_WALL` on the ground (translation rate = ground speed along +x) and on each wheel (rotation rate = wheel speed / radius about its centre, rolling with the ground) when enabled, `MARKER_MONITORING` per marker with per-surface coefficients in the history; `solve_section(section, wings, setup, flow, preset, workdir, su2_hint, cores, progress) -> dict` (a strip result without `width`).

- [ ] **Step 1: Failing tests**: `config` text: moving ground on → `MOVING_WALL` and the ground's translation rate equal to its speed; off → no `SURFACE_MOVEMENT` for the ground; wheel rotation rate = speed / radius (r = 0.23, 15 m/s → 65.2 rad/s); wall functions only on body and wheels. `@pytest.mark.skipif(no SU2)`: the synthetic car section at `coarse` solves and returns finite lift and drag with `converged` set (Review Focus 3 is checked by `judge`'s existing rule: assert the key exists and is bool).
- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement `case.py`**
- [ ] **Step 4: Run, expect pass**
- [ ] **Step 5: Commit** (`Car: SU2 case with moving ground and rotating wheels`)

---

### Task 5: Strips and the car result

**Files:** Create `engine/src/aeroengine/car/strips.py`; Modify `engine/src/aeroengine/commands/car.py`; Test `engine/tests/test_car.py`

**Interfaces:**
- Produces: `plan(half_width_mm: float, n: int = 7) -> list[tuple[float, float]]` ((y, width) mm, cosine-spaced towards the outside where the wheels are, widths summing to the half width); `combine(strips: list[dict], setup: dict, speed: float, rho: float, wings: list[dict], mesh: str) -> dict` (the car result): q = ½ρV², totals doubled, wing shares 3D-corrected as `WingGeometry.carContribution` does (lift × factor3d, or the finite-wing estimate when an endplate is given, induced drag added), rear share from each strip's x_cp between the axle x's (`rear = L·(x_front − x_cp)/(x_front − x_rear)`, unclamped), `converged` false if any strip is not. Command `car-strips` (job) `{setup, wings, flow, preset, planes?}`: plans, runs `solve_section` per plane with progress, writes `car_result.json`, returns it.

- [ ] **Step 1: Failing tests**: `plan(700, 7)` widths sum to 700, y strictly increasing, last y ≥ 600; `combine` with two hand-made strips (lift −100 N/m over 400 mm, −50 N/m over 300 mm, 15 m/s, ρ 1.225, so q = 137.8125 Pa) → cla = 2·55 / 137.8125 = 0.79819 m² (rel 1e-6); downforce at the front axle x → rear_share 0, at the rear → 1, midway → 0.5; one strip not converged → result `converged` false (Review Focus 3); a wing share with factor3d 0.8 → its cla is 0.8 × the 2D value and `cla_2d_wings` keeps the 2D value.
- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement `strips.py` and `car-strips`**
- [ ] **Step 4: Run** `uv run pytest -q`, all pass
- [ ] **Step 5: Commit** (`Car: strips and the car result`)

---

### Task 6: AeroBenchKit types, rules boxes and the quick sum

**Files:** Create `app/AeroBenchKit/Sources/AeroBenchKit/CarBuilder.swift`; Test `app/AeroBenchKit/Tests/AeroBenchKitTests/CarBuilderTests.swift`

**Interfaces:**
- Produces:
  - `CarSetup`, `CarResult` (`Codable`, snake-case keys as above).
  - `WingCard: Codable, Identifiable` (`id`, `name`, `position: WingPosition`, `wing: Wing`, `cla`, `cda`, `xcp: Double` (m from the wing's leading edge), `solver: String`, `rideHeight: Double?`, `speed`, `revision: Int` (bumped on every save)).
  - `Placement: Codable` (`card: String`, `x: Double` mm of the wing's leading edge from its axle, + forward, `height: Double` mm of the wing's lowest point above the ground) and `func placedElements(card, setup) -> [[SIMD2<Double>]]` in car (x, z) mm.
  - `CarRules.box(_ position: WingPosition, setup: CarSetup) -> (minX, maxX, minZ, maxZ)` mm in car coordinates: front from the front tyre leading edge forward 700, z from ground + 30 to ground + 350; rear from the rear tyre trailing edge back 250 (forward limit: the head restraint x, or the rear axle when not marked), z from ground + 30 to ground + 1100 (values as `data/rules/fs2027_aero.json`).
  - `Placement.clamped(to box, card, setup) -> (Placement, clamped: Bool)`.
  - `Combination: Codable, Identifiable` (`id`, `name`, `front: Placement?`, `rear: Placement?`, `cardRevisions: [String: Int]`, `baseRevision: Int`, `full: CarResult?`) and `isStale(cards:, baseRevision:) -> Bool`.
  - `QuickResult` and `func quick(base: CarResult, combo: Combination, cards: [WingCard], setup: CarSetup, estimate: (WingCard, Double) -> (cla: Double, cda: Double)?) -> QuickResult` (`cla`, `cda`, `rearShare`, `usedEstimate: [WingPosition]`): base plus each card's numbers (or `estimate(card, height)` when the placed height differs from the card's ride height by more than 1 mm), each wing's downforce acting at its placed xcp for the axle split.
- [ ] **Step 1: Failing tests**: rules boxes for a setup with front wheel at x −629 r 227 and ground −48 → front box x −402..298, z −18..302; a placement 50 mm outside the box → clamped and flagged (Review Focus 4); `quick` with a base of ClA 1.0 rear share 0.6 plus a front card ClA 0.8 placed 600 mm ahead of the front axle → total 1.8 and rear share (0.6·1.0 − 0.8·600/1550)/1.8 = 0.16129 (wheelbase 1550, rel 1e-4); a card revision bump → `isStale` true (Review Focus 5); placed height differing → `usedEstimate == [.front]`.
- [ ] **Step 2: Run** `cd app/AeroBenchKit && swift test --filter CarBuilderTests`, expect compile failure
- [ ] **Step 3: Implement `CarBuilder.swift`**
- [ ] **Step 4: Run, expect pass; then `swift test`, all pass**
- [ ] **Step 5: Commit** (`AeroBenchKit: car builder types, rules boxes, quick sum`)

---

### Task 7: Wing Lab: Save as Card

**Files:** Modify `app/AeroBench/WingLabModel.swift`, `app/AeroBench/Views/WingLabView.swift`; Create `app/AeroBench/CarStore.swift`

**Interfaces:**
- Produces: `CarStore` (project folder `car/`): `setup.json`, `cards/<id>.json`, `combinations.json`, `base_<mesh>.json` (bare-car results per mesh setting), with load/save functions. Wing Lab: a "Save as Card…" button in the wing section, enabled when the wing has a result; asks for a name; takes `position` from `wing.rulesFor`, cl/cd from the shown result via `carContribution`, `xcp` from the result's moment (or the quarter of the reference chord when the solver gives none), `rideHeight`, `speed`; saving a card with an existing name bumps its revision.
- [ ] **Step 1: Implement; Step 2: build (`xcodebuild … build` → `** BUILD SUCCEEDED **`); Step 3: commit** (`Wing Lab: save a wing as a car card`)

---

### Task 8: The Car tool

**Files:** Create `app/AeroBench/CarModel.swift`, `app/AeroBench/AppState+Car.swift`, `app/AeroBench/Views/CarView.swift`; Modify `app/AeroBench/Views/ContentView.swift` (new `.car` tool: title "Car", icon `car.side`, a backdrop curve as the other tools have), `docs/DECISIONS.md`

**Interfaces:**
- Consumes: Tasks 1–7. A `WarmEngine` for `car-section` and `wing-estimate`.
- Produces, in the Car view (sage37: Fraunces 24 title, takeaway line, solid panes):
  - **Base car pane**: Choose STEP…, axes pickers, Run setup (`car-setup` job), wheels listed with their numbers editable, "Mark head restraint" (click on the side view), car speed, ground and wheel options (toggle and speed each), mesh setting, strip count (default 7) and plane list (editable), Run Bare Car (strips job, result stored per mesh setting), the bare result (ClA, CdA, rear share, converged).
  - **Section pane**: a y slider over the car's width with the live outline (`car-section` through the warm engine, latest-only as the part editor does), open bits marked in clay.
  - **Side view pane**: the centreline outline, wheels, the two rules boxes, placed wings drawn from their sections; dragging a wing moves its placement (clamped), with x and height fields in step.
  - **Cards pane**: the saved cards (name, position, ClA, CdA, solver; an ochre note when the card's speed differs from the car speed), dragged or assigned to the front or rear slot of the selected combination.
  - **Combinations pane**: list with quick numbers always, full numbers when run, "out of date" in clay when stale, Run Full (strips job with the placed wings, same mesh as the baseline; re-runs the baseline at that mesh if missing), Send to Lap Sim (car A–E picker; sets cla, cda, `aeroBalanceDriven` = rear share; labels quick or full in the Lap Sim car's name).
  - Every edit undoable; everything saved through `CarStore`.
  - DECISIONS.md entry: strips over half the car, the fused wing-through-nose rule, y+ split, quick vs full with the 3D correction and same-mesh baseline, rear-drive balance, and the spec and plan paths.
- [ ] **Step 1: Implement `CarModel` and `AppState+Car`; build**
- [ ] **Step 2: Implement `CarView` and the dock entry; build**
- [ ] **Step 3: Run the app with basemodel.stp: setup, section slider, bare-car strips at coarse, one front and one rear card placed, quick result, Send to Lap Sim**
- [ ] **Step 4: DECISIONS.md entry and commit** (`Car tool: modular wings on the base car`)
