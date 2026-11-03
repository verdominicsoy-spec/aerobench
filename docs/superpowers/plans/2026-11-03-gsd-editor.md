# Part Editor (GSD-style) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An Edit mode in the CAD Viewer that edits one solid STEP part with points, splines, planes, extrude, tangent fill, Add, fillet, chamfer and flat push/pull, kept as an editable feature list and saved as STEP.

**Architecture:** The app owns the feature list (plain JSON). Every change sends the whole list to the warm engine (`serve`, new handler `part-edit`), which rebuilds from the first changed feature using a per-prefix cache, resolves references through OpenCascade's operation history, and returns a GLB plus face ranges, edge polylines and a status per feature. A job command `part-save` writes the result. Engine code lives in a new package `engine/src/aeroengine/cad/edit/`.

**Tech Stack:** Python 3 + `cadquery-ocp`, pytest; Swift, SwiftUI, SceneKit, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-03-gsd-editor-design.md`

## Global Constraints

- One solid part from a STEP, in the part's **own coordinate frame**; XY, YZ, ZX are the part's planes; Save writes the part alone in that frame.
- STEP and OCP in mm; everything sent to the app (GLB, polylines, points) in metres (`tessellate.MM`).
- References never guessed: one that maps to zero or several shapes is `"lost"` on the feature that uses it.
- A failed feature stops the rebuild; the reply carries the result up to the last good feature.
- Fill: G1 (tangent) to the chosen face along part edges, C0 along splines.
- Push/pull: flat faces only; curved faces refused with a message.
- Feature list saved as `<stem>.features.json` beside the STEP, with the STEP's fingerprint; a different fingerprint marks every part reference lost.
- Previews debounced; a newer request replaces a queued one (`WarmEngine` runs one request at a time, 60 s timeout).
- No new dependencies. UI follows the CAD Viewer's existing style (sage37).

## Review Focus

1. A fillet radius too large for the edge: the feature reports OpenCascade's failure, later features are not built, the view shows the part before it. (Task 3)
2. An earlier edit removes an edge a later fillet used: the fillet says reference lost; it never moves to a neighbouring edge. (Task 3)
3. The STEP was re-exported since the list was saved: every part reference is lost, features made only of other features still build. (Task 3)
4. A fill whose boundary does not close: failed with "the boundary is open at …", no crash. (Task 2)
5. Edits arriving faster than rebuilds: only the newest list is built, no queue builds up. (Task 5)

## Data shapes (shared by Tasks 1 to 8)

Feature: `{"id": "f3", "kind": "<kind>", "refs": [Ref, …], "values": {"name": number}}`.
Ref: `{"src": "part" | "<feature id>" | "std", "kind": "face" | "edge" | "point" | "curve" | "surface" | "plane", "i": int, "name": "XY"?, "tangent": Ref?}` (`i`: index in that source's output of that kind; `name` only for `std` planes; `tangent` only on fill boundary refs).

| kind | refs | values |
| --- | --- | --- |
| `point` | one face or edge | `t` (edge, 0 to 1) or `u`, `v` (face, 0 to 1 of its parameter range) |
| `spline` | 2+ point refs, in order | none |
| `plane` | reference plane (`std` XY/YZ/ZX or a flat face), then a point | none |
| `extrude` | a curve (spline or part edge), then a plane | `distance` (mm), `symmetric` (0 or 1) |
| `fill` | boundary curves and edges in loop order; part edges carry `tangent` | none |
| `add` | 1+ surface refs (extrude, fill outputs) | none |
| `fillet` | 1+ part edges | `radius` (mm) |
| `chamfer` | 1+ part edges | `distance` (mm) |
| `pushpull` | one flat part face | `distance` (mm, + outward) |

Reply of `part-edit`: `{"parts": [names], "part": name, "fingerprint": str, "part_valid": bool, "glb": path, "faces": [{"ref": Ref, "start": int, "count": int}], "edges": [{"ref": Ref, "points": [[x,y,z]…]}], "points": [{"id": str, "position": [x,y,z]}], "planes": [{"id": str, "origin": [x,y,z], "normal": [x,y,z]}], "features": [{"id": str, "status": "ok" | "failed" | "lost" | "skipped", "message": str?}], "valid": bool, "closed": bool}`. `faces[k]` covers triangles `start ..< start+count` of the GLB's one mesh.

---

### Task 1: Part loading and references

**Files:** Create `engine/src/aeroengine/cad/edit/__init__.py`, `engine/src/aeroengine/cad/edit/refs.py`; Test `engine/tests/test_part_edit.py`

**Interfaces:**
- Produces:
  - `load_part(path: Path, part: str | None) -> tuple[TopoDS_Shape, list[str], str]`: the named part in its own frame (`XCAFDoc_ShapeTool.GetShape_s` on the part label, via `brepcheck._parts`), all part names, and the fingerprint `f"{size}:{mtime_ns}:{sha256[:16]}"`. One part and `part=None`: that part. Several and `None`: `EngineError("pick a part", ", ".join(names))`. Cached on (path, size, mtime_ns).
  - `class Topology`: built from a shape; `faces: list`, `edges: list` in `TopExp.MapShapes_s` order (deterministic for the same shape); `index(sub) -> int | None` by `IsSame`.
  - `class History`: starts as identity over a base shape. `apply(op: BRepBuilderAPI_MakeShape, before: TopoDS_Shape)` records one operation. `forward(sub) -> list[TopoDS_Shape]`: `[]` if deleted, the `Modified` pieces if any, else `[sub]` when `sub` is still in the result.
  - `resolve(ref: dict, ctx) -> TopoDS_Shape`: raises `RefLost(ref)` unless exactly one shape. `ctx` (Task 3) holds each source's `Topology` and the `History` since that source was made.

- [ ] **Step 1: Failing tests**

```python
def test_a_single_part_loads_in_its_own_frame(tmp_path):  # one box placed at x=500 in an assembly
    shape, names, fp = load_part(step, None)
    assert names == ["Box"] and bounds(shape)[0][0] == pytest.approx(0)

