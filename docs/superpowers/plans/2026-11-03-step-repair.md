# STEP Repair to One Body Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A CAD Viewer action that turns a STEP file into one closed, valid body: tiny defects fixed without asking, medium gaps (0.5 to 10 mm) queued for review, then everything fused and written as `<name>_repaired.step`.

**Architecture:** One new engine module, `cad/bodyrepair.py`, holds the pipeline (clean, stepped sewing, gap pairing, bridging, hole filling, fuse, verify). One engine command, `cad-repair-body`, runs it: without `accept` it is the plan job (pending items count as skipped, output still written); with `accept` it is the apply job. The app decodes the result in AeroBenchKit, shows the queue in the CAD Viewer's Geometry check section, draws previews in the viewer, and saves decisions next to the source.

**Tech Stack:** Python 3 + `cadquery-ocp` (OpenCascade), pytest; Swift, SwiftUI, SceneKit, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-03-step-repair-design.md`

## Global Constraints

- STEP / STP only. IGES and meshes are out of scope; the existing `cad-repair` stays as it is.
- Automatic gap limit default **0.5 mm**, a user setting. Queue band **0.5 to 10 mm**. Over **10 mm**: report only.
- Cleanup (tiny edges, sliver faces, ShapeFix precision) uses its own tolerance, **0.01 mm**, never the gap limit.
- Gaps are paired **within one part only**. Never between parts.
- Fuse fuzzy value **0.01 mm** (the cleanup tolerance), so parts a fraction of a mm apart are not merged.
- Apply always writes the file. Unclosed parts go in as separate open shells; the result says closed only when it is.
- Decisions file: `<source stem>.repair.json` next to the source. A saved decision matches when kind and part match and centres are within **3 mm** (part-local coordinates).
- STEP and OCP work in mm; the viewer and all JSON points are in metres (`tessellate.MM = 0.001`).
- No new dependencies. Engine commands follow the `@command` pattern; app jobs go through `jobs.submit`.
- App UI follows the existing Geometry check section style (sage37, `S37.C` colours).

## Review Focus

1. A surface-model plate 0.3 mm thick with 0.05 mm gaps: stepped sewing must stop at the first tolerance that closes it, and the plate must survive with its volume. (Task 1)
2. A part placed several times (the sample car's wheels): repaired once, one queue item per defect, preview lines at every placement. (Task 4)
3. A file that needs nothing: no items, closed and valid, and the app offers to save straight away. (Tasks 4, 6)
4. A fuse that fails inside OpenCascade: the job still writes the unfused solids and reports `fused: false`, never crashes. (Task 4)
5. A saved decision for a part that moved more than 3 mm or was renamed: ignored, not applied to a different gap. (Task 3)

---

### Task 1: Clean, stepped sewing, solids

**Files:**
- Create: `engine/src/aeroengine/cad/bodyrepair.py`
- Test: `engine/tests/test_bodyrepair.py`

**Interfaces:**
- Produces:
  - `CLEAN_TOL_MM = 0.01`, `SEW_STEPS_MM = (0.01, 0.02, 0.05, 0.1, 0.2, 0.5)`
  - `clean_part(shape, tol_mm: float = CLEAN_TOL_MM) -> tuple[TopoDS_Shape, dict]`: `ShapeFix_Shape` at precision `tol_mm`, small edges removed (`ShapeFix_Wireframe.FixSmallEdges`) and sliver faces removed (`ShapeFix_FixSmallFace`) at `tol_mm`. Stats keys: `small_edges_removed`, `small_faces_removed`.
  - `free_edges(shape) -> list[TopoDS_Edge]`, `nonmanifold_edges(shape) -> list[TopoDS_Edge]` (edge-to-face map size 1, and >= 3).
  - `sew_stepped(shape, limit_mm: float) -> tuple[TopoDS_Shape, float | None]`: returns the shape unchanged and `None` when it has no free edges; otherwise sews at each step in `SEW_STEPS_MM` up to `limit_mm` (and `limit_mm` itself if not in the list), stopping at the first with no free edges. Returns the sewn shape and the tolerance used (the last tried when edges remain).
  - `to_solids(shape) -> tuple[list[TopoDS_Solid], list[TopoDS_Shell]]`: each closed shell becomes a solid (`BRepBuilderAPI_MakeSolid` + `ShapeFix_Solid` for orientation); existing solids pass through; shells with free edges are returned as open.
  - Test helper in the test file: `faces_of_box(dx, dy, dz, move=None) -> TopoDS_Compound`, a box's six faces as a loose compound, optionally one face translated by a `gp_Vec` (this plants gaps of a known size).

- [ ] **Step 1: Write the failing tests**

```python
def test_closed_solid_is_not_sewn():
    box = BRepPrimAPI_MakeBox(10, 10, 10).Shape()
    out, tol = sew_stepped(box, 0.5)
    assert tol is None and out.IsSame(box)

