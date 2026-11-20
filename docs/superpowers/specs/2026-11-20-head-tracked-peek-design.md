# Head-tracked peek for the CAD viewer

2026-11-20. Status: draft for approval.

## Intent

Hold Shift in the CAD viewer and the screen becomes a window onto the model:
the webcam follows your head, and the view changes as if the model sat
behind the glass. Move your head left and you see round the left side of a
flap; move up and you look down into a slot gap. Let go of Shift and the view
returns to where it was.

It starts as something to show people, but the goal is an inspection aid:
judging depth and clearances (flap gaps, overlaps, endplate clearances)
without breaking off to orbit. Research supports that use: in Arthur, Booth
and Ware (1993), head-coupled perspective cut errors on a 3D tracing task
more than stereo did, and people preferred it to stereo.

## What the spike showed

A throwaway web demo (`spikes/head-tracked-view/index.html`, three.js and
MediaPipe) was tried by the user on their MacBook.

- The effect works, but only for one viewer, and it is strongest with one eye
  closed: two eyes see that the screen is flat. On video it looks better than
  in person. This is a physical limit, not a bug.
- **Estimating distance from the webcam broke the illusion.** The distance
  from eye separation swung ±8 cm while the user held still, and a wrong
  webcam field of view put it 70% too far. The scene stretched and shrank.
  **Locking the distance to a measured value fixed it** (user-confirmed).
  Track only sideways and vertical head movement.
- One-time calibration works: the user measures their distance, and the
  webcam's field of view is solved from the eye separation at that distance.
- Detect once per camera frame (about 30 Hz), not per render frame.
- A One Euro filter with about 40 ms of look-ahead removes jitter without
  visible lag.
- Depth cues help (the spike drew a grid box and a floor shadow). The CAD
  viewer does not need these for v1; see "Left to the builder".

## Goals

- Hold Shift in the CAD viewer: head-coupled, off-axis perspective. Release:
  the head offset eases out. Orbit and zoom done during the peek are kept
  (my call: snapping back after a careful orbit would be annoying); there is
  no saved pre-peek camera.
- It must look physically right on a calibrated MacBook. The off-axis
  projection must keep the window plane fixed to the view's edges.
- Orbit (drag) and zoom (scroll) still work while Shift is held. The head
  offset sits on top of the orbit camera, not in it.
- Calibration in Settings: enter your distance, press Calibrate.

## Non-goals

- Stereo, glasses, or headsets.
- Tracking distance (lean in to zoom). Distance stays locked; see the spike.
- More than one viewer at a time.
- The Flow Field viewer. It shares `Viewer3D`, so it can come later.
- iOS.

## Anti-goals (a failure even if it works)

- The view moving at all when Shift is not held.
- The webcam running when the feature is off, or long after the last peek.
- A measurement, pick or edit landing in the wrong place because of a peek.
- A visible jump in the view when Shift is pressed or released.

## Constraints

- macOS app, SceneKit viewer (`SceneKitViewer`, `OrbitCamera`, `OrbitSCNView`
  in `app/AeroBenchKit/Sources/AeroBench3D/`).
- No new dependencies. Use AVFoundation for the camera and Vision for faces
  (`VNDetectFaceLandmarksRequest`: pupils or eye centres). MediaPipe is not
  native on Mac. ARKit face tracking is iOS-only.
- The app is not sandboxed and has no hardened runtime. Camera access needs
  only `INFOPLIST_KEY_NSCameraUsageDescription` in the build settings.
- Shift+drag currently pans (`SceneKitViewer.swift:674`, "shift or option").

## Approaches considered

1. **True window (chosen).** The plane through the orbit target stays pinned
   to the view's edges, the eye moves with the head, and the projection is
   off-axis (Kooima's generalised perspective projection). This is what the
   spike tested and what gives the TikTok effect. It needs perspective.
2. **Orbit nudge.** Head offset turns the camera a few degrees about the
   target, reusing `OrbitCamera.orbit`. Least code, works in orthographic,
   but the screen stops behaving like a window: the model swings instead of
   staying behind the glass.
3. **Both.** Window in perspective, nudge in orthographic. Two behaviours to
   tune.

The user asked for whatever is most realistic, which is 1. In orthographic
view, holding Shift eases into perspective for the peek and back on release
(my call, for realism).

## Decided

### Input
- **Shift held = peek** (user). Pan moves to **Option+drag only** (user).
  Right and middle drag and trackpad scroll still pan. Update any help text
  that mentions Shift to pan.
- Shift+drag while peeking orbits as usual. Scroll zooms as usual.
- Picks, measure clicks and edit clicks are ignored while peeking (my call:
  peek is for looking, and it keeps the anti-goal about measurements safe).
  Hover feedback may be hidden while peeking.

### Geometry (the window)
- The physical window is the viewer's on-screen rectangle in cm. Get it from
  the view's frame in screen coordinates and the display's physical size
  (`CGDisplayScreenSize`), not a guessed pixels-per-cm.
- The webcam is at the top centre of the built-in display, about 0.8 cm above
  the glass. Head tracking is offered only when the viewer is on the
  built-in display (v1; my call, see open questions).
- The virtual window is a plane perpendicular to the view direction, with
  the size the current view shows at that depth. Map it 1:1 onto the
  physical window, which fixes the world-per-cm scale.
- **Put the plane through `orbit.target`** (user, after the first hand
  test). The point you orbit around stays still on screen and moving your
  head looks around it. With the plane at the model's front (the first
  build), the whole model sat behind the glass and slid sideways with the
  head, which read as the model moving. Parts in front of the plane can be
  cut by the view's edges; accepted.