def test_several_parts_need_a_name(tmp_path):
    with pytest.raises(EngineError, match="pick a part"):
        load_part(two_part_step, None)

def test_topology_order_is_stable():
    a, b = Topology(box()), Topology(box())
    assert len(a.faces) == 6 and len(a.edges) == 12
    assert [centre(f) for f in a.faces] == [centre(f) for f in b.faces]

def test_an_edge_follows_a_fillet_and_a_filleted_edge_is_gone():
    # fillet edge 0 of a box: edge 0 is deleted, an edge on the far side keeps one piece
    ...
    assert hist.forward(t.edges[0]) == [] and len(hist.forward(t.edges[far])) == 1
```

`write_parts` from `tests/test_bodyrepair.py` moves to `tests/conftest.py` as a fixture helper so both files use it.

- [ ] **Step 2: Run** `cd engine && uv run pytest -q tests/test_part_edit.py`, expect FAIL (`ModuleNotFoundError`)
- [ ] **Step 3: Implement `refs.py`**
- [ ] **Step 4: Run, expect 4 passed**
- [ ] **Step 5: Commit** (`Part editor: part loading and references`)

---

### Task 2: Geometry operations

**Files:** Create `engine/src/aeroengine/cad/edit/ops.py`; Test `engine/tests/test_part_edit.py`

**Interfaces:**
- Produces (all in mm, OCP shapes in, OCP shapes out; operations that change a solid also return the `BRepBuilderAPI_MakeShape` for `History.apply`; failures raise `EngineError` with a plain message):
  - `point_on_edge(edge, t) -> gp_Pnt`, `point_on_face(face, u, v) -> gp_Pnt` (normalised parameters via `BRepAdaptor_*`).
  - `spline(points: list[gp_Pnt]) -> TopoDS_Edge` (`GeomAPI_PointsToBSpline`; 2 points: a line).
  - `plane_through(reference: gp_Pln, point: gp_Pnt) -> gp_Pln`; `face_plane(face) -> gp_Pln` (raises "pick a flat face" when not planar); `STD = {"XY": …, "YZ": …, "ZX": …}`.
  - `extrude(curve: TopoDS_Edge, plane: gp_Pln, distance: float, symmetric: bool) -> TopoDS_Face` (`BRepPrimAPI_MakePrism` along the normal; symmetric: start at −distance, length 2×distance).
  - `fill(boundary: list[tuple[TopoDS_Edge, TopoDS_Face | None]]) -> TopoDS_Face`: `BRepOffsetAPI_MakeFilling`, `Add(edge, face, GeomAbs_G1)` when a face is given, else `Add(edge, GeomAbs_C0)`. Before building, check the loop closes (consecutive ends within 0.01 mm); raise "the boundary is open at x, y, z mm".
  - `add(solid, surfaces: list) -> (TopoDS_Shape, maker)`: `bodyrepair.sew_stepped(compound, 0.5)` then `bodyrepair.to_solids`; open shells left → raise "the surfaces do not close a volume" with the free-edge centres; else fuse onto `solid` (`BRepAlgoAPI_Fuse`, fuzzy 0.01).
  - `fillet(solid, edges, radius) -> (shape, maker)` (`BRepFilletAPI_MakeFillet`); `chamfer(solid, edges, distance) -> (shape, maker)` (`BRepFilletAPI_MakeChamfer`). Both already carry on along edges that meet tangentially, which is the spec's chain pick; no separate chain step.
  - `pushpull(solid, face, distance) -> (shape, maker)`: flat faces only (else "push/pull works on flat faces"); prism of the face along its outward normal by `abs(distance)`, fused when positive, cut when negative.

- [ ] **Step 1: Failing tests** (box 100 mm unless stated)

```python
def test_point_on_edge_midway(): assert point_on_edge(edge_x0, 0.5) is at (50, 0, 0)
def test_spline_passes_through_its_points(): every input point lies on the edge within 1e-6
def test_plane_through_a_point_is_parallel(): plane_through(STD["XY"], gp_Pnt(0, 0, 30)) has origin z 30, normal (0, 0, 1)
def test_extrude_symmetric_area(): line 100 mm, XY, distance 10, symmetric → face area 2000, z from -10 to 10
def test_fill_is_tangent_to_the_part():
    # a box with its top face removed; fill the top rim with each side face as G1 support
    face = fill([(e, side_face_of(e)) for e in rim])
    assert max angle between fill normal and side-face continuation along the rim < 1 degree