def test_tiny_gap_sews_at_the_smallest_step():
    shape = faces_of_box(100, 100, 100, move=("top", gp_Vec(0, 0, 0.015)))
    out, tol = sew_stepped(shape, 0.5)
    assert tol == 0.02 and not free_edges(out)
    solids, open_ = to_solids(out)
    assert len(solids) == 1 and not open_
    assert volume(solids[0]) == pytest.approx(1e6, rel=1e-3)

def test_thin_plate_survives():
    shape = faces_of_box(100, 100, 0.3, move=("top", gp_Vec(0, 0, 0.05)))
    out, tol = sew_stepped(shape, 0.5)
    assert tol <= 0.1
    solids, _ = to_solids(out)
    assert len(solids) == 1 and volume(solids[0]) > 100 * 100 * 0.29  # not collapsed

def test_gap_over_the_limit_stays_open():
    out, tol = sew_stepped(faces_of_box(100, 100, 100, move=("top", gp_Vec(0, 0, 5))), 0.5)
    assert tol == 0.5 and free_edges(out)
    solids, open_ = to_solids(out)
    assert solids == [] and len(open_) == 1
```

(`volume` is `GProp_GProps` via `BRepGProp.VolumeProperties_s`, a helper in the test file.)

- [ ] **Step 2: Run to verify they fail**

Run: `cd engine && uv run pytest -q tests/test_bodyrepair.py`
Expected: FAIL, `ModuleNotFoundError: aeroengine.cad.bodyrepair`

- [ ] **Step 3: Implement the four functions above in `bodyrepair.py`**

Reuse `_subshapes` and the `EdgeFaceMap` pattern from `brepcheck.py`.

- [ ] **Step 4: Run to verify they pass**

Run: `cd engine && uv run pytest -q tests/test_bodyrepair.py`
Expected: 4 passed

- [ ] **Step 5: Commit** (`Body repair: cleaning, stepped sewing, solids`)

---

### Task 2: Gap pairing, bridging, hole filling

**Files:**
- Modify: `engine/src/aeroengine/cad/bodyrepair.py`
- Test: `engine/tests/test_bodyrepair.py`

**Interfaces:**
- Consumes: `free_edges`, `sew_stepped`, `to_solids` (Task 1).
- Produces:
  - `QUEUE_MAX_MM = 10.0`
  - `@dataclass Gap: edges: tuple[TopoDS_Edge, TopoDS_Edge]; size_mm: float; centre_mm: tuple[float, float, float]; lines_mm: list[list[tuple[float, float, float]]]`
  - `find_gaps(shape) -> list[Gap]`: pairs free edges of one shape. Gap size of a pair = the largest distance from points sampled along the shorter edge (11 points) to the other edge (`BRepExtrema_DistShapeShape` against the edge, or `GeomAPI_ProjectPointOnCurve`). Pair each free edge with the free edge that gives it the smallest size; keep mutual pairs only. `lines_mm` = the two edges sampled as polylines. Sorted by size.
  - `bridge(shape, gap: Gap) -> TopoDS_Shape`: adds a ruled face between the two edges (`BRepFill.Face_s`, reversing one edge when their ends cross), then sews at `CLEAN_TOL_MM`. Geometry on either side does not move.
  - `@dataclass Hole: edges: list[TopoDS_Edge]; centre_mm: tuple; lines_mm: list[list[tuple]]`
  - `find_holes(shape, gaps: list[Gap]) -> list[Hole]`: free edges in no gap, grouped into closed loops (`ShapeAnalysis_FreeBounds`). Edges that form no closed loop are not holes.
  - `fill(shape, hole: Hole) -> TopoDS_Shape | None`: `BRepOffsetAPI_MakeFilling` with the loop's edges as C0 constraints, then sew at `CLEAN_TOL_MM`; `None` when filling fails or leaves free edges.

- [ ] **Step 1: Write the failing tests**

```python
def test_a_5mm_gap_is_found_and_bridged():
    shape, _ = sew_stepped(faces_of_box(100, 100, 100, move=("top", gp_Vec(0, 0, 5))), 0.5)
    gaps = find_gaps(shape)
    assert len(gaps) == 4 and all(g.size_mm == pytest.approx(5, abs=0.01) for g in gaps)
    for g in gaps:
        shape = bridge(shape, g)  # edges of later gaps may change: re-find after each in the pipeline
    assert not free_edges(shape)
    solids, _ = to_solids(shape)
    assert volume(solids[0]) == pytest.approx(100 * 100 * 105, rel=1e-3)

