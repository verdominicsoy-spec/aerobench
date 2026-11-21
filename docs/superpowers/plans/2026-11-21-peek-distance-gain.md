# Peek Distance Gain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While peeking, the slide and tilt move more the closer you sit: rate = slider × 55 cm ÷ your distance.

**Architecture:** The eye gap gives a distance; `PeekState` smooths it; `PeekState.gain(reference:)` turns it into a clamped factor; the viewer multiplies the sensitivity by it.

**Tech Stack:** Swift, XCTest (`swift test` in `app/AeroBenchKit`).

**Spec:** `docs/superpowers/specs/2026-11-21-peek-distance-gain-design.md`

## Global Constraints

- Factor = reference ÷ distance, reference `config.distanceCM` (55), clamped to 0.5…2; 1 before a face.
- The eye position keeps the locked 55 cm (no stretching).
- Distance filter: `OneEuroFilter(minCutoff: 0.4, beta: 0.005, lead: 0)`.

## Review Focus

- Separation 0 or tiny (bad frame): distance finite, factor clamps to 0.5 (Task 1/2 test).
- Face lost then back: no jump from a stale filter (filter reset to the shown distance, as the head's is).
- `cameraStopped` clears the distance, so the next peek starts at 1×.
- Release: the factor only scales terms already multiplied by blend, so releasing Shift still returns exactly.

---

### Task 1: Distance from the eye gap

**Files:** `HeadGeometry.swift`; Test `HeadGeometryTests.swift`

**Produces:** `HeadGeometry.pupilGapCM = 6.3`; `static func distance(_ s: Sample, hfov: Double) -> Double` = `pupilGapCM / (2·tan(hfov/2)·max(separation, 1e-6))`.

- [ ] Test `testDistanceFromEyeGap`: separation `6.3 / (2·tan(31°)·55)` gives 55 (1e-9); half that gives 110; separation 0 is finite.
- [ ] Fail, implement, green.

### Task 2: Smoothed distance and gain

**Files:** `PeekState.swift`, `HeadPeek.swift`; Test `PeekStateTests.swift`

**Produces:** `face(_:tilt:distance: Double? = nil, at:rest:)`; `PeekState.distanceCM: Double?`; `func gain(reference: Double) -> Double`; `HeadPeek.gain` = `state.gain(reference: config.distanceCM)`, `receive` passes `HeadGeometry.distance(sample, hfov:)`.

- [ ] `testGainIsInverseDistance`: steady 27.5 → gain(55) 2 (1e-6); 55 → 1; 20 → 2; 200 → 0.5; no face → 1.
- [ ] `testGainIsSmoothed`: steady 55 for 1 s, then 45.8: after 0.1 s gain < 1 + 0.5·(55/45.8 − 1); after 2 s within 1% of 55/45.8.
- [ ] `testGainHeldWhenTheFaceIsLost`: steady 27.5, then no face for `faceLostAfter + fade + 1` → gain still 2.
- [ ] Fail, implement (reset on return after loss; cleared by `cameraStopped`), green.

### Task 3: Viewer

**Files:** `SceneKitViewer.swift` (`applyPeekCamera`)

- [ ] `let sensitivity = peek.config.sensitivity * peek.gain`, used for `extra` and `roll`.
- [ ] `swift test` all green; `./AeroBench.command --no-pull` builds; commit, push.
