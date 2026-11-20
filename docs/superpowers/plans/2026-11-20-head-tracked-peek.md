# Head-Tracked Peek Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hold Shift in the CAD viewer and the webcam turns the view into a window onto the model (head-coupled, off-axis perspective). Pan moves to Option+drag in every viewer.

**Architecture:** Pure maths (the off-axis window, the physical layout, calibration, filtering and the peek state machine) lives in AeroBench3D and is unit-tested. A `HeadTracker` (AVFoundation and Vision) feeds a `HeadPeek` controller. `SceneKitViewer` drives a separate peek `SCNCamera` from it on a display link while a peek is active. Settings and calibration live in the app target.

**Tech Stack:** Swift 6 toolchain (language mode 5), SceneKit, AVFoundation, Vision, SwiftUI, XCTest. macOS 15.

**Spec:** `docs/superpowers/specs/2026-11-20-head-tracked-peek-design.md` (read it first). Reference spike: `spikes/head-tracked-view/index.html`.

## Global Constraints

- No new dependencies. AVFoundation and Vision only for tracking.
- Peek triggers on **Shift alone** (no other modifiers), only in a viewer with peek on (CAD on, Flow Field off), never while a text field has focus.
- Pan is **Option+drag** in every viewer. Right-drag, middle-drag and two-finger trackpad scroll still pan. Shift+drag orbits.
- The view must not move at all unless Shift is held, apart from the ease-out after release.
- Distance is locked to the calibrated value (default **55 cm**). Only sideways and vertical head movement is tracked.
- Interpupillary distance constant: **6.3 cm**. Webcam: top centre of the built-in display, **0.8 cm** above the glass.
- Ease in and out over **0.15 s**. Face lost: hold the last position, then ease to centre after **0.5 s**. Camera stops **30 s** after the last release.
- One Euro filter: min cutoff **1.8 Hz**, beta **0.02**, derivative cutoff **1 Hz**, look-ahead **0.04 s**.
- Picks, measure and edit clicks are ignored while a peek is active (blend > 0).
- Orbit and zoom during a peek are kept on release. Only the head offset eases out.
- Orthographic view: a peek eases into perspective and back.
- Head tracking only when the viewer's window is on the built-in display. Otherwise Shift does nothing; the Settings status says why.
- `INFOPLIST_KEY_NSCameraUsageDescription` = "AeroBench uses the camera to follow your head while you hold Shift in the CAD viewer, so you can look around a part." (Debug and Release).
- Work on a branch `head-tracked-peek`, not the default branch.

## Review Focus

1. **Shift pressed before the pointer is over the viewer, or with another window key.** Expect no peek until Shift is pressed again over a key viewer window; never a stuck peek. Covered by `testPeekNeedsShiftAlone` (Task 1) and the manual check in Task 7.
2. **App loses focus (Cmd-Tab) mid-peek.** Shift-up never arrives, so the peek must end. Covered by `testDeactivationEndsPeek` (Task 5); the viewer calls `release` on `NSWindow.didResignKeyNotification` (Task 7).
3. **Camera permission denied, or no camera.** Shift does nothing and Settings explains. Covered by `testUnavailableTrackerNeverBlends` (Task 5).
4. **Viewer zoomed inside the model** (target inside the bounds, so the front of the model is behind the eye). Expect the window plane to clamp and no NaN. Covered by `testWindowDepthClamps` (Task 2).
5. **Window resized or moved to another display mid-peek.** Expect the layout to be recomputed each frame and the peek to stop on a non-built-in display. Covered by `testLayoutOffCentreView` (Task 4) and the manual check in Task 7.

---

### Task 1: Pan to Option; Shift-alone predicate

**Files:**
- Modify: `app/AeroBenchKit/Sources/AeroBench3D/SceneKitViewer.swift` (`OrbitSCNView.mouseDown` ~line 674 and its doc comment ~line 638)
- Modify: `README.md:396` ("shift-drag" → "option-drag")
- Test: `app/AeroBenchKit/Tests/AeroBenchKitTests/OrbitCameraTests.swift`

**Interfaces:**
- Produces: `static func OrbitSCNView.dragPans(_ flags: NSEvent.ModifierFlags) -> Bool` and `static func OrbitSCNView.peekHeld(_ flags: NSEvent.ModifierFlags) -> Bool`

- [ ] **Step 1: Write the failing tests**