def test_a_missing_face_is_a_hole_and_is_filled():
    shape = faces_of_box(100, 100, 100, drop="top")
    holes = find_holes(shape, find_gaps(shape))
    assert len(holes) == 1
    filled = fill(shape, holes[0])
    assert filled is not None and not free_edges(filled)
```

`faces_of_box` gains `drop: str | None` to leave one face out. If bridging gap by gap invalidates the edges of the remaining gaps, the test (and Task 4's pipeline) re-runs `find_gaps` after each bridge and matches by centre within 0.01 mm.

- [ ] **Step 2: Run to verify they fail** (`ImportError: find_gaps`)
- [ ] **Step 3: Implement `Gap`, `find_gaps`, `bridge`, `Hole`, `find_holes`, `fill`**
- [ ] **Step 4: Run** `cd engine && uv run pytest -q tests/test_bodyrepair.py`, expect 6 passed
- [ ] **Step 5: Commit** (`Body repair: gap pairing, bridging, hole filling`)

---

### Task 3: Item ids and saved decisions

**Files:**
- Modify: `engine/src/aeroengine/cad/bodyrepair.py`
- Test: `engine/tests/test_bodyrepair.py`

**Interfaces:**
- Produces:
  - `item_id(kind: str, part: str, centre_mm) -> str`: `f"{kind}:{part}:{x:.1f},{y:.1f},{z:.1f}"`, deterministic for the same input file.
  - `match_decision(kind: str, part: str, centre_mm, saved: list[dict], within_mm: float = 3.0) -> str | None`: the `decision` (`"accept"` / `"skip"`) of the nearest saved entry with the same `kind` and `part` whose `centre_mm` is within `within_mm`; else `None`.
  - Decisions file format (written by the app, read by the engine): `{"version": 1, "decisions": [{"kind", "part", "centre_mm": [x, y, z], "size_mm", "decision"}]}`.

- [ ] **Step 1: Write the failing tests**

```python
SAVED = [{"kind": "gap", "part": "Floor", "centre_mm": [100, 0, 5], "size_mm": 2.0, "decision": "skip"}]

def test_a_decision_matches_within_3mm():
    assert match_decision("gap", "Floor", (101.5, 1.0, 5.0), SAVED) == "skip"

def test_a_moved_or_renamed_part_does_not_match():
    assert match_decision("gap", "Floor", (104.0, 0, 5), SAVED) is None
    assert match_decision("gap", "Diffuser", (100, 0, 5), SAVED) is None
    assert match_decision("hole", "Floor", (100, 0, 5), SAVED) is None

def test_item_ids_are_stable():
    assert item_id("gap", "Floor", (1.04, 2, 3)) == item_id("gap", "Floor", (1.01, 2, 3)) == "gap:Floor:1.0,2.0,3.0"
