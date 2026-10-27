# AeroBench

One native macOS app with four Formula Student aero tools: Wing Lab, CAD Viewer,
Flow Field Viewer and Lap Sim. SwiftUI front end, Python compute engine. The
full brief is in [docs/AeroBench_spec.pdf](docs/AeroBench_spec.pdf), and every
judgement call made while building it is in [docs/DECISIONS.md](docs/DECISIONS.md).

**Status:** Phases 0–3 built (foundations, Lap Sim, CAD Viewer, Flow Field Viewer). Wing Lab is an empty screen for now.

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

Quasi-steady point-mass lap sim. Pick a track (built-in test track, skidpad,
75 m acceleration run, or an imported centreline CSV), set car A and
optionally car B, and Run (⌘R). Results show lap time, endurance time and
energy, a speed trace, a track map coloured by speed, the B minus A time
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

Drag to orbit, scroll or pinch to zoom, two-finger drag to pan (SceneKit's
standard trackpad controls). Front/Back/Left/Right/Top/Bottom/Iso views, Fit,
and perspective or orthographic. Untick parts in the tree to hide them; the
bounds readout follows what is visible. Turn on Measure and click two points;
with Snap to vertex on, clicks snap to the nearest mesh vertex, so edges and
corners measure exactly. STL and OBJ carry no units, so pick mm, m or in.

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

**Calibrate** (left panel, top to bottom), drawing on the frame on the right:

1. Open the video (mp4/mov) or a folder of frames, or drop the video on the window.
2. Draw the crop around the plot region, and exclusion boxes over the legend,
   axis triad and any labels.
3. Pick the colour map, or *Sample the legend* and drag along the colour bar
   from its low end to its high end.
4. Enter the value range (the legend's ends, e.g. −1 and 1).
5. Scale: click two points whose y, z you know (y right, z up). If the camera is
   perspective (later planes look smaller, the ground line creeps up the
   screen), tick *Perspective camera* and do it on the first and last frames.
   Optionally limit the grid to a window around the region of interest.
6. Plane positions: x at the first and last frame (even spacing), or a CSV of
   one x per frame in mm. Frame range and stride.
7. Mask colours (white geometry and background by default), colour-distance
   threshold, median filter, working resolution.

*Check This Frame* runs one plane and shows the result with the median colour
distance; under about 5 ΔE means a good fit. *Reconstruct* builds the volume.
*Save Calibration* writes the setup as JSON to reuse on later videos; it is
also saved with the project in `flow/`.

**Explore**: isosurfaces (several at once, colours from the colour map, with
opacity), a value window that shows voxels between two values, and a slice
scrubber with the original frame beside the reconstructed plane, in mm.
Export isosurfaces as .glb or .obj (mm) and the volume as .npz or .vti
(ParaView).

*Demo Sweep* generates a synthetic perspective sweep with a known answer and
its calibration, to try the tool without real data.

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

Not needed until Phase 4 (Wing Lab). The exact Apple silicon install steps will
be written here once they have been checked on the actual machine.
