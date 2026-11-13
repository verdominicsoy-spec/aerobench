# RANS You Can Trust: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wing Lab's RANS tells you what the wing will do on the car: where it separates, how much downforce it makes there, and how sure that answer is.

**Architecture:** Fix the physics and numerics that make the 2D RANS answer wrong first (turbulence that never reaches the wing, a separation check that hides separation), then run the section at the angle it sees on the car (lifting-line induced angle, ground included), then bracket the one modelling choice that flips the answer (transition against fully turbulent). Re-validate everything at the end and put the real numbers in the app.

**Tech Stack:** Python engine (`engine/src/aeroengine/wing/`), SU2 8.5 (`build/su2`), SwiftUI app (`app/AeroBench`, `app/AeroBenchKit`), pytest, XCTest.

**Spec:** this document. The evidence it argues from is the "Diagnosis" section below, measured on the user's run `~/Documents/frontwing#1/jobs/20261112-182154-318a`.

---

## Diagnosis (13 Nov 2026)

The user's case: 4-element inverted front wing (main −10.5°, flaps 2.5°, 22°, 34.5°), 20 m/s, 682 mm total chord, span 1 m, no endplate set (3D factor 1).
AeroBench: 2D, free air, SST-LM, fine mesh: Cl −2.37, Cd 0.033, "Flap 1 separates from 74%", nothing else.
STAR-CCM+: 3D on the car, moving ground, fully turbulent k-ω SST: the **main element separates on its upper (pressure) side**.

Root causes found, largest first:

1. **The section runs at the wrong angle.** RANS always runs the 2D section at its full geometric angle. On the car the wing is 1 m span on 0.68 m chord (AR 1.5). Its trailing vortices drop the angle every section sees by several degrees (lifting line: α_i = C_L / (π AR_eff)). `finite.py` only scales the lift afterwards (AR/(AR+2)), so the separation verdict is for an infinite wing. For a main already at −10.5°, a lower effective angle loads its upper surface leading edge: the separation STAR shows. With the 3D factor left at 1 the app also shows about twice the downforce this wing makes on the car.
2. **The turbulence you type never reaches the wing.** Tu is set to 1% at the far field 50 chords out and SST decays it on the way in: measured in the solution (SU2 writes the fields nondimensional, on |V|), 0.45% at 30 m upstream and **0.14% at the wing**, 7 times less. With SU2's sustaining terms (`SST_OPTIONS= SUSTAINING`, in the build) the same run holds 0.97–1.00% all the way to the wing. Without them every SST-LM run is a quieter tunnel than the one asked for: longer laminar runs and bigger laminar bubbles.
3. **The separation check hides separation.** `rans.separation` ignores the first 5% of chord (so a leading-edge stall would be missed), ignores anything not reversed at 95% chord, and needs more than 15% of chord reversed. On this run it reported Flap 1 only. The solution also has: Flap 2 reversed 42–68% of chord on its suction (lower) side; Flap 3 reversed 39–65% and again 85% to the trailing edge (a real trailing-edge separation, 15% of chord measured to the edge, but only 10% up to the 95% point it measures from). It reads the x component of skin friction, not the component along the surface, and measures from the geometric nose, not the stagnation point. In 2D the main is attached on both surfaces.
4. **The comparison was not like for like.** The AeroBench run was free air, STAR had a moving ground; nothing in the app pointed that out for a front wing.