```swift
func testOptionDragPansShiftDragOrbits() {
    XCTAssertTrue(OrbitSCNView.dragPans(.option))
    XCTAssertFalse(OrbitSCNView.dragPans(.shift))
    XCTAssertFalse(OrbitSCNView.dragPans([]))
}

func testPeekNeedsShiftAlone() {
    XCTAssertTrue(OrbitSCNView.peekHeld(.shift))
    XCTAssertTrue(OrbitSCNView.peekHeld([.shift, .capsLock]))   // caps lock is not a chord
    XCTAssertFalse(OrbitSCNView.peekHeld([.shift, .command]))
    XCTAssertFalse(OrbitSCNView.peekHeld([.shift, .option]))
    XCTAssertFalse(OrbitSCNView.peekHeld([]))
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd app/AeroBenchKit && swift test --filter OrbitCameraTests`
Expected: FAIL to compile, `dragPans` and `peekHeld` not found.

- [ ] **Step 3: Implement both predicates and use `dragPans` in `mouseDown`**

`peekHeld`: the device-independent flags minus `.capsLock`, `.numericPad` and `.function` equal `.shift`. Update the class doc comment to "option-drag, right-drag, middle-drag: pan". Update the README line.

- [ ] **Step 4: Run to verify they pass**

Run: `cd app/AeroBenchKit && swift test --filter OrbitCameraTests`
Expected: PASS, including the existing tests.

- [ ] **Step 5: Commit**

```bash
git add app/AeroBenchKit README.md
git commit -m "Viewer: pan with Option-drag; Shift is free for peeking"
```

### Task 2: Off-axis window maths

**Files:**
- Create: `app/AeroBenchKit/Sources/AeroBench3D/PeekProjection.swift`
- Test: `app/AeroBenchKit/Tests/AeroBenchKitTests/PeekProjectionTests.swift`

**Interfaces:**
- Consumes: `OrbitCamera` (`position`, `forward`, `right`, `up`, `fovY`, `orthographic`, `orthoHalfHeight`, `distance`, `project`).
- Produces:

```swift
/// A rectangle perpendicular to the camera's forward direction: the virtual window.
public struct PeekWindow: Equatable, Sendable {
    public var center: SIMD3<Double>   // world
    public var halfWidth: Double        // world, along OrbitCamera.right
    public var halfHeight: Double       // world, along OrbitCamera.up
}

extension OrbitCamera {
    /// Depth of the window plane: the front of a bounding sphere, clamped to [minDepth, distance].
    public func peekDepth(boundsCenter: SIMD3<Double>, boundsRadius: Double, minDepth: Double) -> Double
    /// The window at `depth` along forward, sized to what the un-peeked view shows there.
    public func peekWindow(depth: Double, aspect: Double) -> PeekWindow
    /// The eye that reproduces the un-peeked view: (0, 0, depth) in perspective, (0, 0, 100 * halfHeight) in ortho.
    public func restEye(window: PeekWindow, depth: Double) -> SIMD3<Double>
    /// Camera position and off-axis projection (OpenGL clip convention, column-major, depth -1...1)
    /// for an eye at `eye`: window-frame coordinates in world units (x along right, y along up,
    /// z toward the viewer from the window centre). The camera keeps the un-peeked orientation.
    public func peekCamera(window: PeekWindow, eye: SIMD3<Double>, near: Double, far: Double)
        -> (position: SIMD3<Double>, projection: simd_double4x4)
}
```

- [ ] **Step 1: Write the failing tests** (in `PeekProjectionTests`; build cameras with `OrbitCamera.frame` as `OrbitCameraTests` does; a `clip(_:)` helper applies `projection * view` and divides by w)

  - `testWindowCornersStayPinned`: for eyes `(0,0,d)`, `(0.3d, -0.2d, 0.8d)` and `(-0.5d, 0.4d, 1.5d)` (d = depth), each window corner `center ± right*halfWidth ± up*halfHeight` maps to NDC (±1, ±1) within 1e-9.
  - `testRestEyeMatchesTheNormalView`: perspective camera, rest eye. For three points around the model, the NDC equals `OrbitCamera.project(_:aspect:)` within 1e-9.
  - `testParallaxDirection`: eye moved right (+x). A point 0.5·depth behind the window centre moves left in NDC x, and a point in front of it moves right.
  - `testWindowDepthClamps`: target inside the bounds (radius > distance) gives `minDepth`. Bounds entirely beyond the target give `distance`. No NaN in `peekCamera` for either.

