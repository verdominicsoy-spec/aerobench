# Decisions

Judgement calls made while building AeroBench, newest at the bottom of each
phase. Anything here can be revisited.

## Phase 0

**Repo layout.** Follows spec section 3. `scripts/` sits inside `engine/` as
the layout block indents it and section 8.1 names `engine/scripts/fetch_airfoils.py`.

**Built in a Linux container, verified on macOS CI.** Phase 0 was written in a
cloud session with no Xcode. The engine was run and tested there directly.
The Swift code is compiled and its tests run by GitHub Actions on a macOS
runner (`.github/workflows/ci.yml`), which also runs `xcodebuild` on the app.
That CI job is the main evidence the app builds until it is run on the real Mac.

**Swift split into an app target and a local package.** `app/AeroBenchKit` holds
everything that does not need SwiftUI: event parsing, the engine process
runner, project and job files. That lets `swift test` exercise the job runner
against the real engine, which covers the Phase 0 acceptance checks at that
level. The app target is views and observable state on top.

**Hand-written Xcode project, Xcode 16 format.** `project.pbxproj` uses a
file-system synchronised group for `app/AeroBench/`, so new Swift files are
picked up without touching the project file. Needs Xcode 16 or later. No
XcodeGen or other generator.

**Swift 5 language mode.** Both the app and the package compile in Swift 5 mode
with Swift 6 toolchains. Strict concurrency checking would add churn around
`Process` and pipes for no v1 benefit. Revisit when polishing.

**macOS 15 deployment target, arm64 only.** The target machine runs the latest
macOS; 15 is a safe floor for Observation, `ContentUnavailableView` and the
APIs used. Apple silicon only per spec section 2.

**No sandbox, no hardened runtime, sign to run locally.** The app has to launch
the engine from the repo and read and write project folders anywhere. Signing
and notarisation come with packaging (later phase).

**The app runs `engine/.venv/bin/aeroengine` directly, not `uv run`.** Two
reasons: `uv run` re-resolves the environment on every launch, and it puts a
uv process between the app and Python, so SIGTERM/SIGKILL would hit uv and
could orphan Python. The trade-off is that `uv sync` must have been run in the
engine folder, which Settings checks and reports.

**Cancelling.** SIGTERM, then SIGKILL after 3 s. The engine makes itself a
process group leader at startup, and the SIGKILL goes to the whole group so
any solver it starts later (gmsh, SU2) dies with it. On SIGTERM the engine
stops, cleans up its intermediates and exits with 143, logging a `cancelled`
warning event. No new event type was added.

**How a job is judged.** Succeeded only if the engine exited 0 and emitted a
`result` event. A job the user cancelled is cancelled. Otherwise it failed,
with the engine's own `error` message if it sent one, else a message built
from the exit status (killed by signal, non-zero exit, or no result) and the
tail of stderr. Nothing is shown as good unless the engine said so.

**Job folder contents.** The app owns `job.json`, `status.json` and `log.txt`;
the engine owns `result.json` and its intermediates. Jobs left as running by a
crash or quit are marked failed ("Interrupted") the next time the folder is
loaded.

**Intermediates.** Commands put throwaway files in `scratch/` and meshes in
`mesh/` inside the job folder. The engine removes both when the job ends,
whether it succeeded, failed or was cancelled, and keeps `mesh/` only when
`options.keep_mesh` is true. A SIGKILLed engine cannot clean up after itself,
so its `scratch/` may survive; it stays inside the job folder.

**Jobs with no project open** go to the app's cache folder
(`~/Library/Caches/<bundle id>/jobs`), the only place outside a project the app
writes, per spec section 4.

**Core limit.** Settings has max parallel jobs (default 2) and cores per job
(default 4). Cores per job reaches the engine as `options.cores` in job.json and
as `OMP_NUM_THREADS` / `AEROBENCH_CORES`; `JobContext.thread_env()` builds the
environment for child solvers. Placeholder defaults; tune once real runs exist.

**Engine dependencies are added per phase.** Phase 0 needs only the standard
library, so `engine/pyproject.toml` has no runtime dependencies yet. numpy,
scipy and the rest (spec section 3) are added, and checked for Apple silicon
wheels, when the phase that needs them lands. This keeps `uv sync` fast and
avoids pinning versions nobody has tested yet.

