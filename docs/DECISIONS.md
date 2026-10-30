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