- [ ] **Step 2: Run to verify they fail**

Run: `cd app/AeroBenchKit && swift test --filter PeekProjectionTests`
Expected: FAIL to compile.

- [ ] **Step 3: Implement**

The frustum is Kooima's generalised perspective with the window axes as the camera axes. With eye `e` (window frame) and `n = near`:
`l = (-halfWidth - e.x) * n / e.z`, `r = (halfWidth - e.x) * n / e.z`, `b = (-halfHeight - e.y) * n / e.z`, `t = (halfHeight - e.y) * n / e.z`, then the standard `glFrustum` matrix. `position = center + right*e.x + up*e.y - forward*e.z`. The window's half-height at depth `d` is `d * tan(fovY/2)` in perspective and `orthoHalfHeight` in ortho. `halfWidth = halfHeight * aspect`.

- [ ] **Step 4: Run to verify they pass**

Run: `cd app/AeroBenchKit && swift test --filter PeekProjectionTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/AeroBenchKit
git commit -m "Viewer: off-axis window maths for head-tracked peek"
```

### Task 3: SceneKit projection convention check

The design's early risk check: a custom `projectionTransform` must behave in `projectPoint` and `hitTest` the way the maths assumes.

**Files:**
- Modify: `app/AeroBenchKit/Sources/AeroBench3D/PeekProjection.swift` (add the converter)
- Test: `app/AeroBenchKit/Tests/AeroBenchKitTests/PeekProjectionTests.swift`

