# Peek True Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The peek is a 1:1 window: the head moves the eye (including leaning in), nothing turns or rolls, and the model sits behind the glass.

**Architecture:** Remove the turn, roll, gain and slider. `PeekState` smooths the eye distance first, the head is placed with it, and the eye moves by (head − head at press) × rest.z ÷ distance at press, in all three axes. The window plane moves to the model's front.

**Tech Stack:** Swift, SceneKit, XCTest (`swift test` in `app/AeroBenchKit`).

**Spec:** `docs/superpowers/specs/2026-11-21-peek-true-window-design.md`

## Global Constraints

- Pressing Shift changes nothing until the head moves; blend 0 gives the normal view exactly.
- No sensitivity, tilt or gain left in code, settings or copy.
- The distance keeps its median-of-3 and `OneEuroFilter(minCutoff: 0.4, beta: 0, lead: 0)`.

## Review Focus

- Distance read before the head is placed, so the head's x and y use the smoothed distance, not a raw one.
- Face lost: the head eases back to the press position, z included, so the eye returns to rest.
- Zoomed right into a part: the glass clamps to a quarter of the way to the target, never behind the camera.
- Orthographic: the far rest eye times d/d₀ stays finite and the view still looks parallel.
- An old `peekSensitivity` value in user defaults is ignored.

---

### Task 1: Remove the turn, roll, gain and slider

**Files:** `HeadGeometry.swift`, `HeadTracker.swift`, `PeekState.swift`, `HeadPeek.swift`, `PeekProjection.swift`, `SceneKitViewer.swift`, `app/AeroBench/AppSettings.swift`, `app/AeroBench/Views/SettingsView.swift`, README; their tests.

- [ ] Delete `eyeAngle`/`tilt`, the tilt state, `gain`, `Config.sensitivity`, `peekTurned`, `peekAxes`/`roll`, the slider and its key; their tests go too.
- [ ] The gain tests become distance tests on `PeekState.distanceCM`: smoothed, one bad frame dropped, held when lost, no jump on return, nil after the camera stops.

### Task 2: 1:1 eye with the live distance

**Produces:** `PeekState.measure(distance: Double?, at:)` (called before `face`); `PeekState.offsetCM: SIMD3<Double>?`; `PeekWindow.eye(rest:offsetCM: SIMD3<Double>, distanceCM:blend:)` scaling all three axes by `rest.z / distanceCM`; `HeadPeek.pressDistanceCM` = neutral head z, else `config.distanceCM`.

- [ ] `testEyeMovesOneToOne`: rest (0,0,200), d₀ 50: offset (10,−5,0) → (40,−20,200); (0,0,−25) → z 100; blend 0.5 halves the move; blend 0 → rest.
- [ ] `testOffsetIncludesLeaningIn`: press at z 55, then z 40 held 1 s → offset z ≈ −15.
- [ ] Fail, implement, green. `HeadPeek.receive` measures, then places the head with `state.distanceCM ?? config.distanceCM`.

### Task 3: The glass at the model's front

**Produces:** `OrbitCamera.peekDepth(center: SIMD3<Double>, radius: Double) -> Double` = max(dot(center − position, forward) − radius, 0.25 · distance).

- [ ] `testGlassAtTheModelsFront`: framed camera → `distance − radius` when the target is the centre (1e-9); zoomed in so the front is closer than a quarter → `0.25 · distance`.
- [ ] Fail, implement, green. Viewer uses it for the window; the room's back is measured from the window.
- [ ] `swift test` green; `./AeroBench.command --no-pull` builds; commit, review, push.
