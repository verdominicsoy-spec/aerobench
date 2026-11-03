# Part editor (GSD-style) in the CAD Viewer

Date: 2026-11-03. Status: design, awaiting approval.

## Intent

The user edits existing parts in CATIA's Generative Shape Design (GSD) and
wants the edits they make most often inside AeroBench, on the STEP files they
already bring in. They do not model parts from scratch here. The first real
edit is a fillet on an endplate's own edge; next come the surface edits of
GSD: points clicked on the part, splines through them, planes, surfaces
extruded from a spline, and fills that join the part smoothly.

## Goals

- Edit **one solid part** imported from STEP, inside the CAD Viewer, in an
  **Edit mode**.
- Features, v1:
  - **Point**: clicked on an edge or a face of the part (or of an earlier
    feature's surface). Stays attached: "this far along this edge" or "at
    this spot on this face".
  - **Spline**: through an ordered run of points.
  - **Plane**: parallel to a reference plane, through a point. The
    reference is one of the standard planes (XY, YZ, ZX) or a flat face
    the user clicks. (The user's own way of making planes in CATIA.)
  - **Extrude**: a spline or edge swept along the normal of a plane, by a
    typed distance, optionally both ways (symmetric).
  - **Fill**: a surface inside a closed boundary of clicked edges and
    splines. Along the part's own edges it is **tangent** to the part's
    faces (the user's choice); along splines it only has to meet them.
    Each edge of a solid has a face on each side; the fill stays tangent to
    the face under the pointer when the edge was clicked (builder's call),
    and the tool lets the user flip it.
  - **Add**: the user's way of using new surfaces in CATIA is adding
    material. Picked surfaces (extrudes, fills) are sewn into a closed
    volume of their own, with the STEP repair's sewing and closing code,
    then fused onto the part. The volume may overlap the part; the fuse
    removes the overlap. If the picked surfaces do not close, Add reports
    where the open edges are and changes nothing.
  - **Fillet**: constant radius on clicked edges of the solid.
  - **Chamfer**: on clicked edges, by a distance.
  - **Push/pull face**: moves a clicked **flat** face of the solid along
    its normal by a distance (thicken an endplate, lengthen a lip). Curved
    faces are refused with a message in v1; moving one means extending the
    faces around it, the riskiest operation here (builder's call).
- A **feature list** beside the viewer: the imported part first, then each
  feature with its values. Any value can be changed, any feature removed;
  everything after it rebuilds.
- **Undo** for every edit (the list is the state).
- **Save as STEP**, and the feature list saved beside it so the work
  survives quitting and engine crashes.

## Non-goals

- Modelling a part with no imported part under it.
- Sketches with constraints, variable-radius fillets, sweeps along paths,
  lofts, multi-section surfaces. (Later, if the user's edits need them.)
- Editing several parts at once, or features that span two parts (a
  fillet across the wing-to-endplate junction). The user's first edit is
  on the endplate itself.
- Surface (non-solid) imported parts: the user's endplates come as solids.
- Typed coordinates for points. The user clicks on the part.

## Anti-goals

- Changing the imported part anywhere a feature does not reach.
- A result that looks right but is not a valid solid, reported as fine.
- Losing the user's edits to a crash or a quit.
- A reference that silently moves to the wrong edge or face after an
  earlier feature changes. A reference that cannot be found again is
  reported on its feature ("reference lost, pick again"), never guessed.

## Approaches considered

- **A. Feature list in the app, rebuilt by a warm engine (chosen).** The
  app keeps the list as plain data. Every edit sends the whole list to the
  long-running engine (`WarmEngine`, `aeroengine serve`), which keeps the
  imported part and each feature's result in memory and rebuilds only
  from the first changed feature onward. It returns the mesh for the
  viewer, maps from triangles to faces and from lines to edges so clicks
  resolve to real topology, and a status per feature. Undo, edit and
  delete are list changes; saving the list makes crash recovery a rebuild.
  Cost: everything after an edited feature reruns, which is fast at the
  scale of one part.
- **B. Engine owns a live model, edits applied incrementally.** Rejected:
  undo history and state live in the engine, a crash loses the session,
  and editing an early feature replays the rest anyway.
- **C. CadQuery or FreeCAD's modeller.** Rejected: CadQuery is built for
  scripts, not picking; FreeCAD is a very large dependency; neither
  solves picking, which is the hard part.

The user chose A.

## How it works

### References

- The imported part never changes, so its faces and edges are referenced
  by their index in a fixed topological order of the imported shape.
- A sub-shape a feature creates is referenced by the feature's id and its
  index within that feature's own output.
- After a fillet, chamfer or push/pull, an imported face or edge may be
  trimmed or split. References follow it through OpenCascade's history of
  the operation (modified / generated shapes). When one reference maps to
  several pieces, or to none, the feature that used it reports "reference
  lost" with the pick shown, and the user picks again.
- Points store their host reference plus a normalised position (edge: 0
  to 1 along it; face: u, v in the face's parameter range).

### Engine

- A `serve` handler builds the part from `{path, part, features}`:
  reads the STEP (cached on path and modification time), takes the named
  part, applies the features in order, and caches each feature's result
  keyed on everything up to and including it, so an edit to feature N
  reuses 0..N-1.
- Fill: OpenCascade's filling (`BRepOffsetAPI_MakeFilling`) with the
  part's faces as G1 (tangent) constraints along the part's edges and C0
  along splines.
- Add: sew the picked surfaces with `bodyrepair.sew_stepped`, close them
  with `bodyrepair.to_solids`, then fuse the volume onto the part with the
  repair's `_fuse`.
- Each request returns: the tessellated result (a GLB written to a temp
  file, path returned), the triangle-to-face map, edge polylines with
  their references, point positions, and per feature `ok` /
  `failed: <message>` / `reference lost`. A failed feature stops the
  rebuild there; the result up to it is shown.
- Save: a job command writes the final shape as STEP.

### App

- **Edit mode** in the CAD Viewer for a STEP file: a toolbar row with
  Point, Spline, Plane, Extrude, Fill, Add, Fillet, Chamfer and
  Push/Pull, and the feature list.
- Picking: hovering highlights the edge or face under the pointer; a click
  picks it. Edges are picked by screen distance to their drawn line, faces
  through the triangle map. Fillet and chamfer can extend a pick along
  edges that meet tangentially (a chain).
- Each tool shows what it needs (picks, values), a preview as values
  change, then Apply or Cancel. Selecting a feature in the list loads its
  values for editing.
- Undo and redo through the window's undo manager, with action names
  ("Undo Fillet 3 mm").
- The feature list saves as `<stem>.features.json` beside the STEP after
  every change, and loads when that STEP is opened in Edit mode.
- Save writes `<part>_edited.step` beside the source through a save panel,
  as the repair does.
- The UI follows the CAD Viewer's existing style (sage37).

## Constraints

- Engine: Python with `cadquery-ocp`; no new dependencies.
- The warm engine protocol of `serve.py` and `WarmEngine.swift`.
- STEP in mm, viewer in metres.

## Left to the builder

- JSON shapes of the feature list and the serve request and reply.
- The fixed topological order used for imported references, and how
  history is followed through each operation.
- Push/pull's OpenCascade operation.
- Edge picking tolerance on screen and how hover is drawn.
- Cache size limits.
- **Builder's call: a STEP with several parts.** The user picks the part to
  edit from the CAD Viewer's part list; Save writes that part alone.
- **Builder's call: frame.** Edit mode shows the part alone in its own
  coordinate frame (as a CATIA part file has its own axes). XY, YZ and ZX
  are the part's planes, and Save writes the part in that frame so it drops
  back into the CATIA assembly.
- **Builder's call: source changed.** The feature list stores a fingerprint
  of the STEP it was made on (size, modification time, and a hash). If the
  file differs, every reference to the imported part is marked "reference
  lost" for the user to pick again; nothing is re-found by guesswork.
- **Builder's call: invalid part.** Edit mode checks the part is a valid
  closed solid first; if not, it offers to run the STEP repair, then edits
  the repaired part.
- `WarmEngine` handles one request at a time with a 60 s timeout: previews
  must be debounced and a newer request must replace a queued one, so slow
  fills don't pile up.
- Test fixtures: a box, and an endplate-like solid built with the
  existing OCC helpers in `cad/sample.py`. Tangency of a fill is checked by
  the angle between surface normals either side of the boundary.
