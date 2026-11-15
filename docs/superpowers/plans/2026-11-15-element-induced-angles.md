# Each element at its own induced angle: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The on-car RANS (`rans.solve_finite`) turns each element of a multi-element wing by its own induced angle, from the vortex lattice's downwash along the chord, so a short wing like frontwing#1.02 (aspect ratio 0.77) unloads its flaps the way STAR does instead of stalling its main. Single-element wings keep today's answer.

**Architecture:** (1) `vlm.Lattice.chordwise` gives the induced angle along the chord at mid-span: the lattice's 3D downwash beyond what the same chordwise loading induces in 2D (same height, ground image). (2) `finite.element_turns` turns that into each element's angle relative to the load-weighted mean, so the mean stays the validated lifting-line angle and one element gets zero. (3) `rans.turn_elements` rotates each element about its quarter chord; `rans.solve` takes `element_turns`. (4) `solve_finite` feeds each solve the turns from the last solve's Cl and element loads, and reports them. (5) Rerun frontwing#1.02 and compare with STAR's wing-alone run.

**Tech Stack:** Python 3 (numpy), SU2 via `aeroengine.wing.rans`, pytest.

**Spec:** the user's request of 15 Nov 2026 ("make a plan to continue to improve on aerobench and execute it"), and the finding in `docs/validation/frontwing1/README.md` "STAR's wing alone": STAR's main loads like the 2D main at +7.4 deg, its flaps at 40-70% of 2D; one induced angle per section cannot show it.

## Global Constraints

- Fix the physical cause; no fitted factors. The mean induced angle stays `finite.lattice_factors`' (validated on Zerihan's wing within 3%).
- Calibrated estimate numbers (estimate.py, Swift `Wing.finite3D`) do not change.
- Never hand-build Release into build/DerivedData.
- Commit each task; push after the feature; `graphify update .` after code changes; never commit graphify-out/.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Validation numbers in percent, with what is not converged said.

## Review Focus

- One element: turns exactly [0.0], and `solve_finite` behaves as before (existing loop tests unchanged).
- Inverted (downforce) wing: aft elements turned the unloading way (positive, alpha's sense) when Cl < 0.
- Element loads of mixed sign or near zero total: shares fall back to chord shares, no division blow-up.
- Free air with turns: the mesh and restart are not reused across solves whose turns differ (the geometry changed).
- Drawn coords not starting at x = 0: stations measured from the wing's own leading edge.

---

### Task 1: Chordwise induced angle from the lattice

**Files:** Modify `engine/src/aeroengine/wing/vlm.py`; Test `engine/tests/test_wing_vlm.py`.

**Interfaces:** `Lattice.chordwise(stations: list[float]) -> np.ndarray`: induced angle (rad) per unit section Cl on the lattice's chord, at the two mid-span lattice strips (mean), at each station (fraction of the chord from the leading edge, linear between the lattice's control points, held at the ends).

- [ ] Tests: endless free-air wing (span 1000, chord 1): every station |angle| < 1e-3; AR 10 free air: rising from 0.1 to 0.9, ratio under 1.3; frontwing#1.02's lattice (span 0.5245, chord 0.6245, height 0.0966, endplate 0.315, endplate_bottom 0.035): rising, the 0.9 value over twice the 0.1 value.
- [ ] Implement: solve the lattice at alpha 1 rad; per strip the 3D normal velocity at the control points is -1 (no flow through); the 2D section's own normal velocity there from the same chordwise circulation (point vortices, image at twice the strip's height); induced = 1 + w2D, over the strip's Cl.
- [ ] Commit.

### Task 2: Each element's turn relative to the mean

**Files:** Modify `engine/src/aeroengine/wing/finite.py`; Test `engine/tests/test_wing_finite.py`.

**Interfaces:** `element_turns(cl: float, stations: list[float], shares: list[float], span, chord, endplate, ride_height, planform=None, endplate_bottom=None) -> list[float]` degrees, alpha's sense: `-deg(off_e) * cl * chord / planform`, `off_e = a(x_e) - sum(shares * a(x_e))` from `Lattice.chordwise` on the lattice `lattice_factors` uses at the ride height (cached).

- [ ] Tests: one element gives [0.0]; share-weighted sum of turns is 0; frontwing#1.02 at stations (0.2, 0.55, 0.73, 0.89), shares (0.37, 0.31, 0.2, 0.12), Cl -2: main < 0 < flap 1 < flap 2 < flap 3.
- [ ] Commit.

### Task 3: Turning elements in the RANS solve

**Files:** Modify `engine/src/aeroengine/wing/rans.py`; Test `engine/tests/test_wing_rans.py`.

**Interfaces:** `turn_elements(placed: list[np.ndarray], turns: list[float]) -> list[np.ndarray]`: each element rotated by its turn in alpha's sense (points times the same matrix as `in_ground_effect`) about its quarter-chord point (leading edge = the point farthest from the trailing edge, the mean of the first and last points). `solve` applies `p["element_turns"]` (optional, one per element) before the ground turn.

- [ ] Tests: zero turns leave the coords unchanged; the quarter-chord point stays put; one element turned by 5 deg has the shape `in_ground_effect([e], 5, h)` gives it (same after removing translation); wrong length raises EngineError.
- [ ] Commit.

### Task 4: The finite loop feeds the turns

**Files:** Modify `engine/src/aeroengine/wing/rans.py` (`solve_finite`); Test `engine/tests/test_wing_rans.py`.

**Interfaces:** Stations: each element's three-quarter chord along the drawn x, from the wing's leading edge, over the planform. Shares: the last solve's `elements[i]["cl"]` over their sum when every share is in [0, 1], else chord shares. First solve: the quick estimate's Cl at the start angle, chord shares. Each later solve uses the last converged solve's Cl and shares. Settled: the angle within FINITE_TOLERANCE and no turn moved more than FINITE_TOLERANCE. Mesh and restart reused only when the turns did not change. Produces `finite["element_turns"]` (degrees, rounded 3).

- [ ] Tests: the existing loop tests pass unchanged (one element); a two-element fake (elements at x 0-0.5 and 0.5-1, its solve returning both elements' Cl) gets turns on its second solve with the aft one positive for Cl < 0, and the result carries `element_turns`.
- [ ] Commit.

### Task 5: frontwing#1.02 against STAR

**Files:** Modify `docs/validation/frontwing1/run_car.py` if needed; `docs/validation/frontwing1/README.md`.

- [ ] Run `run_car.py 0.315 0.0966 0.5245 -7.45 0.035` (background, about 1-1.5 h).
- [ ] Compare Cl and each element's Cl with STAR's mid-span strip (Cl -2.00; main -0.77, flap 1 -0.61, flap 2 -0.41, flap 3 -0.21) and the separation; write it up, converged or not.
- [ ] Commit.

### Task 6: Write-up

- [ ] Memory validation-status, push, `graphify update .`, report.
