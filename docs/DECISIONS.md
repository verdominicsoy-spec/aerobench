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


## Phase 4: Wing Lab

**A free plane.** Dominic asked for Wing Lab to analyse a wing locally, not
anchored on the car, so there are no car reference points: the rules box is
an optional rectangle he places, with data/rules/fs2027_aero.json as the
reference for its size.

**Airfoil library.** UIUC states no licence for redistributing its
coordinates, so as the spec says the script (and the app's Download button)
fetch them and nothing is committed (data/airfoils/ is gitignored). The NACA
set is generated. All 1,665 UIUC files index in under 3 s; two are rejected
as not single sections: an engine cowl (naca1) and the whole 30P30N three-
element set in one file, which is kept in mind for the multi-element check.
Normalising keeps a file's own chord line when it is already chord-along-x:
de-rotating to the point furthest from the trailing edge tilted cambered NACA
sections by about 0.09 degrees, which moved Cl by 4% at zero angle against
their published polars. The re-panelling spline still rounds NACA's square
root nose a touch: 0.26% of Cl, about 0.006 degrees.

**Inviscid preview.** XFOIL's linear-vorticity stream-function method,
extended to several elements with a stream function constant and a Kutta
condition per element (and XFOIL's extrapolation at a closed trailing edge).
Lift converges at second order to the exact Karman-Trefftz solution (5e-5 at
320 panels); NACA 0012's lift slope is within 2% of 2 pi (1 + 0.77 t/c).
It runs in Swift in the app (Accelerate's LU, factorised once per geometry,
under 50 ms for three elements in a release build) because launching the
Python engine alone takes longer than that; the engine keeps the reference
copy, and the Swift tests check one against the other to 1e-8. The stream
function grows with distance, so elements more than a few hundred chords
apart lose precision; a real wing's are within a couple.

**Three solvers for three questions.** Dominic asked for solvers suited to
different things. Inviscid preview for angle trends and load split, live.
NeuralFoil (MIT, a network trained on XFOIL, through aerosandbox: about
400 MB in the engine environment and a 7 s first import, fine for a job) for
picking sections: whole polars with drag and transition points in
milliseconds, one element in isolation. SU2 RANS for the real slot flow. Each
says in the app what it can and cannot tell you.

**Trimmed mesh where laminar, polyhedral where turbulent.** Dominic's
request, in STAR-CCM+'s terms. SU2 reads only triangles and quads in 2D, so
true polyhedra would mean the STAR backend (listed for later). What the
laminar/turbulent split actually needs is resolution, not a cell shape, so
the SU2 mesh is zoned by the flow instead: structured quad wall layers
everywhere (y+ about 1), finer flow-aligned wall cells from the leading edge
to the transition point the quick viscous solver predicts on each surface
(where a transition model needs them), unstructured triangles in the
turbulent regions and wakes. With a fully turbulent model the zones only
refine the mesh; they matter with SST plus Langtry-Menter.

**Meshing robustness.** Each was a mesh SU2 diverged on, or one that would
have failed in a slot:
- gmsh's removeDuplicateNodes collapsed the trailing edge fan into
  zero-area cells: not used.
- Spacing that jumped 3.2x at a zone boundary, and 0.8% chord around a nose
  of 1.6% radius: the surface spacing is now limited to a tenth of the local
  radius of curvature (about 6 degrees per segment) and graded so neighbours
  differ by at most 15%.
- Wall-layer growth of 1.24: limited to 1.02-1.2.
- Wall layers are capped at 40% of the narrowest gap so layers from
  neighbouring elements cannot collide, and a slot that leaves room for
  fewer than 10 layers is refused with that reason.

**SU2 numerics.** On NACA 0012 at Re 6 million an adaptive CFL diverged twice
and CFL 50 diverged at once; a fixed CFL 25 on two multigrid levels took the
pressure residual down 8 orders in about 1,300 iterations (104 s, 4 cores).
Coarser meshes tolerate less, so if SU2 diverges the run is retried at CFL 10
and then 4, which is what one would do by hand; the result says which CFL it
took. Converged means the pressure residual fell 4 orders and Cl and Cd moved
less than 1e-4 of their value (with floors of 0.1 and 0.01, since a relative
change means nothing at zero lift) over the last 200 iterations. Anything
else is shown as not converged and greyed out.

**Installing SU2.** There is no Mac package (conda-forge has Linux only), so
engine/scripts/install_su2.sh builds SU2 8.5.0 from source into build/su2,
with MPI if Open MPI is installed; the app offers it as a button, and the
engine finds it there. A GitHub workflow builds it on a Mac the same way and
runs a two-element wing whenever the script changes. Linux CI takes SU2 from
conda-forge. gmsh's Linux wheel needs a few X/GL libraries even headless;
macOS has them.

**The optimiser runs in the engine, with the wing geometry in Python too.**
Each trial has to build its wing from design values, so placing elements,
gap, overlap and the validity checks exist in both Swift (the canvas) and
Python (the trials), with a Swift test pinning the Python numbers. The app
does not re-derive a trial's wing: the engine records every element's angle
and leading edge, and loading a trial puts exactly those on the canvas.

**Turning an element keeps the slots behind it.** Design angles turn each
element about its leading edge; then every flap goes back to the gap and
overlap it had as drawn (or to its design values), so a flap angle variable
does not drag the slot shut. Gap and overlap are solved together (Newton on
the flap's leading edge): setting them one after the other does not settle,
because the gap's direction depends on where the nearest point is.

**Invalid wings are scored, not failed.** The spec lists geometric
validity, minimum gap and the rules box as constraints. A wing that breaks
one is never meshed or run. Optuna's TPE learns nothing from a failed trial,
and in testing it spent 21 of 30 trials in the corner where the flap hits
the main element. So such a wing is told to the sampler as scoring far below
anything real (it learns to stay away), shown as "invalid" (never as a
result), and does not use up the trial budget; if 5 × the trial count of
them (at least 50) pile up in one session the study stops and says the
bounds hold almost no valid wing. Failed meshes, divergence and unconverged
runs are failed trials with their reason, as the spec says, and the study
carries on.

**Objectives with constraints use a penalty.** "Most downforce under a Cd
cap" and "least drag for a downforce target" subtract (or add) 10 per unit
of relative violation: 10% over the cap costs 1.0 in Cl. That works the same
for TPE and CMA-ES (which has no constraint support); trials over the limit
are marked and never picked as best. Downforce is −Cl for an inverted wing,
so "most downforce" is the same objective either way up.

**Parallel trials and resuming.** Trials run in threads, each launching its
own SU2 on the per-job core count, as many at once as Settings says (the
spec's example is 4 trials on 4 cores each). TPE uses its constant-liar
option so parallel trials do not all pick the same point. The study is an
Optuna SQLite file in the project (wing/studies/<name>.db); after every trial
the engine also writes <name>.json, which the app follows while the study
runs and reads when the project opens. Trials an interrupted session cut off
are marked interrupted, queued again and not counted. Restarting a study
with different variables or a different objective is refused.

**Validation: NACA 0012 at Re 6 million against Ladson (NASA TM 4074, 80
grit trip, from the NASA Turbulence Modeling Resource).** Spalart–Allmaras,
default (medium) mesh, about 22,000 cells, 2 to 5 minutes a point on 4 cores:

| α | Cl | Ladson Cl | Cd | Ladson Cd |
| --- | --- | --- | --- | --- |
| 0° | 0.000 | −0.013 (at −0.05°) | 0.00855 | 0.00809 |
| 5° | 0.548 | 0.536 (interpolated) | 0.00977 | 0.0085 (interpolated) |
| 10° | 1.071 | 1.071 (at 10.12°) | 0.0137 | 0.0120 |
| 15° | not converged | 1.513 (at 15.26°) | | 0.0190 |

Lift slope from 0° to 10° is 0.107 per degree against Ladson's 0.1065. Lift is
within 2%; drag reads 5% high at 0° and 12–15% high at 5° to 10°, mostly
pressure drag. At 15° Cl still swings by about 0.01 after 6,000 iterations,
so the run is flagged as not converged rather than reported: treat results
above about 12° on a single element (stall is near 17°) as a question for a
finer mesh or a time-accurate run.

**Mesh independence (same case, JST).** Coarse 13k, medium 22k, fine 45k
cells:

| Mesh | α=0° Cd | α=10° Cl | α=10° Cd |
| --- | --- | --- | --- |
| coarse | | 1.074 | 0.0141 |
| medium (default) | 0.00855 | 1.071 | 0.0137 |
| fine | 0.00842 | 1.069 | 0.0134 |

Medium to fine moves lift 0.2% and drag 1.5–2%, so medium is the default
and coarse (3% on drag, under half the time) is fine for optimiser trials.

**The scheme, not the mesh, was the drag error.** The first study, on SU2's
incompressible upwind FDS with MUSCL, gave Cl 1.04 and Cd 0.0168–0.0201 at
10°, 37% over Ladson. Each change below was run on the medium mesh at 10°:
finer leading edge spacing (0.0004 c) Cl 1.048 / Cd 0.0170; wall layers 2.5×
the flat-plate boundary layer 1.047 / 0.0169; far field at 200 chords
1.041 / 0.0174; least-squares reconstruction 1.047 / 0.0177; second-order
turbulence convection 1.044 / 0.0178; no multigrid 1.038 / 0.0177. On NASA's
own 225 × 65 grid the same set-up gave Cd 0.0174, and pressure drag
integrated from the surface was 0.0116 against about 0.0055 expected:
numerical dissipation. The JST central scheme (fourth-order coefficient
0.005, a quarter of SU2's default; the default gave Cd 0.0149) fixed both
lift and drag and converges at the same CFL 25. If JST diverges at every
CFL, the run falls back to FDS once and says so; the app warns that its drag
reads high, and the optimiser fails such trials since their drag would not
compare with the rest.

**Far field stays at 50 chords** (the spec's number): 200 chords moved Cd by
2% and Cl by 0.3%.

**Open MPI on one machine.** SU2 segfaulted intermittently on the Linux CI
runners while Open MPI chose a one-sided component for MPI_Win_create. The
engine now keeps Open MPI off UCX and the other cluster network transports
(uct, ofi, usnic) when it runs SU2 under mpirun; a user's own OMPI_MCA
settings still win.

**Wall layers fan round every sharp convex corner.** The 30P30N slat has a
cusp and its main element a stepped cove; gmsh's boundary layer field fanned
only at trailing edges and failed ("Edge not recovered") at the other
corners. Any node where the outline turns outward by more than 60° now gets
a fan. Library sections are smooth, so their meshes do not change. Coves are
still the mesher's weak spot: the 30P30N meshes as three elements, but its
slat alone and its main element with the flap did not, so sections with
coves and cusps may need a retry or a coarser level.

**SU2 stops when the answer is in.** SU2 ran on towards a residual of 1e-12
long after lift and drag had settled (on NACA 0012 at 10° they held from
iteration 2,262 of 3,790). The engine applies its own convergence test to
SU2's screen output, at half the tolerance for a margin, 20 iterations after
each file write (every 250 iterations), and stops the run when it passes.
The history is then judged as before; the flow and surface files are at most
250 iterations older than the forces, which by then move less than 1e-4.

**Runs that never settle steer the sampler too.** In the overnight test
study every failed trial had a flap angle above about 35°: the flap
separates, steady RANS never settles, and each such run burned its full
iteration budget (13 to 16 minutes) while TPE, which learns nothing from a
failed trial, kept proposing more. An unconverged run is now told to the
sampler as half the spread of the real results below the worst of them
(once there are two real results to measure by), so it learns to stay away;
it is still shown as failed, never as a result. Diverged runs and failed
meshes stay plain failures, since those can happen to a good wing.

**A resumed study does not replay its proposals.** With a fixed seed, every
session started the sampler from the same state, so after a resume it
proposed the designs it had already run (the test study ran one design three
times). The seed moves on by the number of trials already in the study.
Studies the app starts have no fixed seed.

**Acceptance: a two-variable study on a two-element wing.** NACA 4412 main
(300 mm, 3°) and flap (140 mm), inverted, 15 m/s, Spalart–Allmaras, medium
mesh; flap angle 15–45° and gap 6–25 mm, most downforce, TPE, 30 trials one
at a time on 4 cores. It ran from 21:02 to 02:54 (5.3 hours of trials). The
cloud container it ran in restarted three times and it was stopped once on
purpose; each time it resumed from its file, re-ran the trial that was cut
off, and carried on. On a Mac nothing restarts it, so it would have run
straight through. Result: 22 converged trials, 8 failed, 7 invalid wings
skipped without a run. Every failed trial had a flap angle of 29° or more
(the flap separates and steady RANS does not settle). The best, flap at
26.9° with a 9.1 mm gap, gave −Cl 1.977 against 1.883 as drawn (+5%), with
Cd 0.0406 against 0.0363; tighter gaps put the flap within the 5 mm minimum
of the main element, so the optimum sits against that constraint. The study
found three faults on the way, all fixed: invalid wings using up the trial
budget, a resumed seeded study replaying its proposals, and the sampler
learning nothing from runs that never settle.

**Acceptance: the 30P30N three-element high-lift section.** Geometry from
the UIUC database (30p-30n.dat: slat and flap at 30°, flap gap 1.27%), Re 9
million on the stowed chord, Spalart–Allmaras, JST, the default medium
settings: about 175,000 cells (the narrow flap gap caps the wall layers, so
y+ = 1 at Re 9 million takes 40 of them), roughly an hour a point on 4 cores.
The experiment is McDonnell Douglas's, as plotted in Klausmeyer and Lin, NASA
TM 112858, Figure 3 (Geometry A, Re 9 million, Mach 0.2); the values below
are read off that plot, so they are good to about ±0.05:

| α | Cl | Experiment (read off the plot) | Difference |
| --- | --- | --- | --- |
| 0° | 2.269 | about 2.2 | +3% |
| 8° | 3.251 | about 3.2 | +1.6% |
| 16° | 3.998 | about 3.95 | +1.2% |
| 21° | not converged (Cl swinging about 3.1) | about 4.3 (near maximum lift) | |

Before stall the lift curve is within 3% of the experiment, a little high
throughout, as the RANS codes in the NASA challenge were too (and the
experiment's Mach 0.2 would lower incompressible lift by about 2% more). At
21° the run separates and never settles: it is flagged, not reported. Two
likely reasons: starting from freestream at 21° can lock RANS onto a stalled
solution (the usual remedy is to start from the 16° solution), and the slat
and main-element wakes may need longer or finer refinement at high angles.
Maximum lift of a high-lift section is beyond this set-up for now; for an FS
wing, which works below its stall, the attached range is what matters.

**Review of Phase 4 (Dominic).** The flow-zoned SU2 mesh stands in for the
trimmed/polyhedral split: accuracy is what matters, not the cell shape.
Single-element drag reading 5–15% high is acceptable for now. Starting
high-angle runs from a lower-angle solution is not built: it would help a
single wing swept towards stall, not the optimiser (each trial has its own
mesh, so there is no neighbouring solution to start from), and an FS wing
works below stall. If polars to maximum lift are wanted, it is a small
addition (restart SU2 from the previous angle's solution on the same mesh).

**A quick mesh level, about 1½ minutes for a multi-element wing.** Asked
for: a multi-element run in about two minutes. Measured on the two-element
starter wing (NACA 4412 main and flap, 15 m/s, Spalart–Allmaras, 4 cores):

| Level | Time | Cells | Cl | Cd |
| --- | --- | --- | --- | --- |
| quick | 97 s | 31,240 | −1.8891 | 0.03668 |
| coarse | 206 s | 31,240 | −1.8882 | 0.03671 |
| medium (default) | 401 s | 55,710 | −1.8834 | 0.03629 |

Quick uses the coarse cells but a looser convergence test (lift and drag
still to 0.1% over 100 iterations, the residual down 3 orders), which halves
the iterations; it lands within 0.3% of medium on lift and 1.1% on drag. A
coarser quick mesh tried first took 75 s but read lift 1.7% high, so the time
is better spent on cells than saved. The 97 s includes sampling the flow
field for the app.

**The flow field view.** The engine resamples SU2's solution onto a
640-wide grid around the wing, linearly on SU2's own cells (its quads split
into triangles), so values are never interpolated across an element or a
slot, and blanks the inside of each element. It holds Cp, speed over the
free stream, total pressure Cp0 = Cp + (V/V∞)² − 1 (incompressible; zero in
the free stream, negative where energy is lost) and the eddy viscosity
ratio, plus streamlines seeded upstream and just behind each trailing edge,
traced both ways so slot flow and any recirculation show. About 5 seconds a
run, 3 to 4 MB per run.

**Quick estimate sweeps: about three angles in 5 minutes.** Asked for:
estimates on multiple elements in at most 5 minutes. The sweep meshes once
(wakes aligned with the middle angle), runs the middle angle from rest, then
the others alternately above and below, each started from its neighbour's
solution, and caps every angle's iterations by the time left, so it never
runs past the limit. On the two-element starter wing (quick mesh, 31,240
cells, 4 cores): 0° from rest 118 s (with meshing), 2° from 0° 59 s, 4° from
2° 66 s; the restarted 2° matched a fresh 2° run to 0.05% in Cl. Five angles
would take about 6 minutes, so the default sweep is −2° to 2°; wider sweeps
run what fits and list the rest. SU2 aborted ("buffer overflow detected") on
a restart named by its absolute path, so the solution is copied into the
run's folder as start.dat first.

**Side profiles in the Flow Field Viewer.** Slices can be cut across the
sweep (as captured), lengthways and upright (side profile), or lengthways
and level (from above). Lengthways cuts have no video frame to compare
with, and the sweep axis can be unevenly spaced, so along it the image is
resampled evenly (nearest plane) to keep lengths true. A Side Profile
button turns the camera to the side and shows the lengthways cut.

**Video timing is shared between app and engine.** The app has always
picked frame i as whatever shows at (i + 1/2) / fps, using the video's
reported frame rate, while the engine counted frames as they decoded. Those
agree only when the reported rate is right and constant. The calibration
now carries the frame rate and frame count the app used, and the engine
picks frames by time the same way, so both always mean the same frame. The
rate and length can be typed in for a video that reports them wrong; frame
numbers then follow the typed timing.

**The quick estimate takes seconds: panel method plus NeuralFoil.** Asked
for: quick estimates in seconds, not minutes. No RANS run gets there, so
the quick estimate is a different method. The multi-element panel method
gives the lift each element carries in place; the angle at which that
element alone (same shape and place) carries the same lift is its effective
angle; NeuralFoil at that angle and the element's Reynolds number gives its
viscous lift, drag and moment. An element with another behind it has its
trailing edge unloaded by that element (the dumping effect), so it carries
more lift in place than it could alone: its lift is its in-place inviscid
lift scaled by NeuralFoil's viscous loss in the linear part of its lift
curve (6° short of stall onset, which is 4° short of maximum lift), and its
drag is NeuralFoil's at the effective angle or the stall onset, whichever is
lower. The last element can stall. Drag is the sum of the profile drags (the
elements' inviscid x-forces cancel between them).

Validated against RANS (medium mesh, SA) on the 22 converged trials of the
two-element overnight study, flap 17° to 28°, gap 8 to 21 mm: lift within
1% up to a 26.5° flap, 2.2% mean error, rising to 11% at 28° where the flap
starts to separate in RANS and the estimate cannot see it; drag 2% to 26%
high, 11% mean; it ranks drag almost perfectly (rank correlation 0.985) and
lift less well near the limit. The scale factor's angle was chosen on this
same data, so it was also checked on the 30P30N (three elements, slat, Re 9
million), which it does not do well: lift within 5% of RANS at 0°, but 13%
high at 8° and 32% at 16°, with NeuralFoil flagging low confidence on the
slat and the cove. So it is described as for main-and-flap wings, not slats,
and the app shows NeuralFoil's low-confidence flag. Two elements at 19
angles take under a second once NeuralFoil is loaded; a job is a few
seconds.

**Deleting sections.** Elements come off the wing with the Delete key or a
right click. Sections imported into My Airfoils can be deleted (the file and
its index row); built-in NACA and UIUC sections come back whenever the index
is rebuilt, so those can be hidden instead (kept per Mac, like favourites).

**The optimiser runs on the quick estimate by default; RANS is optional.**
Asked for: optimise with the quick estimate, the CFD run optional for
accuracy. Each trial is now a quick estimate (a fraction of a second; 200
trials took 30 s with start-up) unless the study is set to RANS, and after
an estimate study the best few designs (distinct ones) can be run with RANS,
recorded beside them, with RANS's pick shown.

A last element past its stall angle counts as separating (failed, and the
sampler steers away, as with a RANS run that never settles), with a 2°
margin. Without the margin the estimate's optimum sat on the line at a 29.4°
flap, where RANS had not settled. With it, on the overnight problem (flap
15–45°, gap 6–25 mm) the estimate picked a 27.4° flap and a 15 mm gap; RANS
nearby gives about 1.87, against RANS's own optimum of 1.977 at 26.9° and
9.1 mm. The estimate barely sees the gap: RANS gains 6% closing it from
14.6 to 9.1 mm at the same flap angle, the estimate 0.3%, because what sets
the best gap is the slot flow re-energising the flap's boundary layer, which
a panel method and single-element boundary layers cannot represent. So the
estimate optimises angles well and gaps and overlaps poorly; the app says so
when a gap or overlap is ticked, and the RANS check or a RANS study is the
answer for those. Studies record their solver and cannot be resumed with
another.

**Real tracks in the Lap Sim.** Asked for: actual tracks. Event layouts for
Formula Student are rarely published; the open ones found are the driverless
trackdrive layouts in AMZ's fssim simulator (MIT licence, ETH Zurich's team,
2019): Formula Student Germany at Hockenheim (309 m) and Italy at Varano (218
m), as left and right cone lines. engine/scripts/make_tracks.py turns them
into centrelines (each left cone's midpoint with its nearest right cone) in
data/tracks, with the licence beside them; they load like an imported CSV
(spline-smoothed). Tightest centreline radii are 3.2 m and 4.2 m, in line
with the rules' 9 m minimum outside hairpin diameter. They are trackdrive
courses, shorter than an endurance lap, so they compare cars rather than
predict event times.

**Wing Lab layout.** The results tabs were squeezed into a fixed 300-point
picker (five tabs did not fit), the numbers columns clipped when the results
pane was short, and the Study tab needed about 640 points side by side. The
picker now takes its own width, number columns scroll, the Study tab stacks
its table over its charts when narrow, and the inspector is at least 320
points wide. The library and the inspector can be hidden from the toolbar
(remembered per Mac). A summary strip across the top of the results shows the
latest preview, estimate and CFD numbers side by side and what the wing adds
to the car (from CFD when it converged, else the estimate). A study's
time-lapse plays its trials back in the order they ran, each trial's wing on
the canvas over a dashed outline of the drawn wing, with the charts filled in
up to that trial; a click on the canvas ends it.

## Backlog picks

Dominic's picks from the improvement list, with his note that AeroBench is a
lightweight sanity check before hours in STAR-CCM+, not an industry tool. So
each item is the smallest thing that does the job.

**Multi-core SU2 from the app.** An app opened from Finder gets a bare PATH
(/usr/bin:/bin:/usr/sbin:/sbin), so the engine never found Homebrew's
mpirun and every CFD run from the app used one core even with Open MPI
installed. The engine's PATH now has /opt/homebrew/bin and /usr/local/bin
appended (anything already on it wins). The SU2 installer also installs
Open MPI with Homebrew when mpicc is missing; AEROBENCH_NO_MPI skips that.

**Polars through stall.** The quick sweep (5 minutes, middle angle first,
alternating outwards) suits a few angles around the design point. Near
maximum lift a run started from rest often never settles, so a second sweep
order runs the lowest angle from rest and each next angle from the solution
of the one below, on the chosen mesh, with no time limit.

**Slice export, gain map, accuracy page.** The flow viewer saves the slice on
show as a PNG with a scale bar and the Cp0 colour bar. The Lap Sim already
plotted speed for A and B and the time delta along the lap; what it lacked
was where on the track the time goes, so a track map is coloured by the
slope of the delta (smoothed over about 5 m, colour range from the 95th
percentile so one spike does not wash out the rest). Help → How Accurate Is
Each Solver? puts the validation numbers in the app.

**Live estimates (a warm engine).** Every engine job is a fresh Python
process, and loading NeuralFoil takes 5 to 7 s, while the estimate itself
then takes about 30 ms for 19 angles. `aeroengine serve` stays running and
answers JSON-lines requests on stdin (only the estimate for now), and the
app keeps one when *Live while editing* is on, sending at most one request
at a time and the latest wing when it returns, so a drag is followed at
about 30 updates a second. A request-reply process was preferred to a
local HTTP server: nothing listens on a port, and it exits by itself when
the app goes away and its stdin closes.

**Compare, report, library polars.** Compare pins a design as A with the
results it had and draws it dashed beside the wing being edited; there is no
second editable wing, which keeps the model to one wing plus a snapshot.
The report is one A4 PDF drawn by SwiftUI (ImageRenderer), not an HTML or
LaTeX pipeline. Library polars were asked for as precomputed at Formula
Student Reynolds numbers; NeuralFoil takes about 2 ms a section, so instead
of fixed tables the whole library is computed on demand at the main
element's Reynolds number, and a note turns orange when the wing has moved
more than 20% away from it.

**Flow probe, car in the field, section cut.** The probe reads the nearest
voxel rather than interpolating: the volume is already resampled from video
pixels, so interpolation would suggest more precision than there is. The car
in the flow viewer is the CAD Viewer's model as loaded, in its own
coordinates, with a manual offset; no automatic registration, because when
STAR used the CAD frame there is nothing to register. The section cut runs
on the CPU over the tessellated triangles (put in world space once, then
each plane position is one pass) and is drawn as a flat 2D outline, rather
than clipping the 3D view with a shader: the flat view is what shows a wing
or floor profile, and it can be tested.

**A disk image, not a frozen engine.** The engine's environment is several
hundred MB of compiled packages (gmsh, VTK, OpenCascade, OpenCV,
NeuralFoil, Optuna), and a uv virtualenv is not relocatable, so it is not
shipped inside the app. The app carries the engine's source and lock file,
copies them to Application Support on first launch and runs `uv sync
--frozen` there; the app bundle is never written to, so its signature holds.
Updates keep the environment, the airfoil library and SU2. Signing is ad hoc
by default; a Developer ID signature and notarisation need Dominic's Apple
account, so the script takes an identity rather than assuming one.

**The estimate and the gap.** Against the 27 distinct RANS trials of the
overnight study, the estimate's lift error is not a function of gap: it is
within about 1% everywhere except where RANS's flap separated (a steep flap
with a wide gap, -7% and -11.5%), and the trial where the estimate was low
(+3.8%) had the narrowest gap and the steepest attached flap. What the gap
changes is where the flap separates. So the separation line moves with the
gap: 1.5 degrees further out per 1% of the front element's chord the gap is
below 4.75%, held at the ends of the fitted range (2.6 to 6.9%). It splits
all 27 trials the same way RANS did, including the 8 that never settled,
and any gain from 1.0 to 3.0 degrees per 1% would too. On the overnight
problem the estimate optimiser now picks a 27.7 degree flap and a 12 mm gap
on three seeds (before: 27.4 degrees and 15 mm). RANS at that design gives
Cl 1.891, against about 1.87 for the old pick and 1.977 for RANS's own best
(26.9 degrees, 9.1 mm): from 5.4% short to 4.4% short. The rest is the lift
a well-set slot adds before anything separates, which the estimate still
does not model. It is fitted on one main-and-flap wing, so it is a better
default, not a validated slot model. (Replaced by the flap's deflection, see
"Flap separation by deflection": scored again later, this line marked two of
the overnight study's attached trials separating.)

**Shape variables.** Phase 5 in the spec asks for about 12 shape parameters
per element. For a quick check two were judged enough: camber added as a
parabola (zero at both ends, so the chord, leading edge and gap geometry
stay put) and a thickness scale about the camber line, whose lower bound
doubles as the spar-box limit. Both are applied before angles and gaps, so
the slot is set on the reshaped section. Trials store only the two numbers;
the app reshapes the section itself with the same formula
(Airfoil.reshaped) to draw a trial or apply it.

**sage37, lightly.** The tools are dense working screens (canvas,
inspector, charts), so the full sage37 treatment (refracting glass panes
over a bloom, the dock, Fraunces titles) was left out as more than a quick
check needs. What came across: the app is dark, sage is the accent (sidebar
selection, toggles, sliders, charts' default series), the sidebar is a solid
surface column, and the primary action in each panel is sage37's prominent
capsule button. Colours, radii and the press spring are the design system's
tokens (app/AeroBench/Sage37.swift). The glassout console for SU2 and
optimiser output is not built; the Jobs log stays a plain list.

**Shape trials are relative to the study's starting sections.** The first
version applied a trial's camber and thickness to whatever section was on
the canvas, so loading trials one after another (clicking rows, Load It,
Load Best, the time-lapse) reshaped the reshaped section each time: the
names stacked and the sections drifted out of shape. A shape study now
records the sections it started from (base_sections in the export) and the
app always reshapes from those; for studies from before that, from the
section as it is in the library.

**The estimate past a front element's stall.** The first design run showed
the estimate optimiser's favourite was badly separated in RANS (Cd 0.71):
it had pushed the main element 23 degrees past its own stall angle, because
an element with a flap behind it was credited with all its in-place lift and
never checked for separation. A RANS sweep of the NACA 6212 starting wing
through stall (0 to -9 degrees) showed the slot keeps the main attached well
past its own stall (8 degrees past with lift exact, 12 past with lift 7%
over) until it separates (15.6 past). The estimate now caps a front
element's lift 9 degrees past its stall angle, counts it as separating 13
past, and grows its drag with the square of how far past stall onset it is
(0.0087 per degree squared; held at onset the drag was 30 to 60% low). On
that sweep lift is within 1.5% and drag within 4% at every attached angle,
and -9 is flagged; the overnight 4412 study is still split 27 of 27 as RANS
did, lift 0.8% off on average, drag now 16% high there (a per-section
offset the design run's calibration removes).

**Designing a wing in a few minutes.** Quick methods do the search, RANS
confirms. The engine ranks the library by NeuralFoil's maximum lift at the
main element's Reynolds number and lays the best few out as a standard
wing; an estimate study of 150 trials tunes it (under a minute: the first
timed run was within 0.005 s a lap of its 300-trial best by trial 50); RANS
on the quick mesh checks the best. If that separates, the next best design
at least 5% of some variable's range away from it is checked (the top of a
converged study is one design many times over: the first timed run spent
two 5-minute RANS runs on two copies of one separated wing), and checking
stops at the first design RANS confirms.

The first version also ran one RANS run of the starting wing alongside the
estimate study to calibrate its lift and drag. It came out 1.012 and 1.001
on the NACA 6212 wing, and with the top of the study that flat it could not
change which design was checked, so a design run no longer waits for it (a
minute on 4 cores); `anchor` stays in the engine for scripted studies.

Timed on 4 cores, fastest lap on the generated endurance track: 52 s of
estimates, then 5½ minutes for one RANS check, which converged with the lap
0.02 s slower than the estimate's (lift 2.6% under, drag 0.6% over); 55.76 s
against 55.84 s for the starting wing. That is over the 3 to 5 minutes
aimed for on this machine; the RANS check is nearly all of it and scales
with cores.

**Flap separation by deflection.** The timed runs kept choosing wings RANS
could not settle: first with the flap's nose pulled behind the main's
trailing edge (overlap -2 mm; every slot the estimate had been fitted on
overlapped by 29 mm, so the design search now keeps every overlap at 2 mm or
more), then with the overlap positive but the flap 42 degrees past the main.
The estimate had both attached: with the main free to move, a heavily
loaded main's downwash keeps the flap's effective angle low in the panel
method (12 to 13 degrees there), while in RANS the flap is recovering
pressure in the main's wake and separates. Scored against all 34 RANS
verdicts so far (the overnight study, the 6212 sweep, the design checks),
the deflection, the flap's chord line against the main's, splits them: the
overnight wing held to 25.2 degrees and separated from 26.0 whatever the
gap, the 6212 wing held at 22 and separated at 42 to 47. Neither the gap
line nor a Valarezo-Chin peak-to-trailing-edge pressure difference (tried
on the panel solution) split them. So an element turned more than 25
degrees past the one in front now counts as separating; the estimate gets
33 of 34, the miss being the 25.2 degree trial, on the safe side. It is
fitted on two wings and says nothing about how the limit moves with gap or
section; RANS checks the pick.

**Lap Sim tracks and load transfer.** Generated tracks keep to the 2027
rulebook's layout limits, read from the rulebook into
data/rules/fs2027_tracks.json. Load transfer and tyre load sensitivity are
off (zero) for projects from before them so their results do not move.

**Ground effect against RANS.** The quick methods put the ground in as an
image wing; RANS as a slip wall along the flow under the wing. On the NACA
6212 starting wing (quick mesh, SA, 15 m/s) RANS gave Cl -2.83 at 300 mm
ride height and -3.48 at 150 mm against -2.17 in free air, and never
settled at 60 mm (Cd 0.21 and still moving: the main separating). The
estimate's gain over free air was 42% and 77% against RANS's 30% and 61%,
so it keeps GROUND_LIFT = 0.75 of the gain on every element (0.73 and 0.78
measured): lift within 0.5% and 2.9%, drag 9% high and 2% low. At 60 mm the
main element is 16 degrees past its stall angle in place and the estimate
calls it separating, as RANS did. The drag needed nothing: the estimate's
ratio over free air was already RANS's. One wing, two heights; the live
panel preview still shows the image's whole gain.

**A dock, not a sidebar.** The tools sat in a sidebar column that took
200 points of width from every screen to hold six labels. They are now a
dock across the top (project, Wing Lab, Lap Sim, CAD Viewer, Flow Field,
Jobs with its running count), the selected one in sage, ⌘1 to ⌘6 to switch,
the choice kept per window. The canvas and charts get the width back.

**The flow field on the canvas.** The RANS field (Cp, speed, Cp0, eddy
viscosity over the plane) had its own results tab, a second picture of the
wing beside the one being edited. It is now drawn on the canvas behind the
wing, as STAR-CCM+ draws a scalar scene on a plane section, with the scalar,
streamlines and colour bar picked there and the value read under the
pointer. Over a ground the engine meshes the wing turned by minus its angle;
the run now records that turn (frame_turn) and the field is turned back into
the wing's frame. A field is only drawn while every element still matches
the run's surface within a millimetre: an edited wing never sits on an old
flow, which would be worse than no picture. The results tab keeps the
surface Cp.

**One optimiser, every variable.** Designing a wing had its own toolbar
button and sheet beside the Optimise section, two ways into one study. It
is now one section: *From scratch* has the engine lay out a starting wing
and fills in the set-up (nothing runs until Start Study, so it can be
changed first); *This wing* is a grid of what to search, a row per element:
section, chord, angle, gap, overlap, camber, thickness. Sections are chosen
from a shortlist per element, ranked by maximum lift at that element's own
Reynolds number (a flap runs slower than the main, so its ranking differs);
in Optuna a section is a categorical choice by index, not a number on a
scale, so TPE does not assume neighbouring sections are alike. A chord
grows from the leading edge with the slots behind kept. With chords
searched, coefficients go on the starting wing's total chord (else a bigger
wing would read as the same Cl and the fastest-lap objective would turn it
into the wrong ClA). Defaults are the safe ones (ranges a box starts with,
about 25 estimate trials a variable, checks that stop at the first RANS
confirms); exact ranges, sampler and study name sit under Advanced.

**The quick methods against public wind-tunnel data.** Until now every
correction in the estimate was fitted to this project's own RANS runs. The
validation suite (aeroengine validate; engine/src/aeroengine/validation.py)
runs the viscous core, NeuralFoil at the measured angles (for a single
element that is the whole estimate), against published measurements. Lift
is scored over the attached range (to 2 degrees short of the measured
maximum lift), as a fraction of the measured lift, with |Cl| below 0.4
scored against 0.4 so a near-zero miss is not infinite; drag over the same
range.

Sources, public only: NACA 0012 at Re 6 million, tripped (Ladson, NASA
TM-4074, 1988, as the NASA Turbulence Modeling Resource tabulates it; public
domain, in data/validation); and the University of Illinois low-speed tests,
volumes 1 to 3 (Selig et al., Summary of Low-Speed Airfoil Data, SoarTech
1995 onwards), every clean run at Re 150,000 to 520,000 with the model's
as-built coordinates where given. The UIUC data come with the GNU GPL and
the authors' terms, so they are fetched from the source on first use and
not committed. Searched for and not reachable: NLR 7301 main and flap (on
the ECARP CD-ROM only), Zerihan and Zhang's ground-effect wings
(Southampton's server sits behind a bot check), AGARD AR-303 (timed out).

Results: NACA 0012 lift 4.6% and drag 2.5%. Over 171 UIUC runs on 52
sections, lift's median error is 7.9% (17% of runs within 5%, 69% within
10%) and drag's 8.1% (84% within 15%). The lift error is nearly always high,
and grows with camber: about 5% on E387 and SD7062, 10% on S1210, 15 to 21%
on S1223 and E423. E387's drag is the worst (28 to 37%: its laminar
separation bubble).

A correction tried, not applied: the estimate's lift times 0.94, fitted on
all the runs, halves the error on sections left out of the fit (median
4.8%, 53% within 5%, 85% within 10%); adding camber or Reynolds number
barely helps across the board, and S1223 stays 11 to 15% off (its lift
slope is off as well as its level). It is not applied because it would pull
the estimate away from RANS, which it now matches on the starting wing
within 1.5% (and RANS read the 30P30N 1 to 3% high against experiment): the
estimate would then read under RANS, and likely under STAR-CCM+.
Dominic's call: match STAR. The estimate stays calibrated to RANS, and the
tunnel cases record how far both sit from measurement. The suite now holds
the estimate to the SU2 reference runs as well (against_rans: the starting
wing at 0 to -9 degrees, over a ground at 300, 150 and 60 mm, and the timed
design run's check): lift within 2.8% wherever RANS converged, drag within
9.1%, and both runs RANS never settled called separating.

**SA or SST.** The estimate's corrections were fitted to SU2 with
Spalart-Allmaras; STAR-CCM+ set-ups for FS wings more often run k-omega
SST. On the starting wing (quick mesh, 0 degrees) SST gives Cl -2.106 and Cd
0.0345 against SA's -2.168 and 0.0347: 2.9% less lift, the same drag. The
estimate (-2.143) sits between them, 1.8% above SST and 1.2% below SA, so
at attached angles either model is matched within the 5%. Near stall SST
usually separates earlier than SA; the separation rules were fitted on SA
runs, so a design the estimate passes close to its limits is worth an SST
check.

## Drawn tracks and five-element wings

**Track editor.** Asked for: custom Lap Sim tracks drawn with Bézier curves
(noted under Ideas for later). Dominic's calls: a track starts as a copy of
an existing one (generated, FSG, FSI, test track, skidpad, acceleration or
the imported CSV), not a blank canvas or a traced image; a track that breaks
the layout rules is highlighted but still runs.

The engine takes a new track kind, `{"points": {"x": [...], "y": [...]},
"closed": ...}`, fitted like a CSV with no smoothing, so the solver is
unchanged. The warm engine (serve) answers `lapsim-track` with any track's
centreline in milliseconds, which the editor fits in Swift
(AeroBenchKit/DrawnTrack.swift). Each node has two handles kept in line, so
the line never kinks, with their own lengths. Nodes go every 25 m of
straight or 35 degrees of turn (turning either way counts, or S-bends
flatten), handle lengths by least squares through the points between
(Schneider's curve fitting, Graphics Gems 1990), and any segment more than
0.1 m off the line is split. Checked by lap time: a copy laps within 1% of
the generated endurance and autocross layouts and 1.4% of FSG, which is the
FSG line's own noise (its lap moves 21.76 to 22.37 s between 0.03 and 0.08
m of CSV smoothing; the copy lands on the 0.08 m figure). An earlier fit
with arc-rule handles and no refinement ran 2 to 8% fast.

Rule checks: a turn is too tight under a 3.0 m centreline radius, the 9 m
outside hairpin diameter (FS D 7.1.1, D 6.1.1) less half the 3 m minimum
width, as the FSG and FSI notes above read it. Checking 4.5 m on the
centreline, as the generator does, flagged FSG's legal hairpins. Straights
count as flatter than 150 m radius, as in the generator, and break the rule
over 80 m. The drawn track is saved in lapsim/setup.json and kept when
another track is picked.

**Five-element wings from scratch.** Asked for: up to 5 elements when
setting up a wing from scratch (was 2 or 3). Chord shares fall along the
wing (0.55 to 0.18 for 3, 0.46 to 0.13 for 4, 0.40 to 0.10 for 5).

**The estimate against RANS on 3 to 5 elements.** Checked after adding 4
and 5: SU2, SA, quick mesh, 15 m/s, NACA 6212 on every element, 0.44 m
total chord, free air at 0 degrees, with reverse flow measured within 4 mm
of each element. The first layouts (each flap 14 to 20 degrees steeper than
the one in front, the last 38 to 54 past the main) all separated their last
flaps, and so did the 3-element start the app had shipped (2, 20, 40): RANS
Cl -1.69 and Cd 0.071 there, the estimate -2.33, 38% high on lift. Every
element read high, the main most in absolute terms: two or more flaps load
it to 27 degrees in place, and the rule that holds a front element up past
stall was fitted on main and flap only.

What splits them is how far the last flap is turned past the main, not past
the one in front. Last flap 24 degrees past the main: attached on 3, 4 and
5 elements, the estimate 3% low, 7% low and 2% high. 30 degrees on 4
elements (10-degree steps): Cl fell from -1.77 to -1.41, the estimate 27%
high. 32 on 3 elements: the last flap separated, Cl -1.19, the estimate 65%
high. Laying the main flatter to keep it below stall made things worse (main
at -6 and -10: Cl -1.13 to -0.74, the estimate 29 to 87% high). On 5
elements with 8-degree steps the limit sits higher: 28 and 30 degrees past
the main held (Cl -1.54 and -1.67, the last flap fading) with the estimate
9 to 10% high.

So the estimate now also calls a flap separating when it is more than
MAX_DEFLECTION, 25 degrees, past the main (two elements: unchanged, and the
2-element RANS references still agree within 2.8% on lift). It is cautious
on 5 elements with small steps, where 28 to 30 degrees held; a limit that
grows as the steps shrink would need more runs. The starting layouts put
the last flap 24 degrees past the main with the main at -2: (-2, 10, 22),
(-2, 6, 14, 22) and (-2, 4, 10, 16, 22), RANS Cl -1.78, -1.77 and -1.50 at
Cd 0.027 to 0.029. The new 3-element start gives more lift than the old one
at less than half the drag. The design search's flap ranges were moved to
hold these starts. Still unchecked on 3 to 5 elements: other angles of
attack, a ground, and sections other than NACA 6212; a study's RANS
calibration of the starting wing and its closing RANS checks cover a
design, as before.

## Ideas for later

Not built yet; noted so they are not lost.

**Generated layouts at the real hairpin limit.** The generator keeps the
centreline radius over 4.5 m, but the rule is a 9 m outside diameter, about
3 m on the centreline (see Drawn tracks). Generated layouts are therefore
more open than the rules allow, which may be part of why they come out more
open than FSG and FSI. Fixing it changes every seed's layout, so it wants a
version on the rules file or a new seed range.

**More RANS on 3 to 5 elements.** Free air at 0 degrees with NACA 6212 is
all that was checked (see the estimate against RANS on 3 to 5 elements):
sweep the angle, add a ground, try the library's high-lift sections, and
find how the past-the-main limit grows as flap steps shrink.

**Racing line inside the track width.** The Lap Sim drives the centreline.
A minimum-curvature line within the 3 m (or drawn) width would give lap
times nearer a driver's and change how much downforce is worth in slow
corners. Track width per node would go on the drawn track first.

**Logged laps against the sim.** Import a data-logger or GPS lap (time,
speed, position), lay its speed trace over the sim's on the same distance,
and fit grip and ClA to it. This is the step that turns the sim from
comparing cars into predicting them.

**Cones out of a drawn track.** Export left and right cone positions at the
rules' spacing (CSV, and a printable plan with distances) so a team can set
the drawn layout out on a car park for a test day.

**Self-crossing and several tracks.** The editor does not yet warn when a
line crosses itself (the generator's crossing check could be reused), and a
project holds one drawn track; a named list would let a team keep a few
test-day layouts.

**Tracing over an image.** Offered and not picked for now: load a site plan
or satellite picture under the editor, set its scale with two points, and
draw over it.

**sage37 in full, leaning toward glassout.** This replaces "sage37,
lightly". The window is the airfoil bloom over glassout's phosphor dot grid,
bent by sage37's refraction shader under a clear glass pane per working
region (forms, canvas, 3D views, charts). Each tool has a mono-caps meta
line, its title in Fraunces (bundled, OFL) and a one-line note; the project
is a glass capsule on the right (⌘1). The tool switcher is a frosted dock
along the bottom in glassout's dress: mono caps labels, the current tool in
inverse-video sage, sage37's press-and-slide lens. The lean toward glassout
is deliberate, to set AeroBench apart from Pit Wall, which shares sage37.
Machine output is glassout consoles: a job's log in Jobs, and STAR's prism
settings in Prism Layer, where the near-wall thickness is the spotlight.
System colours became tokens: warnings clay, errors critical, success and
running sage, the pinned design A slate, non-converged chart points rust,
chart series the sage37 palette. Left as they were: the A4 wing report (a
light document), overlays drawn on flow video frames, the x/y/z axis
colours, and system controls inside forms (toggles, pickers, fields), which
take sage as their tint rather than custom sage37 controls. The window's
minimum height went from 560 to 680 to fit the header and dock round Wing
Lab's panes.

**A faint space-filling curve per tool, and Prism Layer answer-first.**
The dot grid and the shared airfoil bloom competed with the panes, so each
tool now has its own space-filling curve, run edge to edge in bone at 7%
with turns about 18 points apart, cross-faded on a tool switch: Hilbert
(Project), Sierpiński arrowhead (Wing Lab), Moore, a closed loop like a
circuit (Lap Sim), Peano (CAD), Gosper's flowsnake (Flow Field), the
Sierpiński square curve (Prism Layer) and the Heighway dragon (Jobs). A
first pass with a picture per tool (streamlines, contour lines, a floor
grid) was dropped as too busy. Prism Layer now leads
with its answer: the live result is the header's takeaway, then the
near-wall spotlight beside a strip of layers, total and Reynolds, then the
inputs beside STAR's console. The console takes the wider column, against
sage37's rule, because STAR's names have to stay whole. Spec and plan:
docs/superpowers/specs/2026-11-02-backdrop-prism-design.md,
docs/superpowers/plans/2026-11-02-backdrop-prism.md.

**STEP repair to one closed body.** A CAD Viewer section turns a STEP file
into one closed body for STAR-CCM+, which splits it into regions afterwards.
Gaps inside a part are sorted into three bands: up to the automatic limit
(0.5 mm by default, a setting) they are fixed without asking, by sewing at
the smallest step that closes them; from there to 10 mm they wait in a
queue for accept or skip; wider ones are only reported. 10 mm is about a
wing slot gap, so a slot is never closed without the user saying so. Gaps
between parts are never touched. Cleanup of tiny edges and sliver faces and
the fuse's fuzzy value use 0.01 mm, never the gap limit, so trailing edges
and lips a few tenths of a mm thick survive and parts that nearly touch are
not merged. An accepted gap is closed with a ruled strip between its two
edges rather than by sewing wider, so only that gap changes. Apply always
writes the file; a part that cannot be closed goes in as an open shell and
the result says so. Decisions are saved beside the source as
`<name>.repair.json` and matched on kind, part and a 3 mm radius, so the
next revision needs almost no clicking. Spec and plan:
docs/superpowers/specs/2026-11-03-step-repair-design.md,
docs/superpowers/plans/2026-11-03-step-repair.md.

**Edit Part: a feature list on an imported STEP part.** The CAD Viewer's
Edit Part mode edits one solid part with the GSD-style edits the user makes
in CATIA: points clicked on the part, splines through them, planes parallel
to a reference through a point, extrudes along a plane's normal, fills held
tangent to the part's faces along its edges, Add (new surfaces closed into a
volume and fused on, the user's way of adding material), fillets, chamfers
and push/pull on flat faces. The app owns the list as plain data and sends
all of it to a warm engine on every change; the engine rebuilds from the
first changed feature (each state cached) and returns the mesh with every
face and edge labelled by where it came from, so clicks become references.
The imported part never changes, so its faces and edges are referenced by
their place in a fixed order and followed through each operation's
history; a reference that ends as nothing or several pieces is "lost" and
picked again, never guessed. Clicked points are stored as positions and
projected onto their edge or face on each rebuild. The list is saved beside
the STEP with the STEP's fingerprint; a re-exported STEP marks every part
reference lost. The part is edited and saved in its own frame, alone, as
`<part>_edited.step`. Push/pull is flat faces only for now. Spec and plan:
docs/superpowers/specs/2026-11-03-gsd-editor-design.md,
docs/superpowers/plans/2026-11-03-gsd-editor.md.

**Car tool: modular front and rear wings on the base car.** Wing Lab wings
are saved as cards (front or rear, with their own ClA and CdA) and placed on
the base car from its STEP, by dragging on the side view or typing the
leading edge's distance from its axle and its height, never outside the FS
rules box worked out from the wheels, the ground and a marked head
restraint. A combination is judged two ways. Quick: the bare car's numbers
plus each card's, each wing's downforce at its quarter chord for the axle
split, re-estimated when placed off its own height. Full: the car cut into
strips across half its width (sines-spaced, finer outside), each section
meshed with the wings fused into it (a front wing may run through the nose)
and solved in SU2: a high-y+ mesh on the body and wheels, quad layers
for y+ 1 on the wings, the ground moving and the wheels rolling if asked;
each wing's share is 3D-corrected as Wing Lab does, and a full run uses the
bare-car baseline's mesh. Booleans are done in OCP and meshing in gmsh's
built-in kernel, because gmsh's own OpenCascade kernel crashes in a process
that has loaded OCP. Car cases use FDS upwind (JST drifted on a bluff body)
and a looser convergence test (2 orders, 0.5 % over 500 iterations). The
body and wheels keep the high-y+ mesh but are plain no-slip walls, not wall
functions: SU2 8.5's wall functions put k near 1e5 on wall nodes at the real
car's sharp corners and SST ran away (CD 7 to 18 per metre at the
centreline, fixed or moving ground), and on a rotating wheel gave NaN.
Without them the centreline settles with the ground moving or fixed, so
the ground moves by default again. The gap under the floor gets a set
number of cells across it (8 coarse, 12 medium, 16 maxed): at the wall size
the centreline's 34 mm gap had 3, the moving ground dragged a Couette
profile through it and pumped the floor to Cp +1.5 (CL +1.8 per metre).
Drag holds within 2 % from 4 to 20 cells (CD 0.82 to 0.84 moving, 0.48 to
0.51 fixed); lift moved with the mesh (centreline CL +0.2 coarse, -0.35
medium). The cause was the ground, not the gap: as a no-slip wall on cells
up to a metre tall ahead of the car it set the air near it by the cell
size (fixed: still air 0.5 m deep from the inlet; moving: pumped to 1.4 to
2.2 times the free stream's total pressure under the nose, which fed the
floor), and the domain's edges were cut at the wall size, which left
slivers on the ground whose pressure swung by q from node to node. Now the
domain's edges are not cut, the ground is split at the car's ends, the
ground beyond them ("road") is slip, and a ground moving at the air's
speed is slip under the car too: centreline CL -0.56 coarse, -0.61
medium, about -0.69 maxed (it oscillates between -0.57 and -0.76 and does
not settle: the finer wake sheds), CD 0.90, 0.90, 0.92. Slip leaves out
the air the moving ground drags into the gap; resolving that needs y+ 1
layers on the ground (a session tried them: about 3 times the run time).
A fixed ground, or one at another speed, stays no-slip under the car and
its lift still follows the mesh (fixed: CL +0.58 coarse, +0.18 medium).
Neither a slope limiter (Venkatakrishnan: CL +1.24 coarse, did not
converge) nor a velocity inlet and pressure outlet changed this. The axle split
comes from the moment about the ground line, so drag above the ground counts.
Rear-wheel drive: Lap Sim's driven-axle balance is the rear share. Spec and
plan: docs/superpowers/specs/2026-11-03-car-builder-design.md,
docs/superpowers/plans/2026-11-03-car-builder.md.

**Car tool merged into Wing Lab.** Wing Lab and the Car tool had one goal, a
front and a rear wing that make the car fast, so the Car tool left the dock.
The wing being edited sits on the selected combination live, at its end's
place, as a card made in memory from its best numbers; the stored
combination keeps its card until Save (or Run Full, which saves first). The
canvas has a Wing | Car switch with the side view, the results pane a Car
tab, the inspector a Car section, and the library sidebar the cards. On the
car the wing's height and Wing Lab's ride height are one number, so a drag
turns the ground on and goes through Wing Lab's undo. With a base car,
Wing Lab's rules box is the car's box for the wing's end (exact at a wing
angle of 0), and the Study's fastest-lap goal races the base car with the
other wing, at the combination's balance when the study starts. A first
combination is made the first time a wing goes on the car. Spec and plan:
docs/superpowers/specs/2026-11-04-wing-lab-car-merge-design.md,
docs/superpowers/plans/2026-11-04-wing-lab-car-merge.md.

**Ground effect down to 30 mm.** A study at 30 mm ride height reached Cl -19
to -24 on the estimate: the image method's lift gain grows without limit as
the gap under the wing closes (12 times free air at h/c 0.08), and the fixed
GROUND_LIFT = 0.75 had only been checked at 150 and 300 mm. RANS (quick mesh,
SA, converged) on the NACA 6212 main and flap and a NACA 4412 main alone, 30
to 300 mm, shows the real gain peaking (+72% at h/c 0.33, +60% at 0.18) and
falling (+9% and +47% at 30 mm). The share of the image's gain RANS keeps
falls with that gain on both wings alike, so it is now
0.8 / (1 + (gain / 1.6)^3) of it: every converged point within 0.15 of gain,
and the ground can never add more than about 68%. The study's best wing,
stalled in RANS (Cd 0.36 in free air, 0.51 at 30 mm, Cl -1.81), now reads Cl
-2.48 at 30 mm, and a wing separating in free air separates over the ground
too. The live panel preview keeps the same share of its image's gain. Its
drag stays far too low once separating (0.09 against 0.36), so the canvas now
says "separating: check with RANS" beside the live estimate.

**The Design card.** Wing Lab's design was a chain of trips: a starter
job, a Study, RANS checks, saving a card, the car. The Design card at the
top of the inspector runs one engine job, wing-design, from the rules box
to finalists, and the user picks the final design (Use This Wing puts it on
the canvas, a new card and the car). Every setting is a chip (end, start,
elements, goal, RANS checks); More is the Study's own settings. The wing
fills its box: a from-scratch layout grows until it just fits (it began at
440 mm and only shrank, in a 700 mm front box), chords may grow 60%, and
the wing's place in the box is searched as a share of the room the box
leaves it (fixed positions made most samples break the box). A
from-scratch wing starts halfway up the box: on its floor, a 495 mm main
30 mm off the ground separates in RANS (0.47 times the estimate's lift,
three times its drag) and the search starts lost. Goals are in car terms
through the 3D settings: most ClA, best ClA/CdA (the whole car's with a
base car, the wing's without), fastest lap, ClA under a CdA limit, and an
aero balance within 1% of a target. The estimate shortlists and RANS picks:
a RANS check counts only if it converges and stays attached, judged by skin
friction from flow.vtu (SU2 8.5's surface CSV has none): reversed flow over
more than 15% of an element past its first 5% of chord, where an attached
NACA 4412 main reads 3% and the stalled study wing's main 33%, or a drag
over three times the estimate's. Spec and plan:
docs/superpowers/specs/2026-11-05-wing-design-card-design.md,
docs/superpowers/plans/2026-11-05-wing-design-card.md.