**Engine default for development builds.** Settings defaults the engine folder
to `<repo>/engine`, worked out from the source path at compile time, so a fresh
clone works without configuration.

**Project autosave on switch and quit.** Opening another project, closing the
current one or quitting saves unsaved project changes instead of asking.
Explicit Save (⌘S) is also there.

**SU2 install steps deferred to Phase 4.** They could not be verified from a
Linux container, and the spec asks for steps that actually work on the Mac.

**Airfoil data ignored by git now.** `data/airfoils/*` is gitignored ahead of
Phase 4 because UIUC's redistribution terms have not been checked yet.

## Phase 1: Lap Sim

**Placeholder car.** Mass with driver 280 kg, ClA 3.5 m², CdA 1.3 m², μ lateral
1.5, μ longitudinal 1.4, peak power 80 kW, driven axle share 0.55, downforce on
the driven axle 0.55, Crr 0.015, air density 1.225 kg/m³, top speed 33 m/s
(119 km/h). Rough figures for a typical Formula Student car with a full aero
package, not the team's numbers. They live only in the app
(`CarParameters.placeholder`); the engine requires every field in the job so
there is a single source of defaults. The app marks any value still equal to
its placeholder with "est.".

**Extra input: downforce share on the driven axle.** The spec counts the driven
axle's share of downforce in traction but does not list a balance input, so
`aero_balance_driven` was added, defaulting to the same 0.55 as the static
split.

**Rolling resistance acts on static weight only.** With rolling resistance on
the downforce-loaded tyres, extra ClA can make a power-limited straight slower,
which breaks the "adding ClA never makes a lap slower" check. The effect is
small at FS speeds. Revisit if it ever matters.

**The forward pass never decelerates.** Where drive force cannot beat drag and
rolling resistance (at the cornering limit, where the friction circle leaves
no longitudinal grip, or at the power-limited top speed) the car holds its
speed rather than slowing down. Slowing down is the braking pass's job. This
is the usual quasi-steady simplification and is what makes a constant-radius
skidpad run exactly at sqrt(μ g R).

**Integration.** Heun's method in v² over distance, with segment time
2 ds / (v_i + v_{i+1}), exact for constant acceleration. At 0.5 m spacing,
halving the step moves lap time by under 0.01% on all built-in tracks, well
inside the 0.5% check. A 381 m lap takes about 30 ms.

**Closed tracks run three laps back to back and keep the middle one**, so the
reported lap is a flying lap independent of where the start line is. Open
tracks start at the given start speed (0 by default) and end without braking.

**Endurance.** Total time is laps × flying-lap time, energy is laps × per-lap
energy. Energy is mechanical energy at the wheels, the integral of positive
drive force over distance. No standing start, driver change, tyre or
efficiency model.

**Sensitivities.** Central differences with a step of 5% of the value
(at least 0.05 m² for ClA, 0.02 m² for CdA), falling back to a forward
difference when the lower point would be negative. Exchange rate is
−(∂t/∂CdA)/(∂t/∂ClA): the ClA that pays for one m² of CdA at equal lap time.
Reported as n/a when ClA does not change the lap time at all.

**Built-in tracks.** Skidpad: one 9.125 m centreline-radius circle, flying.
Acceleration: 75 m straight from rest. Test track: a synthetic closed loop
defined as a polar curve r(θ) = 55 (1 + 0.28 cos 2θ + 0.12 sin 3θ) m, about
381 m long, 12.4 m tightest radius, with a reverse-curvature section. Its
curvature is analytic. The skidpad radius, acceleration length and start
speed are editable. Real event layouts are imported as CSV.

**CSV tracks** go through a cubic smoothing spline (`scipy.interpolate.splprep`,
periodic for closed loops) with smoothing set from the expected point scatter
(0.05 m by default, editable), then are resampled by true arc length.
Curvature comes from the spline's derivatives.

**Display units.** Speeds in km/h, power in kW, everything stored SI. The
track map colormap (blue slow to red fast) is a plain v1 choice, to be
replaced by sage37 tokens when styling starts.