def test_fill_with_an_open_boundary_says_where(): pytest.raises(EngineError, match="boundary is open at")
def test_add_fuses_a_closed_extension(): box + extrusions forming a 100x100x20 cap on top → one solid, volume 1.2e6
def test_add_with_open_surfaces_changes_nothing(): pytest.raises(EngineError, match="do not close a volume")
def test_fillet_volume(): fillet one edge r=10 → volume 1e6 - (1 - pi/4) * 100 * 100 (rel 1e-3)
def test_fillet_too_large_raises(): r=80 on a 100 box edge → EngineError
def test_chamfer_volume(): chamfer one edge d=10 → volume 1e6 - 0.5 * 100 * 100
def test_pushpull_flat_face(): top face +10 → volume 1.1e6; -10 → 0.9e6
def test_pushpull_curved_face_refused(): cylinder side face → EngineError("flat faces")
```

- [ ] **Step 2: Run, expect FAIL** (`ImportError`)
- [ ] **Step 3: Implement `ops.py`**
- [ ] **Step 4: Run** `uv run pytest -q tests/test_part_edit.py`, all pass
- [ ] **Step 5: Commit** (`Part editor: geometry operations`)

---

### Task 3: The rebuild

**Files:** Create `engine/src/aeroengine/cad/edit/build.py`; Test `engine/tests/test_part_edit.py`

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces: `build(path: Path, part: str | None, features: list[dict], fingerprint: str | None, out_dir: Path, preset: str = "medium") -> dict` returning the `part-edit` reply (Data shapes above), and `final_shape(path, part, features, fingerprint) -> TopoDS_Shape` for saving.

Behaviour:
- The current solid starts as the imported part. Features run in order. `point`, `spline`, `plane`, `extrude`, `fill` make side geometry (kept per feature id, with their own `Topology`); `add`, `fillet`, `chamfer`, `pushpull` change the solid and are recorded in `History`.
- Refs resolve through `resolve`; `RefLost` gives the feature status `lost` ("pick again"); `EngineError` gives `failed` with its message. Either stops the rebuild: later features are `skipped`.
- `fingerprint` given and different from the file's: every ref with `src == "part"` is lost.
- Cache: module-level dict keyed by `(path, size, mtime_ns, part, json.dumps(features[:k+1], sort_keys=True))` holding the state after feature k; keep the 64 most recent entries.
- Output: tessellate the current solid with `tessellate._mesh_shape`'s per-face loop (extend it to return each face's triangle range), write one-mesh GLB to `out_dir / f"{uuid}.glb"`, and for each face and edge of the result give its ref: imported faces and edges whose `History.forward` is a single shape map back to `{"src": "part", …}`; faces and edges the operations generated get `{"src": <feature id>, "i": k}` (k: order within that feature's `Generated` output). Side geometry (spline edges, extruded and filled faces) is added to `edges` / `faces` with its own feature refs. `valid`: `BRepCheck_Analyzer`; `closed`: no `bodyrepair.free_edges`.

- [ ] **Step 1: Failing tests**

```python
def test_a_fillet_builds_and_maps_faces(tmp_path):
    r = build(box_step, None, [fillet("f1", edge 0, 10)], None, tmp_path)
    assert r["features"] == [{"id": "f1", "status": "ok"}] and r["valid"] and r["closed"]
    assert sum(f["count"] for f in r["faces"]) == triangles in the GLB
    assert any(f["ref"]["src"] == "f1" for f in r["faces"])  # the new fillet face
    assert sum(f["ref"]["src"] == "part" for f in r["faces"]) == 6  # the six box faces, trimmed

