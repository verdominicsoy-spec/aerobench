# STEP repair to one closed body

Date: 2026-11-03. Status: design, awaiting approval.

## Intent

The CAD Viewer can check a STEP file and run a blanket repair (`ShapeFix` plus
sewing at a fixed 0.01 mm), but most real problems are left to the user, as
in STAR-CCM+. The goal: load a STEP car assembly and get back **one closed,
valid body** that STAR-CCM+ can surface-mesh without manual repair. The user
splits it into regions in STAR afterwards, so part identity does not need to
survive the fuse (the user's call: "splitting things in starccm is easy").

The user's CAD is usually good, with tiny problems. The tool should fix
those without asking, and ask only about fixes big enough to change the
aerodynamics.

## Goals

- STEP / STP input only (IGES may follow later; mesh files are out).
- Sized for repairing **part by part** (the user's working style): a file
  holds one part or a small assembly, tens of parts at most, so a single
  fuse call is fine and no batching is needed.
- Fix small defects per part, close each part into a solid, fuse every
  solid into one body (overlaps such as a wing through an endplate, and
  internal touching faces, disappear).
- Three bands for gaps, measured as the distance across a gap between free
  edges:
  - up to **0.5 mm**: fixed automatically. The 0.5 mm is a user setting.
  - **0.5 to 10 mm**: a queue item the user reviews (accept / skip, plus
    "Accept all").
  - **over 10 mm**: never stitched; reported only.
- Each queue item: what it is, its size, its part, its location; selecting
  it frames the viewer on it and draws the proposed fix.
- Decisions (accept / skip) are saved and re-applied to the next revision
  of the same CAD.
- Output `<name>_repaired.step` plus a short report of what changed.

## Non-goals

- Mesh (STL / OBJ) repair. The existing mesh repair stays as it is.
- Keeping part names or regions through the fuse.
- **Gaps between different parts** (the user's call). Only gaps inside one
  part are paired, queued or stitched. Parts that do not touch stay
  separate solids, so wing slots between separate elements are never
  touched. Near misses between parts are not detected.
- Defeaturing (removing bolts, holes, small fillets).
- The GSD-style surface editor (a separate project, next).

## Anti-goals

- Closing a gap that is meant to be there. Wing slot gaps (main plane to
  flap, flap to flap) and floor-to-bargeboard gaps are often 8 to 15 mm;
  stitching one silently makes the wing aerodynamically wrong while the
  body looks clean. Nothing above the automatic limit is applied without
  the user accepting it.
- Moving any surface by more than the automatic limit without review.
- Reporting success when the output is not one valid closed body.

## Approaches considered

- **A. Plan job, then apply job (chosen).** Job 1 runs the full pipeline on
  the original file, applies the automatic fixes, stops short of any
  medium gap, and returns the result, the report and the queue. The user
  reviews. "Apply" runs job 2 from the original file with the accepted
  items and writes the output. Fits the existing job system (`cad-check`,
  `cad-repair`), is reproducible, and decisions can be replayed on a new
  revision. Cost: a full rerun on Apply (possibly a minute or more on a big
  assembly).
- **B. Live session in `WarmEngine`.** Instant accepts, but the engine must
  hold the assembly and an undo history, a crash loses the session, and the
  fuse reruns at the end anyway. Rejected: much more code, little time saved.
- **C. Apply everything up to 10 mm, undo afterwards.** Rejected: applies
  the risky slot-gap stitches first, against the anti-goal.

The user chose A.

## Pipeline (engine)

Both jobs run the same pipeline; the plan job has no accepted items, the
apply job has the user's.

1. **Read** the STEP with the existing XCAF reader; take every part once,
   placed by its assembly transform (as `brepcheck._instances` does).
2. **Clean each part**: `ShapeFix_Shape`; drop tiny edges and sliver faces
   below their own small tolerance, 0.01 mm by default (the current repair
   tolerance), never the gap limit, so trailing edges, gurneys and thin
   lips of 0.2 to 0.5 mm survive (builder's call, from the anti-goal); fix
   self-crossing wires.
3. **Close each part**: pair free edges within the part only, and sew with tolerances stepping up to the automatic
   limit (not one fixed value). Remaining free edges are paired into gaps;
   gaps above the limit become queue items (0.5 to 10 mm) or reports
   (over 10 mm). Accepted gaps are sewn at their own size. A part that
   closes becomes a solid.
4. **Parts that will not close** (free edges left after step 3 that are not
   an accepted or pending gap) become a queue item. Proposed fix: patch the
   hole with a filling surface when its boundary is a closed loop; if that
   fails, the part is written as an open shell (step 7). The item says
   which.
5. **Fuse** every solid into one body (`BRepAlgoAPI_Fuse`, with a fuzzy
   value no larger than the automatic limit). Parts that do not touch stay
   separate solids in the one output; that is expected (a separate front
   wing is fine).
6. **Verify**: no free edges, no edges shared by three or more faces,
   `BRepCheck_Analyzer` valid. Any failure is reported plainly in the
   result, never hidden. Edges shared by three or more faces left after
   the fuse are reported as items with no automatic fix.
7. **Write** `<name>_repaired.step` (apply job; the plan job may write a
   preview file the app can show). Apply always writes the file. A part
   that could not be closed (a skipped gap, a gap over 10 mm, a failed
   patch) goes into the same STEP as a separate open shell, beside the
   fused body, never dropped. The report names each such part, and the
   result says "one closed body" only when it is (builder's call).

## Queue items

Each item carries: a stable id, kind (gap, open part, unresolved edge),
part name, size in mm, a location (centre point), and preview geometry
(polylines of the two edges either side of a gap, or of a hole boundary)
in the model's world coordinates.

**Matching across revisions**: decisions are saved next to the source as
`<name>.repair.json` (kind, part name, centre point, size, decision). On a
new run, an item takes a saved decision when kind and part match and the
centre lies within a few mm. Unmatched saved decisions are ignored.

## App (CAD Viewer)

- The Geometry check section gets, for STEP files, a **Repair to One
  Body…** action that runs the plan job (progress as for the existing
  jobs).
- When it finishes: a summary line (what was fixed automatically) and the
  queue as a list: kind, part, size. Selecting a row frames the viewer on
  it and draws its preview lines in the viewer. Each row has accept / skip;
  the list has **Accept All**. Items carried over from a saved decision show
  as already decided.
- **Apply** runs the apply job, then saves through the existing save panel
  and opens the result, as `repairGeometry()` does today.
- An empty queue means Apply can run straight away (or the plan job's
  output is offered directly).
- The setting for the automatic limit (default 0.5 mm) lives in the
  section, beside the action.
- The UI follows the sage37 Swift design (the app's existing style).

## Constraints

- Engine: Python with `cadquery-ocp` (OpenCascade); no new dependencies.
- Jobs follow the existing `@command` pattern and `JobManager` in the app.
- STEP lengths are in mm; the app's viewer works in metres.

## Left to the builder

- Exact command names and JSON shapes.
- The sewing tolerance steps, and how free edges are paired into gaps.
- How preview lines are drawn in the viewer (markers exist; lines are new).
- The tolerance for dropping tiny edges and sliver faces.
- Whether the plan job writes a preview STEP.
- Test models: build small synthetic STEP fixtures (two overlapping boxes,
  a box with a 0.2 mm gap, a box with a 5 mm gap, a box with a 12 mm gap,
  a two-element wing with a 10 mm slot) with the existing OCC helpers in
  `cad/sample.py`.
