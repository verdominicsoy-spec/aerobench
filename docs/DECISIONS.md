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

## Phase 3: Flow Field Viewer

Built against a real STAR-CCM+ Cp0 sweep from Dominic (1080p H.264, 900
frames, kept out of the repo), which shaped several of these.

**Perspective cameras are supported.** That video is a perspective view: the
plane moves away from a fixed camera, so the ground line climbs from row
1017 to 693 over the sweep and a pixel covers more metres in later frames.
A pinhole model (scale ∝ 1/distance, distance linear in frame) fits its
ground line to 1.2 px across all 900 frames. So the scale can be calibrated
on two frames (first and last) and is interpolated between them as
1/scale linear in frame; the image of the world origin moves linearly with
the scale. One calibrated frame means a fixed scale (parallel camera).

**Everything is resampled to one world grid before stacking.** Each frame is
pre-shrunk (area averaging) to about one pixel per grid cell, then sampled at
the grid's world positions through that frame's scale. This is what makes a
perspective sweep stack into a consistent volume. The grid covers everything
any frame sees by default ("all", trimmed to where data exists), or only what
every frame sees ("common"), or an explicit world window. The window matters
for perspective sweeps: the far frames see a much bigger region than the near
ones, and without a window the near planes get few cells.

**Colour inversion** is nearest colour in CIELAB against a 512-entry table,
with pixels further than a threshold (12 ΔE by default) marked empty, and mask
colours (white by default, 10 ΔE) marked empty. The median filter is NaN-aware:
empty cells are filled from their nearest neighbour, filtered, then emptied
again.

**Legend sampling averages across the bar and smooths along it** (3% of its
length). STAR draws a stepped legend (about 30 bands) but a smooth field;
smoothing turns the steps back into the continuous map. Detecting band edges
was tried and is unreliable through H.264.

**No automatic lighting correction.** STAR lights the plane, so the field's
colours are not exactly the legend's. On the real video the plane sat about
3.5 ΔE (median) from the sampled legend, freestream (Cp0 = 1) read 0.984,
and a lit corner a little lower. (Most of that turned out to be the legend
sampling, not lighting; see "Legend ends" below: now 1.4 ΔE and 0.996.) A fitted per-channel gain and offset only cut
the median to 2.1 ΔE and made the lit corner worse, so it was left out. The
capture guide says to turn lighting off.

**The STAR-CCM+ preset** is the blue-yellow-red map as sampled from that
legend through H.264, so approximate. Sampling the legend in the video being
reconstructed is the more accurate option. Viridis uses a published polynomial
fit (within about 1/255), jet and rainbow are their usual formulas.

**Isosurfaces** use scikit-image marching cubes in the engine, one job per
level, about 2 s for 300 × 256 × 136. Empty voxels are filled with the top of
the range (freestream for Cp0), so surfaces close around bodies, and the
volume is padded by one layer so surfaces close at its edges. That also makes
their enclosed volume measurable. OBJ export is in mm, glb in metres.

**Value window** runs in Swift on the raw volume (volume.bin), thinned evenly
to at most 250,000 points so it stays interactive.

**VTK export** is ImageData (.vti) with raw appended float32, written directly.
Uneven plane spacing is resampled to even spacing along x first, since
ImageData needs it. VTK's own reader reads it back exactly (tested).

**Regression test (the spec's acceptance check).** An analytic wake (spreading
and recovering downstream) with a body and ground, rendered with the STAR
preset and a banded legend, encoded with libx264 at CRF 18 (yuv420p),
reconstructed, compared to the analytic field away from body and domain edges.
Fixed and perspective cameras both pass: worst error 0.041 (2.1% of the range,
limit 3%), isosurface volumes at Cp0 0, 0.3 and 0.6 within 1–2.5% of exact
(limit 5%). imageio-ffmpeg supplies an ffmpeg with libx264 on every platform.