- Eye position, in window coordinates: x and y from the face, z = the
  calibrated distance. Convert to world with the same scale. The camera
  moves to that eye, keeps looking along the un-peeked view direction (no
  rotation), and gets an asymmetric frustum through the four window edges.
- This uses the true physical field of view (about 19° at 55 cm on a
  MacBook), not the viewer's 35°. Pressing Shift therefore changes the
  perspective strength while the target plane stays put. **Ease the change
  in over about 150 ms, and out on release** (my call: physically right, no
  jump).
- Put the maths in `OrbitCamera` as pure functions (an eye offset in, a view
  and projection matrix out), so it can be tested without a window. Apply it
  through `SCNCamera.projectionTransform` and the camera node's position.

### Tracking
- A `HeadTracker` in AeroBench3D: AVCaptureSession on the front camera,
  Vision landmarks once per camera frame, eye midpoint to normalised image
  coordinates, then angles from the calibrated field of view, then x and y
  in cm at the locked distance.
- One Euro filter per axis, about 40 ms look-ahead. Port it from the spike.
- If the face is lost, hold the last position. After about 0.5 s with no
  face, ease the eye back to centre.
- Camera lifecycle: start on the first Shift press, keep it running for
  about 30 s after the last release, then stop (my call). The first peek
  after a stop has about 0.5–1 s of startup. The macOS camera light shows
  whenever it runs.

### Settings
New "Head-tracked peek" section, stored in `AppSettings` / UserDefaults:
- On/off (default off). Turning it on triggers the macOS camera permission
  prompt.
- Your distance to the screen, in cm (default 55).
- Calibrate button: look at the screen, and it solves the webcam field of
  view from the median eye separation over about 1 s at that distance.
  Store the result.
- A status line: camera permission, face found, calibrated or not.

### Overlays and the camera revision
While peeking, the camera changes every frame. Bump `cameraRevision` and
call `onCameraChange` on each change so view-space overlays follow, the same
as orbiting.

## Tests

- SceneKit `hitTest` and `projectPoint` with a custom `projectionTransform`:
  check them early. Picks are ignored during a peek, but view-space overlays
  still project points.
- `OrbitCamera` off-axis maths: with zero eye offset the projection matches
  the normal symmetric one at the physical field of view. With any eye
  offset, the four corners of the window plane project to NDC ±1
  (the window property). Moving the eye right brings a point behind the
  plane left on screen and a point in front of it right.
- One Euro filter: holds a constant, follows a step, reduces noise.
- Calibration solve: a known separation and distance give the expected
  field of view.
- Input: Shift+drag orbits and Option+drag pans (the existing
  `OrbitCameraTests` and viewer input tests are the pattern).

## Left to the builder

- How to observe Shift: `flagsChanged` on `OrbitSCNView` when it is first
  responder, or a local event monitor while the pointer is over the viewer.
  Pick whichever makes Shift work without a click into the viewer first.
- Easing curve and exact timings.
- Whether Vision's pupil landmarks or the eye-contour centres are steadier.
- How the Settings status line looks (sage37 style, like the rest of
  Settings).
- Depth cues such as a ground shadow or grid while peeking. Not in v1 unless
  they come cheap.

- Shift alone triggers a peek: not Cmd+Shift shortcuts, and not while typing
  in a text field. Use the built-in camera with Center Stage off.

- **Option+drag pans in every viewer** (user). The Flow Field viewer uses the
  same `SceneKitViewer` and `OrbitSCNView` (`FlowFieldModel.swift:146`,
  `CADViewerModel.swift:125`), so the pan change sits in the shared code and
  both viewers match. Peek is turned on per viewer instance: on for the CAD
  viewer, off for Flow Field.

## Open questions for the user

- None.