Diagnostic runs on the same mesh, free air, 0° (reversed flow from tangential skin friction, % of each element's chord, suction = lower surface):

| Run | Tu at wing | Cl | Cd | Main | Flap 1 | Flap 2 | Flap 3 | Residual (log rms P) |
|---|---|---|---|---|---|---|---|---|
| As run (SST-LM) | 0.14% | −2.371 | 0.0327 | attached | 74–97% | bubble 42–68% | bubble 39–65%, sep. 85%–TE | −7.7 |
| SST-LM, sustained | 1.0% | −2.385 | 0.0302 | attached | bubble 80–90% | 96%–TE | bubble 42–58%, sep. 83%–TE | −9.1 |
| SST fully turbulent, sustained (STAR's model) | 1.0% | −2.334 | 0.0341 | attached | attached | 94%–TE | sep. 79%–TE | −11.9 |
| SST fully turbulent, sustained, flow +10° (a 3D induced angle) | 1.0% | −1.390 | 0.0297 | **upper (pressure) surface reversed 1–91%** | attached | 96%–TE | sep. 86%–TE | −12.0 |

What this shows: the turbulence fix alone removes Flap 2's 26%-chord bubble and most of Flap 1's separation, so it changes the answer. The model choice moves lift 2% and drag 13%. None of the 2D runs at 0° separates the main. At +10°, about the induced angle lifting-line theory gives this wing in free air without endplates (12°; less with endplates and over a ground), the main separates on its upper surface as in STAR and its Cl falls from −1.02 to −0.27. Today's check would miss even that: the flow reattaches at 91%, before the 95% point it measures from. So root causes 1 and 3 together explain the miss; the plan fixes both.

What this plan cannot fix: 2D (or 2.5D) RANS has no car nose upwash, wheel wake, endplate vortex or spanwise variation. The quasi-3D answer is the mid-span section on the car. That limit is stated in the app, not hidden.

## Global Constraints

- Fix root causes; no fitted scale factors or offsets added (memory: fix-root-physics). Published formulas (lifting line, Wieselsberger ground factor) are physics, not fits.
- Changes to calibrated estimate numbers (0.94 NeuralFoil scale, SLAT_PEAK_LIMIT, flap limits) need the user's go-ahead.
- Every RANS result carries `rans_version: 3`; results without it are labelled "before the turbulence fix" in the app.
- Old result JSON keys (`separated`, `separation`, `cl`, `cd`, `elements`) keep their meaning so the optimiser and saved studies still load.
- Commit each task; push after the RANS physics phase and at the end.

## Review Focus

1. A wing that stalls the main on its pressure side at the leading edge: the check must report it (the first 5% of chord is no longer skipped).
2. An inverted wing: "upper" and "lower" in the report must match the screen, and "suction"/"pressure" must follow the load, not the y axis.
3. The 3D loop on a wing that separates: it must stop after 4 solves and report the last angle, not loop or diverge.
4. A wing with no span or endplate: the 3D run must refuse with a message naming the missing input, not run with AR = ∞.
5. Old saved runs and studies (no `rans_version`, no `regions`): they load and show as before the fix.

---

## Phase 1: RANS physics and the separation check

### Task 1: Freestream turbulence reaches the wing

**Files:**
- Modify: `engine/src/aeroengine/wing/su2.py` (the `sst` and `sst-lm` model blocks in `config`)
- Modify: `engine/src/aeroengine/wing/rans.py` (`solve` result)
- Test: `engine/tests/test_wing_rans.py`

**Interfaces:**
- Produces: result keys `tu_at_wing` (float, fraction) and `rans_version` (int, 3).
- Produces: `rans.tu_at_wing(vtu: Path, placed: list[np.ndarray]) -> float`: Tu = √(2k/3)/|V| sampled half a reference chord ahead of the most forward leading edge, on the flow direction. Both k and V from flow.vtu, which SU2 writes nondimensional (`INC_NONDIM= INITIAL_VALUES`), so the ratio needs no scaling.

- [ ] **Step 0:** Check `field.py`, `rans.y_plus` and the app's field view for the same nondimensional trap (a Pressure of −0.52 is p/(ρU²), not Pa). Fix any value shown in physical units.
- [ ] **Step 1:** Test `test_config_sustains_freestream_turbulence`: `su2.config(Case(..., model="sst"), "m.su2")` and `model="sst-lm"` both contain `SST_OPTIONS= SUSTAINING`; `model="sa"` does not.
- [ ] **Step 2:** Test `test_tu_at_wing_reads_the_set_value` (SU2 integration, skipped without SU2, quick mesh NACA 0012, Tu 1%): `0.008 < result["tu_at_wing"] < 0.012`.
- [ ] **Step 3:** Run both, see them fail.
- [ ] **Step 4:** Add the option line; add `tu_at_wing` and `rans_version` to the result.
- [ ] **Step 5:** Run `cd engine && .venv/bin/pytest tests/test_wing_rans.py -q`: pass.
- [ ] **Step 6:** Commit "Wing Lab RANS: the turbulence you set reaches the wing".

### Task 2: A separation check that reports what the flow does

**Files:**
- Modify: `engine/src/aeroengine/wing/rans.py` (`surface_cf`, `separation`, new `regions`)
- Create: `engine/tests/data/frontwing1_cf.json` (each element's (s, cf_t, side) from the user's run, about 5,000 rows, a few hundred kB)
- Test: `engine/tests/test_wing_rans.py`

**Interfaces:**
- `surface_cf` returns columns (s, cf along the surface from leading to trailing edge, side), where s is arc length from the stagnation point over the surface length, so the leading edge is no longer cut off. Side is `1` for the surface that faces +y on screen.
- `regions(cf_by_element, inverted: list[bool]) -> list[dict]`, each `{"element": int, "surface": "upper"|"lower", "loaded": "suction"|"pressure", "kind": "leading-edge bubble"|"bubble"|"trailing-edge separation"|"leading-edge stall", "start": float, "end": float}` (fractions of chord).
- `kind`: a reversed run reaching the trailing edge is `trailing-edge separation`; one starting within 5% of the stagnation point and longer than 30% of chord, or reaching the trailing edge, is `leading-edge stall`; a shorter one there is `leading-edge bubble`; any other closed run is `bubble`.
- `separation(regions) -> (bool, str | None)`: separated when any `trailing-edge separation` spans more than 2% of chord or any `leading-edge stall`. The message names every such region, e.g. "Main separates on its upper (pressure) surface from the leading edge; Flap 3 from 85% of its chord."
- Result gains `regions`; `separated` and `separation` keep their types.

- [ ] **Step 1:** Tests on synthetic Cf: a bubble 30–40% that reattaches → one `bubble`, not separated; reversed 85–100% → `trailing-edge separation`, separated (today's 15% bar would miss it); reversed from 0.5% to 100% → `leading-edge stall`; reversed 1–91% then reattached (the main at +10° in the diagnosis) → `leading-edge stall`, separated: a bubble longer than 30% of chord is a stall whether or not it closes.
- [ ] **Step 2:** Test on the fixture: Main attached on both surfaces (the strip between nose and stagnation point is not reversed flow), Flap 1 trailing-edge separation from about 74%, Flap 2 bubble about 42–68%, Flap 3 bubble about 40–65% and trailing-edge separation from about 85%; `separated` true; message names Flap 1 and Flap 3.
- [ ] **Step 3:** Run, see them fail.
- [ ] **Step 4:** Implement. Stagnation point: the wall point of largest Cp near the leading edge. Merge reversed runs closer than 0.5% of chord.
- [ ] **Step 5:** Run the test file and `tests/test_wing_optimise.py`: pass.
- [ ] **Step 6:** Commit.

Effect to note in the commit: optimiser RANS checks will mark more wings as separated than before; that is the point.

### Task 3: Surface spacing where the flow decides, not where NeuralFoil guessed

**Files:**
- Modify: `engine/src/aeroengine/wing/mesh.py`, `engine/src/aeroengine/wing/rans.py` (zones)
- Test: `engine/tests/test_wing_rans.py`

Today the fine surface spacing goes only where NeuralFoil, on each element alone at its own angle, says the flow is laminar. For the flaps that is wrong (slot flow): Flap 2 was given coarse spacing from 3.6% of chord, and its bubble sat at 42–68%.

**Interfaces:**
- `Settings.transition` stays for the transition model; surface spacing becomes `surface_fine` on the whole suction surface and the first 15% of the pressure surface of every element, `surface_coarse` only on the rest of the pressure surface.

- [ ] **Step 1:** Test `test_suction_surface_is_fine_everywhere`: mesh the frontwing#1 geometry at `medium`; the largest surface edge on each suction surface ≤ 1.05 × `surface_fine` × chord.
- [ ] **Step 2:** Fail, implement, pass. Record the cell count change in the commit message (expect +10–25%).
- [ ] **Step 3:** Commit.

### Task 4: Re-run the user's case (checkpoint)

- [ ] **Step 1:** Run frontwing#1 with Tasks 1–3, SST-LM and SST, free air. Save Cl, Cd, regions to `docs/validation/frontwing1/README.md`.
- [ ] **Step 2:** Push. Stop and show the user before Phase 2.

## Phase 2: The angle the wing sees on the car

### Task 5: Quasi-3D RANS at the induced angle

**Files:**
- Modify: `engine/src/aeroengine/wing/finite.py`, `engine/src/aeroengine/wing/rans.py`, `engine/src/aeroengine/commands/wing.py`
- Test: `engine/tests/test_wing_finite.py`, `engine/tests/test_wing_rans.py`

**Interfaces:**
- `finite.ground_factor(ride_height: float | None, span: float) -> float`: 1 in free air; over a ground 1 − σ with Wieselsberger's σ = (1 − 1.32 h/b)/(1.05 + 7.4 h/b), h/b clamped to [0.033, 0.25] where the formula holds, h from the wing's lowest point.
- `finite.induced_angle(cl: float, span: float, chord: float, endplate: float, ride_height: float | None) -> float` (degrees, sign that unloads the wing): `degrees(cl / (π AR_eff)) × ground_factor`.
- `rans.solve` accepts `params.finite = {"span": m, "endplate": m}`. With it: solve at α; first guess α_i = induced_angle(Cl₂D·AR/(AR+2)); then α_eff = α − α_i, solve, α_i ← induced_angle(Cl(α_eff)) with relaxation 0.7; restart from the last solution on the same mesh (free air: flow angle change; ground: a new mesh, so restart only in free air); stop when |Δα| < 0.1° or after 4 solves.
- Result gains `finite: {"alpha_effective", "induced_angle", "aspect_ratio_effective", "solves", "cd_induced"}`; `cl`, `cd`, `regions` are those at α_eff, `cd` includes `cd_induced = Cl² /(π AR_eff) × ground_factor`.
- `finite.car_contribution` uses the 3D result directly (no AR/(AR+2) on top) when the result has `finite`.

- [ ] **Step 1:** Formula tests: AR_eff 2, Cl −2 → |α_i| = 18.2°; ground at h/b 0.1 → factor 1 − 0.485 = 0.515 (σ = 0.868/1.79).
- [ ] **Step 2:** Loop test with a stub solver (`cl = 0.11·(α_eff + 12)`, linear, per degree) converging to the closed-form fixed point within 0.1° in ≤ 4 solves; a stub that never settles stops at 4 and says so.
- [ ] **Step 3:** Refusal test: `finite` without span → `EngineError` naming span.
- [ ] **Step 4:** Fail, implement, pass.
- [ ] **Step 5:** Commit.

### Task 6: The app runs the wing as it sits on the car

**Files:**
- Modify: `app/AeroBench/AppState+Wing.swift` (RANS params), `app/AeroBench/WingLabModel.swift`, `app/AeroBench/Views/WingLabView.swift`, `app/AeroBench/Views/AccuracyHelpView.swift`
- Test: `app/AeroBenchKit/Tests/AeroBenchKitTests/` (params encoding)

- [ ] **Step 1:** RANS settings gain *On the car (3D)*, on by default when span and endplate are set; it sends `finite`. With the 3D factor at 1 and no endplate, the result strip says "2D section: about AR/(AR+2) of this on the car" with the number.
- [ ] **Step 2:** A front wing (`rulesFor == front`) run in free air shows "Free air: on the car this wing runs over the ground. Set a ride height to compare with a car CFD."
- [ ] **Step 3:** The RANS result shows α_eff and the regions list in words ("Main: upper (pressure) surface separated from the leading edge").
- [ ] **Step 4:** Build (`xcodebuild` Debug, as before), run AeroBenchKit tests, commit.

## Phase 3: How sure the answer is

### Task 7: Transition bracket

**Files:**
- Modify: `engine/src/aeroengine/wing/rans.py`, app result view
- Test: `engine/tests/test_wing_rans.py`

The single choice that flips this kind of answer is laminar against turbulent boundary layers. Car CFD (STAR here) is normally fully turbulent; the track sits somewhere between.

**Interfaces:**
- Param `bracket: bool` (default true for a single run, false in sweeps and optimiser checks). After the SST-LM solve, a fully turbulent SST solve restarts from it on the same mesh.
- Result gains `bracket: {"sst": {"cl", "cd", "regions", "separated", "converged"}}` and `transition_decides: bool` (the separated verdicts differ, or Cl differs by more than 5%).

- [ ] **Step 1:** Test with a stubbed SU2 runner: two solves, the second with `KIND_TRANS_MODEL` absent and `RESTART_SOL= YES`; `transition_decides` true when the stub's verdicts differ.
- [ ] **Step 2:** Fail, implement, pass.
- [ ] **Step 3:** App: the result strip shows both (e.g. "Cl −2.37 (transition) / −2.21 (turbulent)"); when `transition_decides`, a warning: "Whether this separates depends on the boundary layer being laminar or turbulent. Car CFD is usually fully turbulent."
- [ ] **Step 4:** Commit.

### Task 8: Skin friction plot and separation on the canvas

**Files:**
- Modify: `app/AeroBench/Views/WingLabView.swift` (results tab next to Cp), the canvas outline drawing.
- Engine already returns per-element surface Cp; add `cf` to each `surface` entry in `rans.surface_cp`'s output (same points).

- [ ] **Step 1:** Engine test: every `surface[i]` has `cf` with the same length as `x`.
- [ ] **Step 2:** App: Cf against x/c per element, reversed flow shaded; each region drawn as a red band on the element's outline on the canvas.
- [ ] **Step 3:** Build, commit.

## Phase 4: Prove it

### Task 9: Re-run the validation with the fixes

- [ ] **Step 1:** `docs/validation/rans-references/run.py`, `published/` (30P30N, NLR 7301), `uiuc-transition` fine (about 4 h on 12 cores, in the background). Tables updated in each README, old numbers kept beside the new.
- [ ] **Step 2:** Re-test the "turbulent shape factor 1.9" root cause in `published/README.md` with sustained turbulence. If the drag error falls, say so and propose (not apply) removing the 0.94 NeuralFoil scale.
- [ ] **Step 3:** Update `README.md` accuracy tables, `AccuracyHelpView.swift`, memory `validation-status`.
- [ ] **Step 4:** Commit, push.

### Task 10: A 3D ground-effect wing with published data

- [ ] **Step 1:** Find tabulated data for a wing with endplates in ground effect at FS Reynolds numbers: first choice Zerihan & Zhang's single-element wing (Southampton, Re about 4.6e5, forces against h/c and mid-span Cp); else Zhang & Zerihan's double-element wing. If no table is reachable, say so and skip.
- [ ] **Step 2:** `docs/validation/ground-3d/run.py`: quasi-3D RANS at their heights; table of Cl, Cd and where it separates against theirs.
- [ ] **Step 3:** Commit.

### Task 11: Your STAR-CCM+ run as a test case

Needs from the user (STAR exports): front-wing forces (downforce, drag) with span and endplate; an XY plot at mid-span of pressure coefficient and wall shear stress (x component in the wing's chord direction) against x, per element, as CSV; ride height and car pitch.

- [ ] **Step 1:** `docs/validation/starccm/compare.py`: reads those CSVs and an AeroBench result, overlays Cp and Cf, prints force differences and the separation regions of both.
- [ ] **Step 2:** Run frontwing#1 in AeroBench at STAR's conditions (ground, ride height, 3D on, both models), compare, write the README.
- [ ] **Step 3:** Commit, push.
