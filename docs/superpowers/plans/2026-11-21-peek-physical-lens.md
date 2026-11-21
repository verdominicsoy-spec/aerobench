# Peek Physical Lens Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The 3D view's lens is the angle the pane covers from 55 cm whenever the peek can run, so the peek is physically exact.

**Architecture:** A pure lens function from the layout, a pure framing-keeping lens change on `OrbitCamera`, and the viewer syncing the lens before drawing the normal view.

**Tech Stack:** Swift, SceneKit, XCTest (`swift test` in `app/AeroBenchKit`).

**Spec:** `docs/superpowers/specs/2026-11-21-peek-physical-lens-design.md`

## Global Constraints

- Lens = 2·atan(viewHeightCM ÷ 2 ÷ 55), held to 10°–35°; 35° when the peek is off or the view is not on the built-in display.
- A lens change never changes the framing at the target plane.

## Review Focus

- Pressing Shift changes nothing: the lens is synced on the normal path only, before the press.
- Orthographic views: the lens change does not move the camera.
- Turning the peek off restores 35° without a zoom.
- Collapsed pane (height 0): the lens holds at 10°, no NaN.

---

### Task 1: The lens

**Produces:** `HeadGeometry.lensFovY(_ layout: Layout, distanceCM: Double) -> Double` (radians).

- [ ] `testLensMatchesThePane`: 16 cm → 2·atan(8/55); 2 cm and 0 cm → 10°; 60 cm → 35°.

### Task 2: Changing the lens keeps the framing

**Produces:** `OrbitCamera.withFovY(_ fovY: Double) -> OrbitCamera`: perspective moves the camera along forward so distance·tan(fovY/2) is kept; orthographic only sets fovY.

- [ ] `testLensChangeKeepsTheFraming`: half-height at the target, target and forward kept (1e-9); orthographic position unchanged.

### Task 3: Viewer

- [ ] `syncLens()` in `applyCamera`'s normal branch: the lens from `peekLayout()` when `peek?.config.enabled`, else 35°; updates `orbit` and `normalCamera.fieldOfView` when it differs.
- [ ] `swift test` green; app builds; commit, review, push.