def test_a_failed_feature_stops_the_rebuild(tmp_path):   # Review Focus 1
    r = build(box_step, None, [fillet("f1", e0, 80), chamfer("f2", e5, 5)], None, tmp_path)
    assert [f["status"] for f in r["features"]] == ["failed", "skipped"] and r["closed"]

def test_a_vanished_reference_is_lost_not_moved(tmp_path):  # Review Focus 2
    r = build(box_step, None, [fillet("f1", e0, 10), chamfer("f2", e0, 5)], None, tmp_path)
    assert r["features"][1]["status"] == "lost"

def test_a_changed_file_loses_part_references(tmp_path):  # Review Focus 3
    r = build(box_step, None, [fillet("f1", e0, 10)], "0:0:old", tmp_path)
    assert r["features"][0]["status"] == "lost"

def test_the_cache_reuses_the_prefix(tmp_path, monkeypatch):
    build(...[f1, f2]...); count calls of ops.fillet; build(...[f1, f2 with a new value]...)
    assert ops.fillet called once more, not twice

def test_endplate_edit_end_to_end(tmp_path):
    # endplate-like plate 300 x 8 x 200: points on the top edge, spline, extrude 20 along a plane
    # parallel to XY, fill, add; then fillet the leading edge r=3
    r = build(...)
    assert all(f["status"] == "ok" for f in r["features"]) and r["valid"] and r["closed"]
