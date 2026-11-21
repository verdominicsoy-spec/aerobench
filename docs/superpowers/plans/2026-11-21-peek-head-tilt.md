# Peek Head Tilt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While peeking, tilting the head ear to shoulder turns the model the other way in the screen's plane.

**Architecture:** The tracker measures the eye line's angle; `PeekState` filters it and recentres it at Shift; the peek camera rolls its window frame (right, up) about forward by tilt × sensitivity × blend.

**Tech Stack:** Swift, SceneKit, Vision, XCTest (`swift test` in `app/AeroBenchKit`).

**Spec:** `docs/superpowers/specs/2026-11-21-peek-head-tilt-design.md`

## Global Constraints

- Clockwise head tilt (as you see it) turns the model anticlockwise on screen, by tilt × `config.sensitivity`.
- The tilt at Shift press is level; the roll fades with `blend`; a lost face eases the tilt to level.
- The tilt uses its own `OneEuroFilter()` with the default settings.
- The normal (un-peeked) view and `OrbitCamera` itself gain no roll.

## Review Focus

- Mirrored frames: the sign flips (Task 1 test).
- Before the first face, the tilt offset is 0, not nil-crashing (Task 2 test).
- Blend 0 gives roll 0, so releasing Shift returns exactly to the normal view (Task 2/4: roll is multiplied by blend).
- Orthographic views roll too: same frame, no special case (Task 3 test runs both projections).
- Eye points nearly vertical (head on its side): `atan2` stays finite; no clamp (Task 1 test).

---

### Task 1: Eye-line angle and tilt

**Files:** Modify `app/AeroBenchKit/Sources/AeroBench3D/HeadGeometry.swift`, `HeadTracker.swift`; Test `Tests/AeroBenchKitTests/HeadGeometryTests.swift`

**Interfaces — Produces:**
- `HeadGeometry.Sample.eyeAngle: Double` (radians, image frame, y up), `init(eyeMid:separation:eyeAngle: Double = 0, time:)`
- `static func eyeAngle(_ p: SIMD2<Double>, _ q: SIMD2<Double>) -> Double`: angle of the line from the image-left point to the image-right point.
- `static func tilt(_ s: Sample, mirrored: Bool) -> Double`: clockwise-positive as the viewer sees it; `mirrored ? -s.eyeAngle : s.eyeAngle`.

- [ ] Test `testEyeAngleOrdersByX`: `eyeAngle([0,0],[1,1]) == eyeAngle([1,1],[0,0]) == .pi/4`; level is 0; `eyeAngle([0,0],[1e-9, 1])` is finite.
- [ ] Test `testTiltSign`: unmirrored, the image-left eye lower (eyeAngle > 0) is a clockwise tilt (> 0); mirrored flips it.
- [ ] Run, see them fail; implement; `HeadTracker` fills `eyeAngle` from the two eye points in pixels; run green.

### Task 2: Tilt in PeekState

**Files:** Modify `PeekState.swift`, `HeadPeek.swift`; Test `PeekStateTests.swift`

**Interfaces — Produces:** `PeekState.face(_ head: SIMD3<Double>?, tilt: Double = 0, at: TimeInterval, rest: SIMD3<Double>)`; `PeekState.tiltOffset: Double` (filtered tilt minus the tilt at Shift; 0 before a face). `HeadPeek.tiltOffset` forwards it; `HeadPeek` passes `HeadGeometry.tilt(sample, mirrored:)`.

- [ ] Test `testTiltIsRecentredAtShift`: faces at tilt 0.2 before and at press, then 0.3 held still for 1 s → `tiltOffset ≈ 0.1` (accuracy 0.005).
- [ ] Test `testTiltEasesToLevelWhenTheFaceIsLost`: after `faceLostAfter + fade` with no face → `tiltOffset == 0` (accuracy 1e-9).
- [ ] Test `testNoTiltBeforeAFace`: pressed, no face → `tiltOffset == 0`.
- [ ] Fail, implement, green. `cameraStopped()` clears the tilt too.

### Task 3: Rolled peek camera

**Files:** Modify `PeekProjection.swift`; Test `PeekProjectionTests.swift`

**Interfaces — Produces:** `OrbitCamera.peekAxes(roll: Double) -> (right: SIMD3<Double>, up: SIMD3<Double>)` with `right' = cos·right − sin·up`, `up' = cos·up + sin·right` (roll > 0 turns the camera clockwise, the picture anticlockwise); `peekCamera(window:eye:near:far:roll: Double = 0)` places the eye along the rolled axes.

- [ ] Test `testRollTurnsTheCameraClockwise`: `peekAxes(roll: .pi/2)` gives `up == right` and `right == -up` (1e-12); roll 0 gives the plain axes.
- [ ] Test `testRolledPeekPositionUsesRolledAxes`: for both projections, eye `(1, 0, z)` with roll π/2 puts the camera at `window.center + up' ... ` i.e. along the old `-up` by 1.
- [ ] Fail, implement, green.

### Task 4: Wire into the viewer

**Files:** Modify `SceneKitViewer.swift` (`applyPeekCamera`)

- [ ] `let roll = peek.config.sensitivity * peek.tiltOffset * peek.blend`; use `view.peekAxes(roll:)` for the camera node's up, `peekCamera(..., roll:)` and the room's `r`/`u` columns. Key light unchanged.
- [ ] `swift test` in `app/AeroBenchKit` all green; app builds via `./AeroBench.command --no-pull`.
- [ ] Commit, push.