**Interfaces:**
- Consumes: `peekCamera` (Task 2).
- Produces: `func SCNMatrix4(_ m: simd_double4x4) -> SCNMatrix4` (file-level in AeroBench3D; skip it if SceneKit's own `SCNMatrix4(simd_float4x4)` initialiser is enough, and use that name in Task 7).

- [ ] **Step 1: Write the failing test** `testSceneKitAgreesWithPeekProjection`

Build a headless `SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)` with a scene, a camera node placed at `peekCamera(...).position`, oriented by `simdLook(at:up:localFront:)` as `applyCamera` does, with `camera.projectionTransform` set from the off-axis matrix (eye `(0.3d, -0.2d, 0.8d)`). Set the renderer's viewport size if the API exposes it; otherwise compare in normalised units. For three points, `renderer.projectPoint` converted to NDC equals the Task 2 `clip` result within 1e-4. Skip with `XCTSkip` when there is no Metal device.

- [ ] **Step 2: Run to verify it fails**

Run: `cd app/AeroBenchKit && swift test --filter testSceneKitAgreesWithPeekProjection`
Expected: FAIL (converter missing).

- [ ] **Step 3: Implement the converter. If the convention differs (depth range 0...1 or row-major), fix it in `peekCamera`, not here, and note it in the doc comment.**

- [ ] **Step 4: Run all of `PeekProjectionTests`**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/AeroBenchKit
git commit -m "Viewer: check SceneKit's projection convention for the peek camera"
```

### Task 4: Physical layout, head position and calibration

**Files:**
- Create: `app/AeroBenchKit/Sources/AeroBench3D/HeadGeometry.swift`
- Test: `app/AeroBenchKit/Tests/AeroBenchKitTests/HeadGeometryTests.swift`

**Interfaces:**
- Produces:

```swift
public enum HeadGeometry {
    public static let ipdCM = 6.3
    public static let cameraAboveGlassCM = 0.8
    /// The view on the glass and the webcam relative to the view's centre, in cm (x right, y up).
    public struct Layout: Equatable, Sendable {
        public var viewWidthCM: Double, viewHeightCM: Double
        public var cameraCM: SIMD2<Double>
    }
    /// viewRect and screenFrame in AppKit screen points (y up); screenSizeMM from CGDisplayScreenSize.
    public static func layout(viewRect: CGRect, screenFrame: CGRect, screenSizeMM: CGSize) -> Layout
    /// One Vision observation: eye midpoint in normalised image coordinates as Vision gives them
    /// (origin bottom left), eye separation as a fraction of image width (aspect-corrected).
    public struct Sample: Sendable { public var eyeMid: SIMD2<Double>; public var separation: Double; public var time: TimeInterval }
    /// Head (eye) position in cm relative to the view centre: x right, y up, z = distanceCM.
    public static func head(_ s: Sample, hfov: Double, imageAspect: Double, distanceCM: Double,
                            layout: Layout, mirrored: Bool) -> SIMD3<Double>
    /// The webcam's horizontal field of view (radians) that makes `separation` mean `distanceCM`.
    public static func calibratedHFOV(separations: [Double], distanceCM: Double) -> Double?
}
```

- [ ] **Step 1: Write the failing tests**

  - `testLayoutFullScreenView`: viewRect = screenFrame = 1512×982 pt, screenSizeMM = 302.4×196.4 gives a view of 30.24×19.64 cm and cameraCM = (0, 9.82 + 0.8).
  - `testLayoutOffCentreView`: a 600×400 view whose centre is 200 pt left of and 100 pt below the screen centre gives cameraCM = (200·k, (491 + 100)·k + 0.8), with k = 30.24/1512.
  - `testHeadCentredOnCamera`: eyeMid (0.5, 0.5) gives head x and y equal to cameraCM, and z = distanceCM.
  - `testHeadSign`: eyeMid.x < 0.5 with `mirrored: false` gives head.x > cameraCM.x (the person's right is the image's left). `mirrored: true` flips it.
  - `testCalibrationRoundTrip`: separation 6.3 / (2·55·tan(31°)) with distance 55 gives 62° within 1e-9. Uses the median; `[]` gives nil; a separation ≤ 0 is ignored.

- [ ] **Step 2: Run to verify they fail**

Run: `cd app/AeroBenchKit && swift test --filter HeadGeometryTests`
Expected: FAIL to compile.

- [ ] **Step 3: Implement.** The angle maths is the spike's `detectEye`, with Vision's y up and the distance locked.

- [ ] **Step 4: Run to verify they pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/AeroBenchKit
git commit -m "Viewer: head position, screen layout and webcam calibration maths"
```

### Task 5: Filter and peek state

**Files:**
- Create: `app/AeroBenchKit/Sources/AeroBench3D/PeekState.swift`
- Test: `app/AeroBenchKit/Tests/AeroBenchKitTests/PeekStateTests.swift`

**Interfaces:**
- Produces:

```swift
public struct OneEuroFilter: Sendable {
    public init(minCutoff: Double = 1.8, beta: Double = 0.02, dCutoff: Double = 1, lead: Double = 0.04)
    public mutating func filter(_ x: Double, at t: TimeInterval) -> Double
}

/// The peek over time: how far it is blended in, and where the head is.
public struct PeekState: Sendable {
    public init(fade: Double = 0.15, faceLostAfter: Double = 0.5, stopAfter: Double = 30)
    public private(set) var blend: Double            // 0 off ... 1 full peek
    public private(set) var headCM: SIMD3<Double>?   // filtered, nil before the first face
    public var wantsCamera: Bool { get }             // false once stopAfter has passed since release
    public mutating func press(at t: TimeInterval, trackerAvailable: Bool)
    public mutating func release(at t: TimeInterval)
    public mutating func face(_ head: SIMD3<Double>?, at t: TimeInterval, rest: SIMD3<Double>)  // nil: no face this frame
    public mutating func tick(at t: TimeInterval)
}
```

- [ ] **Step 1: Write the failing tests**

  - `testFilterHoldsAConstant`: 60 samples of 5.0 give 5.0 within 1e-9.
  - `testFilterFollowsAStep`: after a step 0 → 10 at 30 Hz, the value is above 9 within 0.3 s.
  - `testFilterReducesNoise`: the standard deviation of ±0.5 alternating input around 10 drops by at least 3× (output after warm-up).
  - `testBlendEasesInAndOut`: press at t = 0 gives blend 0, at 0.075 strictly between 0 and 1, at 0.15 exactly 1. Release at 1.0 gives 0 at 1.15. Monotonic both ways.
  - `testDeactivationEndsPeek`: `release` while easing in (blend 0.5) eases out from 0.5, with no jump.
  - `testFaceLostEasesToRest`: a face at x = 5, then nil frames. The head holds x = 5 until 0.5 s, then reaches `rest` by 0.65 s.
  - `testUnavailableTrackerNeverBlends`: `press(trackerAvailable: false)` leaves blend 0 forever.
  - `testCameraStopsAfter30s`: `wantsCamera` is true from press until 30 s after release, then false. Pressing again makes it true.

- [ ] **Step 2: Run to verify they fail**

Run: `cd app/AeroBenchKit && swift test --filter PeekStateTests`
Expected: FAIL to compile.

- [ ] **Step 3: Implement.** Port `OneEuro` from the spike. Use smoothstep for the blend curve.

- [ ] **Step 4: Run to verify they pass**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/AeroBenchKit
git commit -m "Viewer: One Euro filter and peek state machine"
```

### Task 6: HeadTracker (camera and Vision)

**Files:**
- Create: `app/AeroBenchKit/Sources/AeroBench3D/HeadTracker.swift`
- Modify: `app/AeroBench.xcodeproj/project.pbxproj` (add `INFOPLIST_KEY_NSCameraUsageDescription` to the AeroBench target's Debug and Release, next to `INFOPLIST_KEY_CFBundleDisplayName`, with the text from Global Constraints)

**Interfaces:**
- Consumes: `HeadGeometry.Sample` (Task 4).
- Produces:

```swift
@MainActor public final class HeadTracker {
    public enum Status: Equatable, Sendable { case off, needsPermission, denied, noCamera, starting, running }
    public private(set) var status: Status
    public var onSample: ((HeadGeometry.Sample?) -> Void)?   // main actor, once per camera frame; nil = no face
    public private(set) var imageAspect: Double              // width / height of the frames
    public private(set) var mirrored: Bool                   // whether frames arrive mirrored
    public init()
    public func requestAccess() async -> Bool
    public func start()
    public func stop()
}
```

Camera: the built-in front `AVCaptureDevice` (`.builtInWideAngleCamera`), Center Stage off (`AVCaptureDevice.centerStageControlMode = .app`, `isCenterStageEnabled = false`). A video data output on a serial queue. Run `VNDetectFaceLandmarksRequest` per frame. Use the largest face. Take the eye midpoint from the pupil landmarks, or the eye-contour centres if pupils are missing (the design leaves the choice to you). Separation is measured in pixels, then divided by image width. Hop to the main actor for `onSample`.

- [ ] **Step 1: Implement `HeadTracker` and the plist key**

- [ ] **Step 2: Build**

Run: `cd app/AeroBenchKit && swift build && cd .. && xcodebuild -project AeroBench.xcodeproj -scheme AeroBench -configuration Debug build -quiet`
Expected: both succeed with no new warnings.

- [ ] **Step 3: Manual check, with a temporary `print` in a scratch caller (do not commit)**

With a face in front of the camera, samples arrive at about 30 Hz. eyeMid.x falls when the head moves to its own right if `mirrored` is false. Record which way it goes for Task 7.

- [ ] **Step 4: Commit**

```bash
git add app/AeroBenchKit app/AeroBench.xcodeproj
git commit -m "Viewer: HeadTracker (webcam and Vision face landmarks)"
```

### Task 7: Peek in SceneKitViewer

**Files:**
- Create: `app/AeroBenchKit/Sources/AeroBench3D/HeadPeek.swift`
- Modify: `app/AeroBenchKit/Sources/AeroBench3D/SceneKitViewer.swift`

**Interfaces:**
- Consumes: Tasks 1–6.
- Produces:

```swift
@MainActor public final class HeadPeek {
    public struct Config: Equatable, Sendable { public var enabled: Bool; public var distanceCM: Double; public var hfovDegrees: Double }
    public var config: Config
    public let tracker: HeadTracker
    public init(config: Config)
    /// Collects about 1 s of samples and returns the calibrated HFOV in degrees, or nil if no face was seen.
    public func calibrate(distanceCM: Double) async -> Double?
}

// SceneKitViewer
public var peek: HeadPeek?   // nil: no peeking (Flow Field)
public var isPeeking: Bool { get }   // blend > 0
```

Behaviour:
- When `peek` is set, install an `NSEvent` local monitor for `.flagsChanged`. Shift alone (`OrbitSCNView.peekHeld`) while the view's window is key, the pointer is inside the view, and the first responder is not an `NSText` calls `press`. Anything else calls `release`. Also call `release` on `NSWindow.didResignKeyNotification` and when the window leaves the built-in display (`CGDisplayIsBuiltin`).
- While `blend > 0` or the tracker wants the camera, run `scnView.displayLink(target:selector:)`. Each tick: `tick`, then recompute the layout from the view's screen rect (Task 4). Map the head to window world units with `scale = 2 * halfHeight / layout.viewHeightCM`. Ease the eye `simd_mix(restEye, headEye, blend)`, then `applyCamera()`. Stop the link when blend is 0 and the camera is not wanted.
- `applyCamera()`: if blend > 0, set `cameraNode.camera = peekCamera` (a second `SCNCamera`) with its `projectionTransform` from `peekCamera(window:eye:near:far:)`, and the node at the peek position. Use `near = 0.05 * eye.z` and `far = eye.z + 4 * radius + depth`. Otherwise restore the normal camera. Keep bumping `cameraRevision` and calling `onCameraChange`.
- Window depth: `peekDepth(boundsCenter: center, boundsRadius: radius, minDepth: 0.05 * orbit.distance)`.
- While `isPeeking`, `handleClick` and hover return early. A zoom anchor over empty space uses `orbit.target`.
- Start the tracker on `press` if it is not running. Stop it when `wantsCamera` turns false.

- [ ] **Step 1: Implement `HeadPeek` and the viewer changes**

- [ ] **Step 2: Run the package tests and build**

Run: `cd app/AeroBenchKit && swift test && cd .. && xcodebuild -project AeroBench.xcodeproj -scheme AeroBench -configuration Debug build -quiet`
Expected: all tests pass and the build succeeds.

- [ ] **Step 3: Temporarily set `cad.viewer.peek` in `AppState.init` with enabled = true, 55 cm, 62° (do not commit), then check by hand**

  - Holding Shift over the CAD viewer with a model open eases in. Moving your head shows parallax, and the view's edges stay fixed to the model's front.
  - Release eases out to the same view, keeping any orbit done meanwhile.
  - Shift+drag orbits, Option+drag pans.
  - Clicking in Measure mode does nothing while peeking.
  - Cmd-Tab away mid-peek ends it.
  - With the window on an external display, Shift does nothing.
  - In orthographic, it eases into perspective and back.
  - The Flow Field viewer ignores Shift.

- [ ] **Step 4: Commit (without the temporary wiring)**

```bash
git add app/AeroBenchKit
git commit -m "CAD viewer: hold Shift to peek with head tracking"
```

### Task 8: Settings, calibration and wiring

**Files:**
- Modify: `app/AeroBench/AppSettings.swift` (keys `peekEnabled` Bool default false, `peekDistanceCM` Double default 55, `peekHFOVDegrees` Double, 0 = not calibrated)
- Modify: `app/AeroBench/AppState.swift` (in `init` after `cad = CADViewerModel()`: `cad.viewer.peek = HeadPeek(config: ...)`; add `func applyPeekSettings()`)
- Modify: `app/AeroBench/Views/SettingsView.swift` (new section, sage37 like its neighbours)
- Modify: `README.md` (one paragraph under the CAD viewer controls)

**Interfaces:**
- Consumes: `HeadPeek`, `HeadPeek.Config`, `HeadPeek.calibrate`, `HeadTracker.status`, `HeadTracker.requestAccess` (Task 7, Task 6).

Section "Head-tracked peek":
- Toggle "Hold Shift to peek with head tracking". Turning it on calls `requestAccess()`. If access is denied, it turns back off and shows "Camera access is off: System Settings > Privacy & Security > Camera".
- Stepper or field "Your distance to the screen" in cm, 30–120.
- Button "Calibrate". Its help text: "Sit at that distance and look at the screen." It stores the HFOV it returns, or shows "No face seen" when it returns nil.
- Status line: not calibrated (62° assumed), calibrated (n°), or the tracker status. Add "Only on the built-in display" when relevant.
- When uncalibrated, use 62° as the HFOV.

- [ ] **Step 1: Implement settings, wiring, section and README paragraph**

- [ ] **Step 2: Build and run the package tests**

Run: `cd app/AeroBenchKit && swift test && cd .. && xcodebuild -project AeroBench.xcodeproj -scheme AeroBench -configuration Debug build -quiet`
Expected: PASS and build succeeds.

- [ ] **Step 3: Manual check**

Off by default, and Shift does nothing. Turning it on prompts for the camera once. Calibrating at a measured distance stores a plausible HFOV (roughly 50–80°). Peek works after a relaunch with the settings kept.

- [ ] **Step 4: Commit**

```bash
git add app/AeroBench README.md
git commit -m "Settings: head-tracked peek toggle, distance and calibration"
```

### Task 9: Final check with the user

- [ ] **Step 1:** Run `cd app/AeroBenchKit && swift test` and the Debug build. Both must be clean.
- [ ] **Step 2:** Hand the user the Task 7 manual list and ask them to try it, one eye closed, after calibrating. Their verdict decides whether the depth cues left to the builder (ground shadow or grid while peeking) are needed.