**Real video, qualitative.** With a guessed absolute scale (the real one
needs Dominic's dimensions), the sweep reconstructs to 300 planes in about 20
s with a recognisable car body, rear wing with endplate vortices, and a wake
that merges downstream.

## After Phase 3: feedback round

**Own camera instead of SceneKit's.** SceneKit's built-in camera control
zooms only toward a fixed centre and stops when it gets there, so you could
not get in close to a part off-centre. `OrbitCamera` (AeroBench3D) replaces
it: turntable orbit with world up kept up, pan in the view plane, zoom toward
the point under the cursor with no lower limit, and a double-click pivot.
The maths is unit tested (the zoom point, the pivot and panned content stay
where they should on screen).

**Flow Field object.** Cells that match a mask colour are now kept as a
solid mask in the volume instead of being discarded as empty. `flow-object`
meshes it after a one-voxel Gaussian blur, ignoring the outermost y/z layer
(it samples the crop edge) and, by default, everything at or below z = 0, so
the white below the ground is not shown as a slab. Excluded areas and frame
borders are never solid.

**Rules as data.** `data/rules/fs2027_aero.json` holds the FS Rules 2027 v1.0
aero limits (T8.2, T2.1-T2.4) and the FSUK 2027 differences (T8.1.2, T8.3.3,
T8.4.5), each with its rule number and source. FSUK applies the FS geometry
limits unchanged. The limits are relative to the car (tyres, head
restraint). Wing Lab works on a wing in a free plane, not placed on the car,
so a rules box there is an optional rectangle the user places, with this file
as the reference for its size.

**Geometry check and repair.** Written in NumPy rather than pulling in
MeshLab or similar: vertices are welded (1e-7 of the model size), then
degenerate faces, duplicate faces (including back-to-back), open and
non-manifold edges and inconsistent winding come from edge counting, and
pierced faces from a uniform-grid broad phase plus segment-triangle tests
(crossing a triangle's edge counts, merely touching does not). Candidate
pairs are streamed in chunks so memory stays bounded; a million-triangle
mesh checks in about 17 s on the cloud container. STEP/IGES are also checked
as B-rep through OpenCascade (BRepCheck validity per face and edge,
ShapeAnalysis_Wire self-intersection and tiny edges, free edges); OCP 8 cannot
return BRepCheck's status lists, hence this route. B-rep problem markers are
placed at every instance of a part, counted once per part. Repair only does
what cannot make things worse; pierced faces and non-manifold edges need a
remesh or boolean and a person's judgement, so they are reported only. The
repaired file is never written over the original: you choose where it goes.

**Perspective sweeps without drift.** With a perspective camera the scale of
every plane came from two clicked frames and the pinhole model between them.
Any error in those clicks, or a camera off the centreline, made the planes
drift: the ground crept up and the object and fine detail smeared. Now the
ground line is measured in every frame instead (the first non-mask pixel up
from the bottom of the crop, median over columns clear of exclusions, needs
15% of columns), and a pinhole model v = vh + K / (a ± frame) is fitted to it
robustly (soft L1). Each frame's scale is the reference scale times the ratio
of its ground distance below the horizon, and its z = 0 sits on the measured
ground, so one calibrated frame is enough. On the real STAR video the fit is
within 0.3 px median and 0.6 px worst over the sweep. A fixed camera shows up
as a constant ground row and is used as such. A fit worse than 3 px median
stops the job rather than produce a wrong volume. Tracking needs +z up in the
frames; top views still use two calibrated frames.

**Any perpendicular view.** The calibration says which world axis points right
and which up in the frames; the remaining axis is the sweep. Internally
everything is in image-plane h, v and the volume is turned into world x, y, z
at the end, with mirrored axes flipped, so the Explore tools, exports and the
3D slice do not care which way the video looked. volume.json now carries all
three coordinate arrays and the axes (the old y0/dy/z0/dz stay for older
readers).

**Detail follows the video.** A fixed 256 cells across threw away most of a
1080p frame. With a detail level the cell is 1.5 px of the sharpest frame
(finer gains nothing, the colours blend over a pixel or two), made coarser
only if the grid would exceed the voxel budget: 8, 30 or 100 million voxels
(0.03, 0.12, 0.4 GB as float32).

**What can be automatic, and what cannot.** Within a plane the aspect ratio
is never a free choice: pixels are square, so every mode now uses one scale
(crop size takes the width and the height follows; a height that disagrees
by more than 2% is an error rather than a stretched volume). The crop,
exclusions and legend bar are found automatically (`flow-detect`): overlays
are the pixels with sharp edges that do not change across 24 frames spread
over the sweep (anything over half the frame is a fixed camera's ground line
or plot border and is kept), and the plot is wherever the colour map's
colours appear outside them. The legend bar is the line in an overlay whose
colours run steadily (correlation 0.95) through 90% of the map. On the real
STAR video this finds the legend and its labels, the axis triad, the plot
down to the ground and the bar to within a pixel of a hand-drawn one, in
about 6 s.

Absolute size cannot come from pixels: something of known size has to be
in the picture or the camera has to be known. So one frame is still
clicked. The length along the sweep is different: a pinhole camera's scale
is focal length / distance, and ground tracking measures every frame's
scale, so 1/scale against plane position is a straight line whose slope is
the focal length. With linear or CSV positions the engine reports the view
angle that implies, to compare with STAR's. Given the view angle instead,
the positions follow from the first one. Whether STAR's view angle is
measured across the height or the width I could not confirm, so the user
chooses. The camera looks along -(right x up), so the engine also knows
which way the planes recede and flags positions entered the wrong way round;
the STAR video's triad (x towards the viewer) agrees.

The synthetic rear view was mirrored (x grew away from a camera with +y to
its right). It is now a real camera: planes recede towards -x. Its far end
holds the body and the narrowest wake at about 4 mm a pixel, so that case is
held to 5% of the range at its worst cell (99.9% within 1.6%); the front
view, which has the old geometry the right way round, is now the default.

**Legend ends.** The macOS CI run caught a marginal fit: an auto-detected
legend line runs to the bar's last pixel, where H.264's colour blur mixes in
the background, and the old sampler held the last 3 px flat, smoothed with the
ends pulled towards the middle, and stopped at a banded legend's last band
centre. Free stream (always drawn in the map's end colour, being clipped)
then sat 12-13 ΔE from the sampled end, at the rejection threshold, and one
decoder's rounding emptied 40% of the volume. Now: the last few pixels carry
the colour's trend from just inside out to the end; smoothing pads with the
profile's own trend; and where the two bands at an end are flat and about
the same width, the colour carries on half a band past the last centre
(detecting every band edge stays unreliable through H.264, the two end bands
are enough). A 32-band STAR map's ends go from 11.6 to 1.2 ΔE off, a 16-band
one from 22.5 to 8.2, a smooth one from 9.1 to 3.7. On the real video the
median fit goes from 3.4 to 1.4 ΔE and free stream reads 0.996.

**Quick setup.** "I can't get it to work" with seven sections of settings
was fair: the scale asked for two clicked points with typed world
coordinates, the axes for a reading of the triad, and auto-detect was a
button to find. The quick setup asks only what the video cannot say: the
legend's end numbers, one known width (dragged level on any frame, its middle
the centreline by default) and the plane positions. Everything else is found
on opening the video, including the axes: STAR draws the triad x red, y
green, z blue, and each visible arrow's head is its wide end. It was
checked by simulating careless users (lines 3 px off at each end, on random
frames, defaults left alone) on front, rear and side synthetic sweeps: all
built, 99% of cells within 1-4% of the range, one 6% where the line was
measured on the farthest, smallest frame, which the app now warns about
(under 250 px). New calibrations no longer default to planes at 0 and 1 m,
which made the plane step look done before anyone typed anything. A point
never clicked is now a problem before the engine sees it.

**The vanishing point.** With one calibrated frame and ground tracking, the
sideways offset used to stay fixed in pixels, which is right only for a
camera on the right axis's origin. Planes shrink towards the vanishing
point, and a CFD render puts it at the frame's centre: fitting the STAR
video's car centreline against scale puts it at column 959 of 1920. That
video's camera is about 120 px off the centreline, so the old model let the
car wander 7 cm sideways through the sweep; now it stays within a few mm.
Side views, where the camera sits partway along the car, needed this to
work at all. `ground.principal_u` overrides the column for a cropped video.

**Where the cells go.** On the STAR video "medium" detail gave 36 mm cells:
the grid covered everything the far planes see (about 9 x 3 m, nearly all
free stream) and all 900 planes, 3 mm apart. Two changes, both automatic in
the quick setup: the `auto` extent bounds the grid by wherever the colours
are not free stream (the most common value) or there is geometry not joined
to the frame's edge, from 30 frames at quarter size, plus 15%; and with a
detail level the planes are thinned so they are about as far apart as the
cells across them. Same video, same time (about 40 s): 10 mm cells, 6.7 mm
at high detail in 90 s.

**Decoding the same everywhere.** The macOS CI run read the synthetic side
view noticeably worse than Linux (worst cell 6% against 3.4%). Two changes:
the engine asks OpenCV for its FFmpeg decoder explicitly (macOS would
otherwise use AVFoundation, which converts colours its own way), and the
ground edge is found to a fraction of a pixel (where the colour distance
crosses halfway between flow and ground) instead of at whole pixels, which
flip with how a decoder rounds a blurred edge. Re-encoding the side view
from CRF 14 to 28 now moves the worst cell from 3.3% to 5.1% (it was 3.1%
to 8.9%), and the worst ground misfit stays at 0.5 px.