```

(Feature builders `fillet(id, ref, r)` etc. are small dict helpers in the test file.)

- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement `build.py`; extend `tessellate._mesh_shape` with an optional `ranges: list | None` out-parameter, keeping its return value for existing callers**
- [ ] **Step 4: Run** `uv run pytest -q tests/test_part_edit.py tests/test_cad.py`, all pass
- [ ] **Step 5: Commit** (`Part editor: rebuild with references and cache`)

---

### Task 4: Engine entry points

**Files:** Modify `engine/src/aeroengine/serve.py`, `engine/src/aeroengine/commands/cadcheck.py`; Test `engine/tests/test_part_edit.py`

**Interfaces:**
- Produces:
  - serve handler `"part-edit"`: params `{path, part?, features, fingerprint?, out_dir?}` → `build(...)`. `out_dir` defaults to a per-process temp folder; GLBs older than the last 8 are deleted.
  - job command `"part-save"`: params `{path, part?, features, fingerprint?}` → writes `f"{part}_edited.step"` in the workdir (one named part, own frame, via `STEPCAFControl_Writer` as `bodyrepair._write` does); returns `{"output": name, "valid": bool, "closed": bool}`. Any feature not `ok` → `EngineError("fix or remove '<id>' before saving")`.

- [ ] **Step 1: Failing tests**: `test_serve_answers_part_edit` (drive `serve()` with a `StringIO` of one request and `warm=False`; reply has `features` and an existing `glb`); `test_part_save_writes_the_edited_part` (engine fixture runs `part-save` with one fillet; the STEP reads back as one solid with the expected volume); `test_part_save_refuses_a_failed_feature`.
- [ ] **Step 2: Run, expect FAIL**
- [ ] **Step 3: Implement both**
- [ ] **Step 4: Run** `uv run pytest -q`, all pass
- [ ] **Step 5: Commit** (`Part editor: serve handler and save command`)

---

### Task 5: AeroBenchKit types, picking maths, latest-only runner

**Files:** Create `app/AeroBenchKit/Sources/AeroBenchKit/PartEdit.swift`, `app/AeroBenchKit/Sources/AeroBenchKit/LatestOnly.swift`; Modify `app/AeroBenchKit/Sources/AeroBench3D/SceneKitViewer.swift`; Test `app/AeroBenchKit/Tests/AeroBenchKitTests/PartEditTests.swift`

**Interfaces:**
- Produces:
  - `public struct EditRef: Codable, Hashable, Sendable` (`src`, `kind`, `i: Int?`, `name: String?`, `tangent: Box<EditRef>?` encoded as a nested object; or an `indirect enum` wrapper, the builder's choice).
  - `public struct EditFeature: Codable, Identifiable, Sendable` (`id`, `kind: Kind` enum with the nine kinds, `refs: [EditRef]`, `values: [String: Double]`).
  - `public struct FeatureFile: Codable` (`version: Int`, `part: String?`, `fingerprint: String?`, `features: [EditFeature]`) with `static func url(beside step: URL) -> URL` (`<stem>.features.json`), `load(beside:) throws -> FeatureFile?`, `save(beside:) throws`.
  - `public struct PartEditReply: Decodable, Sendable` matching the reply shape; `static func decode(_ data: Data) throws -> PartEditReply` (the warm engine's `{"data": …}` envelope).
  - `public actor LatestOnly<Input: Sendable, Output: Sendable>`: `init(run: @escaping @Sendable (Input) async throws -> Output)`, `func submit(_ input: Input) async -> Result<Output, Error>?`: runs at most one at a time; a submit while running replaces any waiting input; superseded submits return `nil`.
  - `public enum EdgePick { static func nearest(_ polylines: [[SIMD2<Double>]], to p: SIMD2<Double>, within: Double) -> Int? }`: index of the polyline nearest `p` in screen points, nil beyond `within`.
  - `SceneKitViewer`: `public var onHover: ((PickResult?) -> Void)?`; `public func projectToScreen(_ p: SIMD3<Double>) -> SIMD2<Double>`; `public func setEditOverlay(edges: [[SIMD3<Double>]], highlighted: Set<Int>, selected: Set<Int>, points: [SIMD3<Double>])`; `PickResult` gains `faceIndex: Int?` (the hit triangle).

- [ ] **Step 1: Failing tests**: `testFeatureFileRoundTrips` (a fill with a `tangent` ref survives encode then decode); `testDecodesAPartEditReply`; `testNearestEdgeWithinTolerance` (two polylines, a point 3 pt from the second, `within: 6` → 1; `within: 2` → nil); `testLatestOnlyDropsSupersededInputs` (a run that sleeps 50 ms; submit 1, 2, 3 at once → 1 and 3 run, 2 returns nil).
- [ ] **Step 2: Run** `cd app/AeroBenchKit && swift test --filter PartEditTests`, expect compile failure
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run, expect pass; then `swift test`, all pass**
- [ ] **Step 5: Commit** (`AeroBenchKit: part edit types, edge picking, latest-only runner`)

---

### Task 6: Edit model and engine wiring

**Files:** Create `app/AeroBench/PartEditModel.swift`, `app/AeroBench/AppState+PartEdit.swift`

**Interfaces:**
- Consumes: Task 5 types; `WarmEngine` (one instance for the part editor, created like `lab.warmEngine` in `AppState+Wing.swift`).
- Produces (`@MainActor @Observable final class PartEditModel`):
  - `var on = false`, `private(set) var file: FeatureFile`, `var tool: Tool?` (the nine kinds), `var draft: EditFeature?` (the feature being made or edited), `var selectedFeature: String?`, `private(set) var reply: PartEditReply?`, `var status: String?`.
  - `func set(_ features: [EditFeature], actionName: String, undo: UndoManager?)`: registers the inverse, saves the file beside the STEP (errors shown, not fatal), triggers a rebuild.
  - `func rebuild()`: sends `file.features + [draft]` (the draft as a preview) through `LatestOnly` to `part-edit`; applies the reply: loads the GLB into `cad.viewer` (via `ModelLoader.load(url, units: .metre)`), updates the overlay, and when `reply.fingerprint != file.fingerprint` and the file had one, sets `status` to "The STEP changed since these edits; pick the lost references again".
  - `func pick(_ result: PickResult)`: turns a click into an `EditRef` (face from `faceIndex` via `reply.faces` ranges; edge via `EdgePick.nearest` on projected `reply.edges` within 6 pt, preferred over the face when found) and adds it to `draft`. For a fill boundary edge, the face under the pointer becomes its `tangent`.
  - `func hover(_ result: PickResult?)`: resolves like `pick` and highlights that edge or face in the overlay.
  - `func apply()`, `func cancel()`, `func remove(_ id: String)`, `func edit(_ id: String)`.
- AppState: `func enterPartEdit()`: checks `cad.isStep`; loads `FeatureFile` beside it; first rebuild; if `reply.parts.count > 1` and no part chosen, `status` asks to pick a part; if `!reply.partValid`, offer "Repair first", which calls `planBodyRepair()`. `func savePartEdit()`: runs `part-save` as a job and reuses `saveRepaired(_:name:beside:)` (change it from `private` to internal).

- [ ] **Step 1: Implement the model and AppState actions**
- [ ] **Step 2: Build** `cd app && xcodebuild -project AeroBench.xcodeproj -scheme AeroBench -configuration Debug -destination 'platform=macOS' build`, expect `** BUILD SUCCEEDED **`
- [ ] **Step 3: Commit** (`Part editor: edit model and engine wiring`)

---

### Task 7: Edit mode UI

**Files:** Create `app/AeroBench/Views/PartEditView.swift`; Modify `app/AeroBench/Views/CADViewerView.swift`; Modify `docs/DECISIONS.md`

**Interfaces:**
- Consumes: `PartEditModel` (Task 6).
- Produces:
  - An "Edit Part" toggle in the CAD Viewer toolbar for STEP files (also in the menu bar with ⌘E). On: the sidebar shows `PartEditView` in place of the inspector sections.
  - `PartEditView`: a part picker when the file has several parts; a tool row (Point, Spline, Plane, Extrude, Fill, Add, Fillet, Chamfer, Push/Pull) as icon buttons with accessibility labels; the active tool's panel listing what it still needs ("Pick 2 or more points", "Pick a plane"), its values as number fields in mm (and Symmetric for extrude, a Flip control on each fill tangent), Apply and Cancel; the feature list (kind, key value, status capsule: `failed` and `lost` in clay with the message, `skipped` grey), selecting a row loads it into the panel, right-click offers Edit and Remove; Save Part…; `status` line.
  - Every list change goes through `set(_:actionName:undo:)` with names like "Fillet 3 mm", so Edit ▸ Undo reads "Undo Fillet 3 mm".
  - DECISIONS.md entry: the feature list in the app rebuilt by the warm engine, references through history and never guessed, the fingerprint rule, flat-only push/pull, part frame for saving, and the spec and plan paths.

- [ ] **Step 1: Implement the view and wire it in**
- [ ] **Step 2: Build, expect `** BUILD SUCCEEDED **`**
- [ ] **Step 3: Run the app on the endplate fixture STEP (written by Task 3's test helper to a scratch folder): fillet an edge, edit its radius, undo, add a spline-extrude-fill-add extension, save; reopen the saved STEP in the CAD Viewer**
- [ ] **Step 4: Add the DECISIONS.md entry and commit** (`CAD Viewer: Edit Part mode`)
