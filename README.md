# AeroBench

One native macOS app with four Formula Student aero tools: Wing Lab, CAD Viewer,
Flow Field Viewer and Lap Sim. SwiftUI front end, Python compute engine. The
full brief is in [docs/AeroBench_spec.pdf](docs/AeroBench_spec.pdf), and every
judgement call made while building it is in [docs/DECISIONS.md](docs/DECISIONS.md).

**Status:** Phases 0–3 built (foundations, Lap Sim, CAD Viewer, Flow Field Viewer). Phase 4, Wing Lab, built and validated (NACA 0012 against Ladson, the 30P30N, a mesh study and an overnight optimisation; docs/DECISIONS.md has the numbers), waiting for review.

## Layout

```
app/                  Xcode project (AeroBench.xcodeproj)
  AeroBench/          SwiftUI app sources
  AeroBenchKit/       Swift package: engine runner, project/job files, mesh loaders (AeroBenchKit)
                      and the shared 3D viewer core (AeroBench3D), unit tested
engine/               aeroengine Python package, managed with uv
  src/aeroengine/     CLI, job context, commands
  tests/              pytest suite
  scripts/            one-off tools (fetch_airfoils.py arrives in Phase 4)
data/airfoils/        airfoil library, fetched not committed
samples/              small test inputs, including a synthetic CAD assembly
docs/                 spec and DECISIONS.md
```

## Setup on the Mac