```

- [ ] **Step 2: Run to verify they fail**
- [ ] **Step 3: Implement `item_id` and `match_decision`**
- [ ] **Step 4: Run, expect 9 passed**
- [ ] **Step 5: Commit** (`Body repair: item ids and saved decisions`)

---

### Task 4: Pipeline and the `cad-repair-body` command

**Files:**
- Modify: `engine/src/aeroengine/cad/bodyrepair.py`
- Modify: `engine/src/aeroengine/commands/cadcheck.py` (new command after `cad_repair`)
- Test: `engine/tests/test_bodyrepair.py`

**Interfaces:**
- Consumes: everything from Tasks 1 to 3; `_read`, `_parts`, `_instances`, `_entry` from `brepcheck.py` / `tessellate.py`; `STEPCAFControl_Writer` as in `repair_brep`.
- Produces:
  - `repair_body(path: Path, out: Path, limit_mm: float = 0.5, accept: set[str] | None = None, decisions: Path | None = None, progress=lambda pct, msg: None) -> dict`
  - Command `cad-repair-body`, params: `path` (required), `limit_mm` (default 0.5), `accept` (list of ids; absent = plan job), `decisions` (path, optional). Returns `repair_body`'s dict. Output file in the workdir: `f"{path.stem}_repaired.step"`.
  - Result dict (the app decodes exactly this):

```json
{"output": "car_repaired.step", "limit_mm": 0.5,
 "auto": {"parts": 12, "parts_sewn": 3, "small_edges_removed": 4, "small_faces_removed": 1, "max_sew_mm": 0.2},
 "items": [{"id": "gap:Floor:…", "kind": "gap", "part": "Floor", "size_mm": 2.4,
            "centre": [x, y, z], "centre_mm": [x, y, z], "lines": [[[x, y, z], …], …], "fix": "bridge",
            "decision": "accept" | "skip" | null}],
 "result": {"solids": 3, "open_shells": 0, "open_parts": [], "fused": true,
            "free_edges": 0, "nonmanifold_edges": 0, "valid": true, "closed": true}}
```

  `kind`: `gap` (fix `bridge`), `hole` (fix `fill`, or `open_shell` when `fill` returned `None` on the plan run), `wide_gap` (over 10 mm, fix `null`, no decision), `nonmanifold_edge` (after the fuse, fix `null`). `centre` and `lines` in metres, world placement; `centre_mm` in mm, part-local (what decisions are matched on); an item of a part placed N times carries the lines of every placement (centre: first placement). `decision`: what was applied on this run (`accept` ids, then saved decisions via `match_decision`); pending items are `null` and treated as skipped. `closed` = `free_edges == 0 and open_shells == 0 and nonmanifold_edges == 0 and valid`.

- [ ] **Step 1: Write the failing tests**

Fixtures: write STEP files with an XCAF doc, one named part per shape, as `cad/sample.py` does (helper `write_parts(path, {name: shape})`).

```python
def test_overlapping_boxes_fuse_into_one_closed_body(tmp_path): # two boxes overlapping 5 mm
    r = repair_body(step, tmp_path / "o.step")
    assert r["items"] == [] and r["result"]["solids"] == 1 and r["result"]["closed"]
    assert volume(read_back(tmp_path / "o.step")) == pytest.approx(union_volume, rel=1e-3)

def test_parts_10mm_apart_stay_separate(tmp_path):  # main plane and flap as two parts
    r = repair_body(step, out)
    assert r["items"] == [] and r["result"]["solids"] == 2

def test_plan_then_apply(tmp_path):  # one part: box faces with the top moved up 5 mm
    plan = repair_body(step, out)
    assert {i["kind"] for i in plan["items"]} == {"gap"} and not plan["result"]["closed"]
    assert all(i["decision"] is None for i in plan["items"]) and plan["result"]["open_shells"] == 1
    done = repair_body(step, out, accept={i["id"] for i in plan["items"]})
    assert done["result"]["closed"] and done["result"]["solids"] == 1

def test_saved_decisions_apply_on_a_new_run(tmp_path):  # decisions file accepting every plan item
    r = repair_body(step, out, decisions=saved)
    assert r["result"]["closed"] and all(i["decision"] == "accept" for i in r["items"])

def test_wide_gap_is_reported_and_left_open(tmp_path):  # top moved up 12 mm
    r = repair_body(step, out)
    assert {i["kind"] for i in r["items"]} == {"wide_gap"} and r["result"]["open_parts"] == ["Box"]
    assert out.exists()

def test_clean_file_needs_nothing(tmp_path):  # one solid box
    r = repair_body(step, out)
    assert r["items"] == [] and r["result"]["closed"] and r["auto"]["parts_sewn"] == 0

def test_a_part_placed_twice_has_one_item(tmp_path):  # the 5 mm-gap part placed at two locations
    r = repair_body(step, out)
    assert len([i for i in r["items"] if i["kind"] == "gap"]) == 4
    assert all(len(i["lines"]) == 4 for i in r["items"])  # two edges x two placements