## Phase 2: CAD Viewer and the shared 3D core

**SceneKit, not RealityKit, behind the `Viewer3D` protocol.** The spec allows
SceneKit if RealityKit fights custom meshes with per-vertex colour or fast
mesh replacement, and it does: per-vertex colour on a custom RealityKit mesh
needs a custom shader material, picking needs collision shapes (expensive on
million-triangle meshes), and the orbit/ortho camera has to be built by hand.
SceneKit has all of these built in. Apple has stopped adding features to
SceneKit, so the protocol is what keeps a later move to RealityKit or Metal
contained: the CAD tool talks only to `Viewer3D`.

**The 3D core is its own module.** `AeroBench3D` (in the AeroBenchKit package)
holds the viewer; the mesh model, loaders and measuring maths are in
`AeroBenchKit`. The CAD tool is just views and state on top, so the Flow Field
Viewer can reuse all of it.

**.glb written by the engine itself.** A small numpy glTF 2.0 writer
(`aeroengine/cad/meshio.py`) rather than trimesh, for full control over node
names, instancing and transforms. trimesh is not a dependency yet. Swift reads
glb with its own reader (SceneKit and Model I/O do not read glTF).

**AeroBench .glb files keep the CAD frame (z up), in metres.** glTF's
convention is y up; rotating would make every coordinate the app shows differ
from CATIA's. The file records `"up_axis": "z"` in `extras`. An export for
other tools can add the rotation when export lands.

**Instancing.** Each part is meshed once and instances become nodes with the
instance transform, so the sample car's four wheels share one mesh. CATIA
assemblies reuse parts heavily, so this matters for size and speed.

**Names.** Instance names come from the STEP occurrence, falling back to the
part name. Purely numeric names are STEP ids rather than names and are
replaced by the part name.

**IGES has no assembly structure.** IGES (and OpenCascade's IGES writer in
particular) usually carries loose trimmed faces. A part like that is sewn
(tolerance 1e-5 × the model diagonal, at least 1 µm) and split into one
"Body n" node per shell, so the visibility toggles still mean something.
Parts with several solids are split the same way.

**Tessellation presets** set OpenCascade's chordal deflection as a fraction
of the model's bounding-box diagonal: coarse 2e-3, medium 5e-4, fine 1e-4,
with angular deflection 0.5, 0.25 and 0.1 rad. On a 2.8 m car, fine is
0.28 mm. The mesher runs in parallel within the per-job core limit.

**OpenCascade console output.** OCCT prints progress straight to stdout from
C++. The engine now gives its JSON event stream a private copy of stdout and
points file descriptor 1 at stderr, so native libraries can never corrupt
the event stream.

**Measuring.** Picks hit the rendered mesh. With Snap to vertex on (the
default) the point snaps to the nearest corner of the triangle hit; mesh
vertices lie exactly on the CAD surface, so vertex-to-vertex measurements of
edges and corners are exact to float precision. Without snapping, a pick on a
curved face can sit up to the chordal deflection off the true surface.

**Standard views assume z up**, with Front looking along +x (camera at −x).
That matches a CATIA car with x pointing rearward. A Y-up toggle covers mesh
files from other tools. STL and OBJ units default to mm.

**Tessellation cache** keyed on file path, size, modification date and preset,
in the app's cache folder. Editing the STEP invalidates it.

**Samples are synthetic.** `samples/sample_car.*` is generated by
`engine/scripts/make_sample_cad.py`: a named assembly (chassis box, four
instances of one wheel, front and rear wings with NACA 4412 main plane and
flap) with exact dimensions. The real CATIA file stays on Dominic's Mac. The
"opens a STEP exported from CATIA" and "a model of about 1 million triangles
orbits smoothly" checks can only be done there; the 0.1 mm measuring check is
automated (STEP → engine → glb → Swift → vertex-to-vertex distance).

**cadquery-ocp pinned to 8.x.** OCP 8 moved its collection classes
(`OCP.OCP.collections.Sequence_TDF_Label` and friends) and changed some
signatures; the code targets 8.x.