You need Xcode 16 or later (for the project format) and [uv](https://docs.astral.sh/uv/).

```sh
# 1. uv, if you don't have it (either works)
brew install uv
# or: curl -LsSf https://astral.sh/uv/install.sh | sh

# 2. The engine. uv fetches Python 3.12 itself and builds engine/.venv
cd engine
uv sync
uv run pytest -q          # should be all green
cd ..

# 3. The app: double-click AeroBench.command in Finder
```

**`AeroBench.command` is the everyday way in.** Double-click it in Finder: it
pulls the latest version, updates the engine, rebuilds the app (only what
changed; the first build takes a minute or two) and opens it. If any step
fails it says why and opens the last build that worked. Drag it to the right
side of the Dock to launch from there. The built app lives in `build/` (not
committed).

The first time, macOS may say it cannot verify the script: right-click it,
choose Open, then Open again. After that a double-click is enough.

To work on the code itself, open `app/AeroBench.xcodeproj` in Xcode and Run
(⌘R) with the **AeroBench** scheme and **My Mac**. Signing is set to "Sign to
Run Locally", so no Apple developer team is needed.

On first launch the engine folder in Settings (⌘,) defaults to this repo's
`engine/` folder. If it shows "Engine not found", point it at `engine/` and make
sure `uv sync` has been run there. The app runs `engine/.venv/bin/aeroengine`
directly.

## Phase 0 checks

On the Project screen (no project needs to be open):

1. **Ping Engine** should show "pong from Python 3.12.x".
2. **Run** the dummy job at 10 s, open **Jobs** in the sidebar, watch the progress
   bar move, then press **Cancel**. It should end as cancelled within a second.
3. Run it again, and while it is running kill the engine from Terminal:
   `pkill -9 -f "aeroengine dummy"`. The job should show as failed with
   "Engine process was killed (signal 9)" and the app should keep running.

The same three behaviours are covered by automated tests in
`app/AeroBenchKit/Tests` that drive the real engine:

```sh
cd app/AeroBenchKit
AEROBENCH_ENGINE="$PWD/../../engine" swift test
```

## Lap Sim

Quasi-steady point-mass lap sim. Pick a track (real event layouts: FSG
Hockenheim and FSI Varano trackdrive, from AMZ's MIT-licensed fssim, see
data/tracks; or the built-in test track, skidpad,
75 m acceleration run, or an imported centreline CSV), set car A and
optionally car B, and Run (⌘R). Results show lap time, endurance time and
energy, a speed trace, a track map coloured by speed, a track map coloured
by where B gains (green) or loses (red) time on A, the B minus A time
delta, and dt/dClA, dt/dCdA with the ClA-for-CdA exchange rate.

The car values shipped are **placeholder estimates**, marked "est." until you
change them. Every value is editable and saved in the project's
`lapsim/setup.json` when you save.

Track CSVs: the first two numeric columns are taken as x and y; header and `#`
comment lines are skipped; commas, semicolons, tabs or spaces all work. Pick m
or mm in the app. Whether the loop is closed is detected from whether the ends
meet, or set it by hand. With a project open, imported CSVs are copied into
`lapsim/tracks/`.

The engine side can be run by hand too:

```sh
cd engine
cat > /tmp/job.json <<'JSON'
{"params": {"track": {"builtin": "skidpad"},
  "car": {"mass": 280, "cla": 3.5, "cda": 1.3, "mu_lat": 1.5, "mu_long": 1.4,
          "power": 80000, "driven_axle_fraction": 0.55, "aero_balance_driven": 0.55,
          "crr": 0.015, "rho": 1.225, "v_max": 33}}}
JSON
uv run aeroengine lapsim --input /tmp/job.json --workdir "$(mktemp -d)"
```

## CAD Viewer

Drop a STEP, IGES, STL, OBJ or glb file on the window, or use Open. STL, OBJ
and glb load directly. STEP and IGES go through the engine, which tessellates
them with OpenCascade (coarse, medium or fine) into a .glb that keeps the
assembly tree and part names; the result is cached in
`~/Library/Caches/dev.aerobench.AeroBench/tessellations`, so reopening the same
file at the same preset is instant.

Drag to orbit; pinch (or a mouse wheel, or ⌘-scroll) zooms toward the point
under the cursor, as close as you like; two-finger scroll, shift-drag or
right-drag pans; double-click a part to orbit around that point. Front/Back/Left/Right/Top/Bottom/Iso views, Fit,
and perspective or orthographic. Untick parts in the tree to hide them; the
bounds readout follows what is visible. Turn on Measure and click two points;
with Snap to vertex on, clicks snap to the nearest mesh vertex, so edges and
corners measure exactly. STL and OBJ carry no units, so pick mm, m or in.

**Check Geometry** looks for duplicate vertices and faces, degenerate
faces, open edges and holes, non-manifold edges, flipped normals and pierced
faces (within a part and between parts); for STEP/IGES also OpenCascade's
B-rep validity, self-intersecting face boundaries, tiny edges and free edges.
Problems are listed with counts and shown as coloured markers on the model.
**Repair…** applies only the safe fixes (merge vertices, remove degenerate
and duplicate faces, consistent outward normals, close small holes; shape
fixing and sewing for STEP/IGES), saves the result where you choose and opens
it. Pierced faces and non-manifold edges are flagged, never guessed at.

`samples/sample_car.step` (and `.igs`, `.stl`, `.obj`) is a synthetic named
assembly with known dimensions for checking all of this: the chassis is a
1500 × 600 × 300 mm box with a corner at the origin, and the wheelbase is
1530 mm. For a frame-rate check at about a million triangles:

```sh
cd engine
uv run python scripts/make_sample_cad.py --dense   # writes samples/dense_1M.stl (~50 MB, gitignored)
```

Then open it and tick FPS.

## Flow Field Viewer

Rebuilds a 3D total pressure (Cp0) field from a video of section planes
stepping through the flow, such as a STAR-CCM+ plane sweep.

**Quick Setup** (the default, left panel, top to bottom):

1. *Open Video…* (or drop it on the window). The app looks at frames across
   the sweep and finds the plot, the legend (and reads its colours), the
   things drawn over the flow, the axis triad and the ground line.
2. *Legend*: type the numbers at the ends of the colour bar, shown zoomed.
3. *Axes*: the triad from the video sits next to a drawing of the axes as
   set; pick which arrow points right and which up until they match. They
   are read off the video, so usually they already do.
4. *Size*: find a frame where you can see something whose width you know
   (the track between tyre centres, a wing's span), press *Measure*, drag
   across it and type the width. Its middle is the centreline (y = 0) unless
   you say otherwise; in a side view type where along x it is. With the
   ground tracked, that one measurement sets every plane's scale.
5. *Plane positions*: where the plane was in the first and last frames.
6. *Build 3D*. The checklist above the button says what is still missing.
   The result says what camera view angle your plane positions imply, and
   warns if they look the wrong way round.

*All Settings* has every option, for videos the quick setup cannot handle
(no ground in view, a top view, plane positions from a CSV):

1. Open the video (mp4/mov) or a folder of frames, or drop the video on the window.
2. *Auto-detect* (or draw by hand): it looks at frames across the sweep and
   finds the plot region with a strip of ground below it, boxes over
   everything that stays put while the flow changes (legend, labels, axis
   triad), the legend's colour bar, and whether the ground is in view (then
   ground tracking is switched on). Check the boxes on the frame afterwards.
3. Pick the colour map, or *Sample the legend* and drag along the colour bar
   from its low end to its high end (Auto-detect does this when it finds the
   bar).
4. Enter the value range (the legend's ends, e.g. −1 and 1).
5. Scale. First say which world axis points right and which up in the
   frames, off STAR's axis triad: a rear view is +y / +z, a front view
   −y / +z, a side view +x / +z (or −x). The third axis is the one the planes
   step along, and the volume always comes out in world x, y, z. Then click
   two points whose positions you know on one frame (or, with *Crop size*,
   the width the crop spans; the height follows, as pixels are square).
   For a perspective camera (later planes look smaller, the ground line
   creeps up the screen), tick *Track the ground line*: the engine finds the
   ground in every frame, fits a pinhole camera to it and pins z = 0 there,
   so the planes cannot drift and one calibrated frame is enough. A second
   calibrated frame is still worth it if the camera is off the centreline (it
   fixes sideways drift). Without tracking, calibrate the first and last
   frames. Optionally limit the grid to a window around the region of interest.
6. Plane positions along the sweep axis at the first and last frame (even
   spacing), a CSV of one per frame in mm, or *from the camera's view angle*:
   with ground tracking each frame's scale gives its plane's distance from
   the camera, and STAR's view angle turns that into metres, so only the
   first plane's position is needed. Frame range and stride.
   With ground tracking the result also says what view angle your plane
   positions imply. If it does not match STAR's, the spacing is wrong and the
   volume is stretched or squashed along the sweep; it also warns when the
   positions run towards the camera (the wrong way round).
7. Mask colours (white geometry and background by default), colour-distance
   threshold, median filter, and detail: *Low*, *Medium* or *High* make the
   grid follow the video's own pixels (about 1.5 px a cell) up to 8, 30 or
   100 million voxels; *Fixed width* uses a set number of cells across.

*Check This Frame* runs one plane and shows the result with the median colour
distance (under about 5 ΔE means a good fit) and, with tracking on, how well
the ground line fits. *Reconstruct* builds the volume.
*Save Calibration* writes the setup as JSON to reuse on later videos; it is
also saved with the project in `flow/`.

**Explore**: the object (the no-fluid space where geometry was, from the mask
colours), isosurfaces (several at once, colours from the colour map, with
opacity), a value window that shows voxels between two values, and a slice
scrubber with the original frame beside the reconstructed plane, in mm.
Export isosurfaces as .glb or .obj (mm), the volume as .npz or .vti
(ParaView), and the slice on screen as a PNG with its scale bar and Cp0
colour bar for slides.

*Demo Sweep* generates a synthetic perspective sweep (rear, front or side
view) with a known answer and its calibration, to try the tool without real
data.

## Wing Lab

A multi-element wing in its own plane (not placed on the car), analysed by
the solver that suits the question.

**Library** (left; the toolbar's sidebar buttons hide or show it and the inspector). The NACA 4 and 5-digit set is always there; *Download the
Library* fetches the UIUC database (about 1,600 sections, not shipped with
AeroBench since UIUC gives no licence to redistribute it). Search, filter by
family, source, thickness and camber, star favourites, and *Import .dat…*
your own (Selig or Lednicer) into My Airfoils. Every section is normalised to
unit chord with the leading edge at the origin and its trailing edge
thickness recorded. *Compute Polars* runs NeuralFoil on every section at the
main element's Reynolds number (a few seconds for the whole library), shows
each one's maximum lift and best L/D in the list, and sorts by either; a
question mark marks a section where NeuralFoil is unsure or maximum lift is
past 24°. They are for each section alone, saved as
data/airfoils/polars.json.

**Canvas** (middle). Drag a section onto the canvas to add an element, or onto
an element to swap its shape and keep its chord, angle and place. Drag an
element to move it, its round handle to turn it, its square handle to change
its chord; *Snap* and the angle and chord locks help. Wings start inverted
for downforce (a bigger angle means more downforce either way up). Gap
(trailing edge of the element in front to this one's surface) and overlap
(along the main chord) can be typed and move the element. Overlapping or
too-close elements turn red; an optional rules box (you place it, using
data/rules/fs2027_aero.json as the reference) turns them purple. ⌘Z / ⇧⌘Z
undo and redo.

**Solvers** (inspector, right):

| Solver | For | Speed |
| --- | --- | --- |
| Inviscid preview (panel method) | lift trends and how the load splits between elements, live while dragging; no drag, no slot effects | under 50 ms |
| Quick viscous (NeuralFoil) | choosing sections: a whole polar with drag and where the boundary layer turns turbulent, one element in isolation | seconds |
| Quick estimate (panel method + NeuralFoil) | every element together, Cl and Cd against the wing angle: lift within about 2% of RANS on a main-and-flap wing until the flap nears separation, drag about 10% high; not for slats | seconds |
| RANS CFD (SU2) | the real thing: slot flow, separation, gap effects; Spalart–Allmaras, SST, or SST with Langtry–Menter transition | minutes |

The quick estimate's *Live while editing* keeps the engine loaded (a few
seconds, once) and re-runs the estimate on every change, so the Estimate tab
follows an element as you drag it.

**Compare** (pin in the toolbar): pin the wing as A, then keep editing. A
stays on the canvas as a dashed purple outline, its Cp and estimate curves
are drawn dashed beside the current wing's, and the results strip shows A's
numbers and the difference from the best solver both have (CFD, else the
estimate, else the preview). *Swap* puts A back on the canvas (undoable).

*Help → How Accurate Is Each Solver?* (or the ? in the Wing Lab toolbar)
puts the same comparison in the app with the validation numbers.

The RANS mesh is zoned by the flow: structured quad wall layers on every
element (y+ about 1), finer flow-aligned wall cells where the quick viscous
solver says the flow is still laminar, unstructured triangles in the
turbulent regions and along the wakes, far field 50 chords out. (SU2 reads
triangles and quads in 2D, not polyhedra.) SU2 runs its JST central scheme;
on NACA 0012 at Re 6 million that matches Ladson's lift within 2% and drag
within about 15% up to 10° (docs/DECISIONS.md has the numbers). Runs that do
not converge are shown as not converged, not as results.

**Results** (under the canvas; a strip across the top shows the latest preview, estimate and CFD numbers side by side and what the wing adds to the car, click one for its tab): inviscid Cp, the quick viscous polar (Cl–α,
Cl–Cd, transition points), and the CFD run (Cl and Cd per element,
convergence, surface Cp, and the flow field: pressure, speed, total pressure
Cp0 or eddy viscosity over the plane with streamlines, and the value under
the pointer). *Show Flow Field* still opens the run's flow.vtu in Finder for
ParaView. Under RANS CFD, the *Quick* mesh gives a multi-element answer in
about 1½ minutes, converged to three figures (medium is the validated
default), and *Sweep the wing angle* runs the quick mesh over several
angles within 5 minutes.

**Removing things**: select an element and press Delete (or right-click it)
to take it off the wing. Right-click a section in the library to delete it
from My Airfoils (your imports) or to hide a built-in one.

**Optimise** (inspector): tick the angles, gaps and overlaps to search and
give each a range, pick an objective (most downforce, best L/D, most
downforce under a Cd cap, least drag for a downforce target) and TPE or
CMA-ES, and start. Each trial is a quick estimate by default (a few hundred
in about a minute; it finds element angles well but barely sees the gap,
so check the best few with RANS or run the study with RANS for gaps and
overlaps), or a RANS run with the model and mesh set under Solvers; *Settings* sets how many run at once (each on the per-job
cores). Wings that break the minimum gap or the rules box are skipped
without a run; failed or unconverged runs are recorded as failed and the
study carries on. The *Study* results tab has a sortable table of trials,
the best so far, and Cl against Cd with the Pareto front; click a trial to
put its wing on the canvas; *Time-lapse* plays the trials back in the order they ran, each one's wing on the canvas over the drawn one as the charts fill in. Studies are saved in the project
(`wing/studies/`), so stopping is safe and *Resume Study* carries on.

**Into the Lap Sim**: with the span and a 2D-to-3D factor (your estimate),
the wing's ClA = −Cl × span × total chord × factor (positive for downforce)
and CdA. *Compare in the Lap Sim* makes car B car A with this wing in place of
the one it replaces.

**Export**: each element as a .dat, or all points as CSV, in mm in the wing's
frame, for CATIA.
*Report as PDF* makes one A4 page for a design review: the wing, its
conditions, every solver's latest answer (with ClA and CdA on the car), Cp,
the estimate polar and the RANS flow field.

## The engine on its own

```sh
cd engine
uv run aeroengine list
uv run aeroengine ping --workdir "$(mktemp -d)"
```

Every command is `aeroengine <command> --input job.json --workdir <job folder>`.
stdout is JSON lines (`progress`, `log`, `result`, `error`), the result lands in
`<job folder>/result.json`, and exit codes are 0 done, 1 failed, 2 bad usage,
143 cancelled.

## Projects and jobs

A project is a folder:

```
My Project/
  project.json        name, dates, notes, per-tool state
  wing/ cad/ flow/ lapsim/
  jobs/<yyyyMMdd-HHmmss-xxxx>/
    job.json          what the app asked for (command, params, options)
    status.json       queued / running / succeeded / failed / cancelled
    result.json       written by the engine on success
    log.txt           everything the engine printed
```

With no project open, jobs go to `~/Library/Caches/dev.aerobench.AeroBench/jobs`.
Intermediates (`scratch/`, `mesh/`) are deleted when a job ends; `mesh/` is kept
only if Keep mesh was ticked.

## SU2

Wing Lab's RANS runs use SU2 8.5. There is no Mac package, so it is built
from source once (10 to 20 minutes) into `build/su2` in the repo, where the
engine finds it by itself. Either press *Install SU2* in Wing Lab when it
asks, or:

```bash
xcode-select --install          # once, if you have not got the command line tools
brew install open-mpi           # optional: lets SU2 use several cores
./engine/scripts/install_su2.sh
```

The *SU2 on a Mac* GitHub workflow builds it the same way on a Mac and runs a
two-element wing with it whenever the script changes. A different SU2 can be
set in Settings (the SU2_CFD binary or its folder).