def test_fuse_failure_still_writes(tmp_path, monkeypatch):
    monkeypatch.setattr(bodyrepair, "_fuse", lambda solids: None)
    r = repair_body(overlapping_step, out)
    assert r["result"]["fused"] is False and not r["result"]["closed"] and out.exists()

def test_sample_car_through_the_engine(engine, car_files, tmp_path):
    code, events, err = engine.run("cad-repair-body", {"params": {"path": str(car_files[0])}}, tmp_path / "w", timeout=180)
    assert code == 0, (events, err)
    r = json.loads((tmp_path / "w" / "result.json").read_text())["data"]
    assert r["result"]["closed"] and r["result"]["solids"] < 8  # wing elements overlap and fuse; wheels stay apart
    assert (tmp_path / "w" / r["output"]).exists()
```

`car_files` lives in `test_cadcheck.py`; move it to `conftest.py` so both files use it.

- [ ] **Step 2: Run to verify they fail**
- [ ] **Step 3: Implement `repair_body` and `_fuse(solids) -> TopoDS_Shape | None` in `bodyrepair.py`**

Order, per distinct part (`_parts`): `clean_part`, then `sew_stepped(limit_mm)`, then for each `find_gaps` result in band (limit, 10]: an item, bridged if accepted or matched `accept`; over 10: a `wide_gap` item. Then `find_holes`, each an item, filled if accepted. Then `to_solids`. Write the repaired part back with `tool.SetShape(label, …)`, then `tool.UpdateAssemblies()`. Placed solids and open shells come from the free shapes of the document (`GetShape_s` on each free label), which carry every placement. `_fuse`: `BRepAlgoAPI_Fuse` with the first solid as argument and the rest as tools, `SetFuzzyValue(0.01)`, `ShapeUpgrade_UnifySameDomain` on the result; `None` when `HasErrors()` or an exception. Verify with `free_edges`, `nonmanifold_edges`, `BRepCheck_Analyzer`. Write a fresh XCAF doc holding the fused body (named after the source stem) plus each open shell (named after its part). Progress: 0 to 60 across parts, 60 to 85 fuse, 85 to 100 verify and write.

- [ ] **Step 4: Run** `cd engine && uv run pytest -q tests/test_bodyrepair.py tests/test_cadcheck.py`, all pass
- [ ] **Step 5: Commit** (`cad-repair-body: STEP to one closed body, with a review queue`)

---

### Task 5: AeroBenchKit result type and viewer preview lines

**Files:**
- Create: `app/AeroBenchKit/Sources/AeroBenchKit/BodyRepairResult.swift`
- Modify: `app/AeroBenchKit/Sources/AeroBench3D/SceneKitViewer.swift` (beside `setMarkers`)
- Test: `app/AeroBenchKit/Tests/AeroBenchKitTests/BodyRepairResultTests.swift`

**Interfaces:**
- Produces:
  - `public struct BodyRepairResult: Decodable, Sendable` with `output: String`, `limitMM: Double`, `auto: Auto` (`parts`, `partsSewn`, `smallEdgesRemoved`, `smallFacesRemoved`: Int, `maxSewMM: Double?`), `items: [Item]`, `result: Outcome`; `public static func decode(resultFile: Data) throws -> BodyRepairResult` (same envelope as `GeometryReport.decode`).
  - `public struct Item: Decodable, Sendable, Identifiable` with `id`, `kind`, `part: String`, `sizeMM: Double?`, `centre: [Double]`, `centreMM: [Double]`, `lines: [[[Double]]]`, `fix: String?`, `decision: String?`; `public var reviewable: Bool { kind == "gap" || kind == "hole" }`.
  - `public struct Outcome: Decodable, Sendable` with `solids`, `openShells`, `freeEdges`, `nonmanifoldEdges`: Int, `openParts: [String]`, `fused`, `valid`, `closed`: Bool.
  - Snake-case keys via `CodingKeys` as `GeometryReport` does.
  - `SceneKitViewer.setPreviewLines(_ polylines: [[SIMD3<Double>]])`: constant-lit `.line` geometry in amber, not depth-tested, on its own root node; an empty array clears it.

- [ ] **Step 1: Write the failing test** `testDecodesAPlanResult`: a JSON literal shaped like Task 4's result with one `gap` (decision null) and one `wide_gap`; assert `items.count == 2`, `items[0].reviewable`, `!items[1].reviewable`, `items[0].lines[0].count`, `result.closed == false`, `auto.maxSewMM == 0.2`.
- [ ] **Step 2: Run** `cd app/AeroBenchKit && swift test --filter BodyRepairResultTests`, expect a compile failure
- [ ] **Step 3: Implement `BodyRepairResult` and `setPreviewLines`**
- [ ] **Step 4: Run the filter again, expect pass**
- [ ] **Step 5: Commit** (`AeroBenchKit: body repair result, viewer preview lines`)

---

### Task 6: CAD Viewer: plan, review, apply

**Files:**
- Modify: `app/AeroBench/CADViewerModel.swift`
- Modify: `app/AeroBench/AppState+CAD.swift`
- Modify: `app/AeroBench/Views/CADViewerView.swift` (`GeometryCheckSection`, plus a new `BodyRepairSection` view in the same file)
- Modify: `docs/DECISIONS.md` (one entry at the end)

**Interfaces:**
- Consumes: `BodyRepairResult`, `setPreviewLines` (Task 5); command `cad-repair-body` (Task 4).
- Produces (in `CADViewerModel`):
  - `var bodyLimitMM = 0.5`, `var bodyJob: JobItem?`, `private(set) var bodyPlan: BodyRepairResult?`, `var bodyDecisions: [String: Bool]` (id → accepted), `var selectedBodyItem: String? { didSet { update preview lines and frame the viewer on the item's lines } }`, `func setBodyPlan(_:)` (seeds `bodyDecisions` from each item's non-null `decision`; clears selection and preview lines). `setReport` and loading a new file clear the plan.
- Produces (in `AppState`): `func planBodyRepair()`, `func applyBodyRepair()`, and the save-panel-then-open code in `repairGeometry()` pulled out into `private func saveRepaired(_ item: JobItem, name: String, beside source: URL)` that both use.

Behaviour:
- `planBodyRepair()`: STEP / STP only; submits `cad-repair-body` with `path`, `limit_mm`, and `decisions` when `<stem>.repair.json` exists beside the source. On success `setBodyPlan`. If no item is reviewable and pending, the plan job's output is final: call `saveRepaired` at once.
- `applyBodyRepair()`: writes `<stem>.repair.json` beside the source (every reviewable item with a decision: kind, part, `centre_mm` from the item's `centreMM`, size, decision), submits `cad-repair-body` with `accept` = accepted ids, then `saveRepaired`. A write failure for the decisions file is shown with `show(_:_:)` and does not block the apply.
- `BodyRepairSection` (inside the Geometry check section, STEP / STP only): a "Repair to One Body…" button with progress as for the other jobs; a "Fix gaps up to" field in mm bound to `bodyLimitMM` (clamped 0.01 to 10); after a plan: a summary line from `auto` and `result`; the queue as a list (kind, part, size in mm, two decimals) where selecting a row sets `selectedBodyItem` and each reviewable row has an Accept / Skip control; "Accept All"; reports (`wide_gap`, `nonmanifold_edge`) listed without controls; "Apply" (disabled while a job runs). After apply: the summary says "One closed body" only when `result.closed`, else names `openParts` and the counts.
- DECISIONS.md entry: the three gap bands, part-only pairing, the 0.01 mm cleanup and fuse tolerance, bridging with a ruled face rather than wider sewing, and the spec and plan paths.

- [ ] **Step 1: Implement the model state and `AppState` actions**
- [ ] **Step 2: Implement `BodyRepairSection` and wire it into `GeometryCheckSection`**
- [ ] **Step 3: Build** `cd app && xcodebuild -project AeroBench.xcodeproj -scheme AeroBench -configuration Debug -destination 'platform=macOS' build`, expect `** BUILD SUCCEEDED **`
- [ ] **Step 4: Run the app on the sample car STEP** (`build_sample_car`), run "Repair to One Body…", confirm an empty queue saves straight away and the result opens; then on a fixture with a 5 mm gap: the queue shows 4 gaps, selecting one draws amber lines and frames it, Accept All plus Apply opens a closed body, and `<stem>.repair.json` exists beside the source.
- [ ] **Step 5: Add the DECISIONS.md entry and commit** (`CAD Viewer: repair STEP to one body, with a review queue`)
