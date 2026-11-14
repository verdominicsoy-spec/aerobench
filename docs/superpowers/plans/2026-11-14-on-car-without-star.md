# On-car accuracy without STAR: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the on-car RANS answer trustworthy on short, low, multi-element wings like frontwing#1 without a STAR reference: no fake settled answers on a stall cliff, spanwise strips instead of one mid-span section, and the endplate gap set from the app.

**Architecture:** (1) The single-strip angle loop in `rans.solve_finite` bisects once it has bracketed the answer and reports a stall cliff instead of jumping across it. (2) The vortex lattice gains a spanwise height change and a strip influence matrix (induced angle at each strip per unit Cl of every strip). (3) `finite.couple_strips` solves the strips' angles on RANS polars (nonlinear lifting line on the lattice). (4) Zerihan's wing checks the strips (mid-span Cl and wing CL against the balance and pressures); frontwing#1.02 runs on SST polars at three heights. (5) The app sends the endplates' gap to the ground.

**Tech Stack:** Python 3 (numpy, scipy 1.18), SU2 via `aeroengine.wing.rans`, Swift/SwiftUI (AeroBenchKit, AeroBench app).

**Spec:** the user's request of 14 Nov 2026 ("fix as much as you can without STAR"), and the open items in `docs/validation/frontwing1/README.md` and `docs/validation/ground-3d/README.md`.

## Global Constraints

- Fix the physical, numerical or code cause before adding any correction; no fitted factors.
- Calibrated estimate numbers (estimate.py, Swift `Wing.finite3D`) do not change without the user's go-ahead.
- Never hand-build Release into build/DerivedData; Swift builds go to a scratch DerivedData path.
- Commit each task; push after the feature; `graphify update .` after code changes; never commit graphify-out/.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Validation numbers are reported as they come out, in percent, with what is not converged said.

## Review Focus

- A loop whose bracket narrows to under 0.25 deg with the gap still open on both sides: reported as a cliff, `converged` False, never a settled answer (Task 1 test).
- A strip whose angle falls outside its polar's angles: flagged, not extrapolated silently (Task 3 test).
- A strip whose angle sits in a polar segment past the lift peak: flagged as past stall (Task 3 test).
- A lattice with zero height change: identical to the current lattice (Task 2 test).
- Old app projects with no endplate gap: decode, and send nothing for it (Task 5 test).

---

### Task 1: The single-strip loop bisects and names a stall cliff

**Files:** Modify `engine/src/aeroengine/wing/rans.py` (`solve_finite`, constants); Test `engine/tests/test_wing_rans.py`.

**Interfaces:** Produces `r["finite"]["cliff"]`: None, or `{"low": deg, "high": deg, "cl_low": float, "cl_high": float}`, the two solves either side of the answer. `FINITE_SOLVES` 6.

- [ ] Test `test_finite_wing_on_a_stall_cliff_reports_the_cliff`: fake section with Cl −3.2 below +8.6 deg and +0.05 above; `finite["converged"]` False, `finite["cliff"]["low"] < 8.6 < finite["cliff"]["high"]`, `high - low <= 0.25`, solves ≤ 6.
- [ ] Test the existing loop tests still pass (settles where lift falls steeply; never settles stops).
- [ ] Implement: keep (angle, gap) of every converged solve; once two have opposite gap signs, the next angle is the bisection of the closest opposite pair; stop as a cliff when that pair is ≤ `FINITE_CLIFF` 0.25 deg apart and neither gap is under the tolerance. The answer returned is the side whose gap is smaller.
- [ ] Commit.

### Task 2: Lattice height change across the span and strip influence

**Files:** Modify `engine/src/aeroengine/wing/vlm.py`; Test `engine/tests/test_wing_vlm.py`.

**Interfaces:** `Lattice(..., drop: float = 0.0)`: the wing's height at y = −b/2 minus at y = +b/2 (m); local height `height - drop * y / b`. `Lattice.strips(n: int) -> Strips` with `Strips(y: ndarray, height: ndarray | None, width: ndarray, k: ndarray)`; `k[i, j]` is the induced angle (rad) at strip i per unit section Cl of strip j, the strip-mean Trefftz downwash over 2V. `ny % n == 0`.

- [ ] Tests: `drop=0` gives the same `solve()` as before; with `n = ny` and the lattice's own Cl, the lift-weighted mean of `k @ cl` equals `k_drag * CL` (rel 0.01); with `n = 4`, symmetric wing gives a symmetric `k`; free-air endless span gives `k` near 0; a dropped wing over a ground gives more induced angle at the high end than at the low end.
- [ ] Implement: prescribe each strip's circulation (chordwise shape from the lattice's own solve), solve the endplate panels with the wing held, Trefftz downwash at each column's centre averaged over the strip.
- [ ] Commit.

### Task 3: Strip coupling on polars

**Files:** Modify `engine/src/aeroengine/wing/finite.py`; Test `engine/tests/test_wing_finite.py`.

**Interfaces:** `couple_strips(polars: list[tuple[list[float], list[float]]], k: ndarray, width: ndarray, alpha: float) -> dict` with keys `alpha` (per strip, deg), `cl` (per strip), `cl_wing` (width-weighted), `converged`, `out_of_range` (strip indices), `past_stall` (strip indices). Section angle `a_i = alpha - degrees((k @ cl)_i)`.

- [ ] Tests: linear polars `cl = 2π a` with a one-strip `k = [[κ]]` give `cl_wing = 2π α / (1 + 2π κ)` (rel 1e-3); a strip pushed past the polar's last angle is in `out_of_range`; a polar with a peak, strip landing past it, is in `past_stall`.
- [ ] Implement with `scipy.optimize.root` (hybr) on the residual, started from the linear solution, then continuation in alpha from 0 in 10 steps if the direct start fails.
- [ ] Commit.

### Task 4: Strips on Zerihan's wing and on frontwing#1.02

**Files:** Create `docs/validation/ground-3d/strips.py`, `docs/validation/frontwing1/run_polars.py`, `docs/validation/frontwing1/run_strips.py`; Modify both READMEs.

- [ ] Zerihan: per height a two-point polar from `results.json` (two_d at the geometric angle, on_car at its effective angle), 6 strips across the full span; report wing CL and mid-span Cl against the balance and Figure 9b.
- [ ] frontwing#1.02: SST polars at 74.1, 96.6, 119.1 mm (running in the background since the plan was written), 6 strips, drop 0.045 m, endplate bottom 0.035 m; report per-strip angle, Cl, which strips stall, and the wing's CL on AeroBench's reference.
- [ ] Write both into the READMEs with what is not converged. Commit.

### Task 5: Endplate gap from the app

**Files:** Modify `app/AeroBenchKit/Sources/AeroBenchKit/WingGeometry.swift` (`endplateGap: Double?`, Codable), `app/AeroBench/AppState+Wing.swift` and `AppState+Design.swift` (send `endplate_bottom` with `finite` when a ride height is set), the Wing Lab field beside the endplate height; Swift `WingRans.Finite` decodes `endplate_bottom`, `model`, `cliff`. Test `app/AeroBenchKit/Tests/AeroBenchKitTests/WingTests.swift`.

- [ ] Tests: a wing without the key decodes with `endplateGap == nil`; the finite params carry `endplate_bottom` only with a gap and a ride height; a result with `cliff` decodes.
- [ ] Implement; the results line says "on a stall cliff between a and b" when `cliff` is set.
- [ ] `swift test` in AeroBenchKit; Debug build of the app to a scratch DerivedData. Commit.

### Task 6: Write-up

- [ ] Memory validation-status, push, `graphify update .`, report.
