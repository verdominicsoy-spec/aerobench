# Wing optimiser audit (November 2026)

The question: when Wing Lab's Study or Design card hands back a "best" wing,
is it a good wing, or just the place where the quick estimate is most wrong?
No RANS was run for this audit. It uses the quick estimate
(`aeroengine.wing.estimate`), the RANS runs already saved in
`~/Library/Application Support/AeroBench/Scratch/jobs`, and the 18 study
exports in `Scratch/wing/studies`.

## Verdict

**For angles it is a good screening tool. Its "best" is not a design to
build until RANS has checked it.** The search machinery works. Optuna
converges, seeds repeat on small problems, broken wings never win, and
separating wings never win. But the objective is the estimate's number, and
for any downforce goal that number keeps rising right up to a hard-coded
separation line. Every run therefore ends with a wing on that line. Those
lines (25 degrees of flap deflection; 9 and 13 degrees past a front element's
stall angle) were fitted on two NACA wings, and they are where the estimate
is least reliable. Of the 6 owner study bests that RANS has since run, 3
separated in RANS. On two of them the estimate read lift 28 to 49% high and
drag 3 to 6 times low. All 3 were passed as attached when their studies
ran, and today's estimate still passes 2 of them, one (design-12) with full
NeuralFoil confidence. The drag-based goals (best L/D, best efficiency) have the
opposite problem. The estimate reads attached drag 15 to 40% low. With no
endplate set, "efficiency" has no induced drag at all. So those goals reward
unloading the flap until it reaches a bound.

Use it to rank angle changes well inside the lines. Treat any pick within
about 2 degrees of a line as unconfirmed. Do not trust its gap, overlap or
L/D answers without RANS.

## How the optimiser works (what was read)

| Item | Where | What it does |
|---|---|---|
| Study job | `engine/src/aeroengine/commands/wing.py:264` `wing_optimise`, `:308` `_study` | Optuna (TPE by default, or CMA-ES). In the app each trial is the estimate (`solver="estimate"` is the default, `WingLabModel.swift:364`) |
| Design job | `commands/wing.py:425` `wing_design` | Lays out a wing in the rules box, runs an estimate study in car terms, then RANS on up to `checks` finalists |
| Trial evaluation | `commands/wing.py:348-354` `evaluate_estimate` | Returns Cl, Cd and `converged = not separating`. `trusted` and `confidence` are **dropped** |
| Downforce sign | `optimise.py:333` | `load = -cl` when element 0 is inverted. Every goal maximises load or works from it. Correct for inverted wings |
| Objectives | `optimise.py:181-213` | `max_cl` = load; `max_ld` = load/Cd (2D); `max_cla`/`max_efficiency`/`balance`/`max_cla_cda_cap` use `finite.car_contribution`; caps and targets are a penalty of 10 per unit of relative violation; `min_lap_time` runs the lap sim |
| Rules box, min gap, intersections | `geometry.py:92-108` `Wing.issues`, `optimise.py:326-329` | An invalid wing scores −1e6, is never run, and is never best (`summary` picks only `complete` and `feasible`) |
| Separating rows | `optimise.py:347-348, 360-371` | Treated like a RANS run that never settles. Once 2 real results exist, the row is told to the sampler as worst − ½·spread and shown as failed. It **cannot win** |
| Untrusted rows (NeuralFoil confidence < 0.8) | not used | Scored like any other row and **can win** |
| RANS check of finalists | `optimise.py:493-571` `check` | Re-runs the top distinct designs with RANS. A run counts as separated if RANS's skin friction says so or its Cd is more than 3× the estimate's. Off by default in Study (`checkBest = 0`, `WingLabModel.swift:366`). In Design it is 3, but silently 0 when SU2 is not set (`AppState+Design.swift:64`) |
| Calibration `scale` | `commands/wing.py:366-394` | Multiplies all lift and all drag by one constant. That cannot reorder an unconstrained goal (max Cl, max L/D, max ClA). It only matters with a cap or target |

## 1. Small problems through the real optimiser

`small_study.py` calls `optimise.run` with the same penalties and the same
estimate call as the app. Each problem ran 150 trials, with 5 TPE seeds and
3 CMA-ES seeds, in about 4 to 7 s per run.

Problem A is the overnight acceptance problem from DECISIONS.md. NACA 4412
main at 300 mm and 3 degrees, flap 140 mm, flap angle 15–45 degrees, gap
6–25 mm, most downforce. RANS's own optimum was flap 26.9 degrees, gap
9.1 mm, Cl 1.977. RANS held the flap at 28.2 degrees and separated it at
29.0 degrees.

| Problem | Best value, all seeds | Pick (spread over seeds) | Margin to the separation line | Bounds hit | Trusted |
|---|---|---|---|---|---|
| A: flap angle + gap, max Cl | 1.933–1.935 | flap 27.92–27.99°, gap 12.0–13.5 mm | **0.01–0.08°** of the 25° deflection line | none | yes |
| B: A + main angle, max Cl | 2.599–2.630 | main 11.0–11.7°, flap 33.0–36.6°, gap 8.9–13.4 mm | deflection 0.04–3.4°; main **9.0–9.6° past its stall** (the lift cap sits at 9) | none | yes |
| C: A's variables, max L/D | 50.8–58.7 | flap 15.0–15.6° (one CMA-ES seed: 22.3°), gap 20–25 mm | 12–13° | **flap = low, gap = high** | yes |
| D: 6212 over a ground, height 30–300 mm + both angles, max Cl | 3.570–3.756 | height 97–118 mm, main 4.7–11.3°, flap 21.6–24.1° | main **11.7–13.0° past stall** (separation at 13) | none | yes |

What this shows:

- **It converges and it repeats** on 2 variables: every seed lands within
  0.1% of the same value by trial 3 to 79. With 3 variables (B, D) the
  value repeats within 1 to 5%, but the design does not: main 4.7 to 11.3
  degrees in D. The top is a flat ridge, and its height there is set by the
  estimate's caps, not by the flow.
- **The downforce optimum always lands on a cliff.** In the grid of problem
  A (`small_study.json`, `grid`), the estimate's Cl rises with flap angle up
  to 28.0 degrees at every gap from 9 to 25 mm, then drops to "separating".
  Nothing in the number warns that the cliff is near. DECISIONS.md:811-813
  records the estimate's lift error on the overnight RANS trials: within 1%
  up to a 26.5 degree flap, rising to 11% at 28 degrees, which is exactly
  where all 8 seeds land. (That error was measured on an earlier version of
  the estimate. The rows behind it are not saved, so it could not be
  re-checked here.)
- **Gap is arbitrary.** Across 9 to 25 mm at 28 degrees the estimate's Cl
  changes only 1.877 to 1.936, so the 12 to 13 mm pick is noise. RANS's best
  gap was 9.1 mm, worth 6% (DECISIONS.md:842). The app's warning about gaps
  is right.
- **Max L/D runs to a corner.** In 2D the estimate's L/D gets better as the
  flap unloads, so it heads for the lowest flap angle and the widest gap.
  That is a real 2D trend, made stronger by low drag. It is not a wing
  anyone wants on a car.

## 2. The owner's saved studies

`saved_studies.py` rebuilds each study's top designs from the job that ran
it and re-runs the current estimate on them. Below is each study's best.
"Edge" means within 2 degrees of the deflection line or more than 9 degrees
past a front element's stall.

| Study | Goal | Trials | Failed (separating) | Best | Cl | Cd | Cl/Cd | Deflection margin ° | Front past stall ° | Trusted (min conf) | At bounds | Stored value reproduced | Edge |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| design-1 | max_cl | 335 | 112 | #314 | 2.901 | 0.0991 | 29 | 0.5 | 10.0 | no (0.72) | chord_1=high | yes | EDGE |
| design-2 | min_lap_time | 335 | 64 | #332 | 2.495 | 0.0775 | 32 | 0.2 | 9.1 | no (0.73) | - | yes | EDGE |
| design-3 | min_lap_time | 596 | 94 | #581 | 2.402 | 0.0808 | 30 | 0.7 | 10.2 | yes (0.83) | - | yes | EDGE |
| design-4 | max_cl | 2003 | 152 | #1223 | 2.134 | 0.0423 | 50 | 0.1 | 3.3 | yes (0.80) | angle_0=low | **NO (2.50 stored)** | EDGE |
| design-6 | max_cl | 1001 | 239 | #777 | 2.519 | 0.0409 | 62 | 0.5 | 9.4 | yes (0.98) | chord_0=high | yes | EDGE |
| design-7 | max_cl | 529 | 135 | #448 | 2.006 | 0.0696 | 29 | 4.7 | 12.8 | yes (0.95) | chord_0=high | **NO (19.5 stored; now separating)** | EDGE |
| design-8 | min_lap_time | 256 | 73 | #249 | 3.520 | 0.0849 | 41 | 6.1 | 11.7 | yes (0.95) | chord_1=low | yes | EDGE |
| design-9 | max_cla | 318 | 65 | #317 | 2.964 | 0.0638 | 46 | 3.2 | 8.5 | no (0.74) | angle_0=high | yes | |
| design-10 | max_cla | 289 | 85 | #280 | 2.554 | 0.0544 | 47 | 0.6 | 11.5 | no (0.70) | - | yes | EDGE |
| design-11 | max_efficiency | 745 | 20 | #729 | 2.700 | 0.0214 | 126 | 12.5 | 1.4 | yes (0.96) | - | yes | |
| design-12 | max_cla | 687 | 231 | #455 | 3.748 | 0.0736 | 51 | 0.6 | 12.9 | yes (0.95) | yfrac_0=high | yes | EDGE |
| design-13 | max_efficiency | 1906 | 48 | #1733 | 2.942 | 0.0165 | **178** | 19.6 | -0.6 | yes (0.97) | angle_1=low, chord_1=low | yes | |
| study-1 | max_cl | 607 | **599** | #0 (the start) | 2.468 | 0.0526 | 47 | 0.6 | 11.4 | no (0.70) | camber_*=low | yes | EDGE |
| study-2 | max_cl | 627 | 161 | #483 | 2.845 | 0.0805 | 35 | 0.4 | 12.9 | no (0.71) | gap_1=low, thickness_4=high | yes | EDGE |
| study-3 | max_ld | 336 | 0 | #300 | 1.715 | 0.0139 | 124 | 12.2 | -1.1 | yes (0.94) | - | yes | |
| study-4 | max_ld | 1524 | 0 | #1263 | 1.966 | 0.0152 | 130 | 10.9 | -1.1 | yes (0.95) | angle_1=high | yes | |
| study-5 | max_ld | 1194 | 0 | #966 | 1.937 | 0.0163 | 119 | 12.2 | 0.4 | yes (0.95) | angle_0=low, overlap_1=low | yes | |

(design-5 is left out: no finished job is left to rebuild it from.)

- **11 of the 12 downforce and lap-time bests sit on an edge**, and the
  twelfth (design-9) is 3 degrees from one. 6 of the 17 bests rest on
  NeuralFoil answers it does not trust (confidence 0.70 to 0.74).
- **16 of the 17 studies have no RANS check at all.** Their finalists
  are estimate numbers only.
- The section shortlist picks sections by NeuralFoil's maximum lift
  (`design.py:83-95, 228-241`). So the studies keep choosing S1223, FX 74,
  GOE 523/652 and S1221. On the tunnel data the estimate reads these
  high-camber sections' lift 10 to 21% high, S1223 worst
  (DECISIONS.md:1129-1131).
- **Old studies show numbers from an older estimate.** design-4 shows 2.50
  where the current estimate says 2.13. design-7 shows Cl 19.5, from the
  ground model before `ground_share`, on a wing the current estimate calls
  separating. The export does not record which estimate wrote it, and a
  resume checks only the variables, objective and solver
  (`optimise.py:257-262`). So a resumed study can mix values from two
  versions of the model.

## 3. The estimate against RANS

`rans_vs_estimate.py` takes every saved `wing-rans` result, runs the
estimate on exactly that geometry and flow, and matches each run to the
study trial it checked. "Out of sample" excludes `validation.RANS_REFERENCES`,
the runs the estimate's corrections were fitted to.

| Case | Study trial | Mesh/model | RANS Cl | RANS Cd | RANS state | est Cl | est Cd | Cl err | Cd err | L/D err | est separating | trusted | defl margin | front past stall |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 5-el start | design-10 #0 | medium/sa | 1.236 | 0.0312 | not converged | 1.416 | 0.0387 | +15% | +24% | -8% | no | no | 1.0 | 1.9 |
| 3-el FX74 | design-4 #1223 | quick/sa | 1.980 | 0.0340 | attached | 2.134 | 0.0423 | +8% | +24% | -13% | no | yes | 0.1 | 3.3 |
| same, study's own check | design-4 #1223 | quick/sa | 2.330 | 0.0408 | not converged | 2.134 | 0.0423 | -8% | +4% | -12% | no | yes | 0.1 | 3.3 |
| 3-el FX74/S1221 | design-6 #777 | quick/sa | 2.469 | 0.0464 | attached | 2.386 | 0.0387 | -3% | -17% | +16% | no | yes | 0.5 | 9.4 |
| 2-el, 30 mm ground | design-7 #448 | quick/sa | 1.809 | 0.5136 | **separated** (Cd 6×) | 2.478 | 0.0860 | +37% | -83% | +718% | yes (now) | yes | 4.7 | 12.8 |
| 5-el, 707 mm | study-2 #483 | medium/sst | 2.793 | 0.0863 | **separated** (main, 67% chord) | 2.849 | 0.0807 | +2% | -6% | +9% | no | no | 0.4 | 12.9 |
| 3-el S1223, 161 mm | design-12 #455 | fine/sst | 2.431 | 0.3073 | **separated** (flap) | 3.620 | 0.0711 | +49% | -77% | +543% | no | yes | 0.6 | 12.9 |
| same | design-12 #455 | fine/sst-lm | 2.829 | 0.2127 | **separated** (flap) | 3.620 | 0.0711 | +28% | -67% | +283% | no | yes | 0.6 | 12.9 |
| 2-el FX74/GOE | study-4/5 best (2.0°, 14.83°) | quick/sst | 1.852 | 0.0274 | attached | 1.949 | 0.0164 | +5% | -40% | +76% | no | yes | 12.2 | 0.4 |
| same | same | fine/sst-lm | 1.897 | 0.0194 | attached | 1.949 | 0.0164 | +3% | -15% | +21% | no | yes | 12.2 | 0.4 |
| flap at 92.5° (test) | - | quick/sst(-lm) | 1.63–1.73 | 0.27–0.32 | separated | 2.499 | 0.1487 | +44–53% | -44–53% | | yes | no | | |

| Set | n | Cl error | Cd error | Spearman Cl / Cd / L/D |
|---|---|---|---|---|
| Out of sample, RANS attached and converged | 5 | mean 4.4%, max 7.8% | mean −13%, range −40 to +24% | 0.89 / 0.78 / 0.78 |
| Out of sample, every RANS result (last iterate if unconverged) | 11 | mean 15%, max 49% | mean −24%, range −83 to +24% | 0.74 / 0.93 / 0.70 |
| Fit set (`RANS_REFERENCES`), in sample | 7 | mean 1.7%, max 4.2% | mean +1%, −4 to +9% | 0.95 / 0.99 / 0.99 |

- Where RANS stays attached, lift is good: within 8%, and it ranks lift
  well. Drag is not: it reads 15 to 40% low on the study-4/5 L/D pick, and
  that pick's L/D reads 21 to 76% high. So an L/D goal is chasing a drag
  artefact. The 1 to 4% figures quoted elsewhere come from the fit set and
  are in sample.
- 6 out-of-sample RANS runs separated or did not settle. **The estimate
  called 1 of them separating (design-7, and only after a later fix) and
  flagged 2 as untrusted.** Every one of the 6 is either within 2 degrees of
  the deflection line or more than 9 degrees past a front element's stall.
  That margin flags them all, though it also flags 2 of the 3 attached
  study bests (design-4 and design-6, which RANS held). So it is a
  conservative "needs RANS" test, not a separation predictor. The flags the
  optimiser uses flag none of the 6.
- Estimate version 7 (19 Nov 2026) judges the last element on its pressure
  side too: met by the flow from that side, it separates once the peak there
  passes 9 (`estimate.PRESSURE_PEAK_LIMIT`). Rerun on every saved RANS result
  it calls 3 of the 8 out-of-sample runs that separated or did not settle
  separating (design-7, and two single elements set the wrong way, added
  since), with no attached run called separating. Version 5 had the rule on
  every element and called design-12 too, but RANS reruns with its Flap 1
  turned 2.3 to 14 degrees past the main stalled that flap from its suction
  side every time, so the reason it gave was wrong (DECISIONS.md, 19 Nov).
  Still missed: design-12 and study-2, both with the main 5 to 7 degrees past
  its stall in place, where others held 4 to 14; only RANS tells them apart.
- The rank numbers come from 5 to 11 different wings across studies, not
  from the trials of one study. Read them as a sanity check, not a measure.
  The 22 RANS trials of the overnight study, on which DECISIONS.md quotes a
  drag rank correlation of 0.985, are no longer saved.

## 4. Risks, with evidence

1. **The objective has its peak on the separation line.**
   `estimate.py:65-73` (FRONT_LIFT_LIMIT 9, FRONT_SEPARATION 13,
   MAX_DEFLECTION 25) and `estimate.py:216-231` are hard on/off tests. Lift
   below them shows no fall-off as separation nears, and the optimiser is
   told nothing until a row crosses the line (`optimise.py:347`). Evidence:
   all 8 seeds of problem A sit within 0.08 degrees of the line; 11 of 12
   saved downforce bests are on an edge; 3 of 6 RANS-checked bests
   separated (design-7, design-12, study-2), with the estimate up to 49%
   high on lift and up to 83% low on drag.
2. **Drag reads low, so drag-based goals chase an artefact, and efficiency
   has no induced drag.** Attached drag reads −15 to −40% on the L/D pick,
   and up to −83% on separated picks. A front element's drag is held at
   stall onset plus a fitted growth (`estimate.py:189-191, 243-244`). With
   no endplate height, `finite.car_contribution` (`finite.py:26-27`) scales
   Cl and Cd by one factor and adds no induced drag. So `max_efficiency`
   ranks 2D L/D: design-11 and design-13 report 126 and 178, with the flap
   angle and flap chord at their lower bounds. `max_ld` (Study) is 2D by
   definition and heads for a corner of the bounds (problem C).
3. **Nothing stops an unconfirmed or untrusted row from becoming "the
   answer".** `evaluate_estimate` drops `trusted` (`commands/wing.py:353`).
   Study runs no RANS check unless asked (`WingLabModel.swift:366`). Design
   quietly runs 0 checks without SU2 (`AppState+Design.swift:64`) and then
   lists 5 estimate-only finalists (`commands/wing.py:562-566`). The section
   shortlist goes after the very sections whose lift the estimate
   overpredicts most. 16 of 17 saved studies were never checked.
4. Smaller ones:
   - Gap and overlap barely move the estimate, so their optimum is arbitrary
     (problem A grid).
   - Stale study values are shown and can be resumed (design-4, design-7;
     `optimise.py:257-262`).
   - The 3× drag test for "separated" in `check` (`optimise.py:45, 552`)
     would have passed design-12 at 3.0× under SST-LM, had RANS's own
     separated flag not caught it.
   - The single-anchor `scale` cannot change an unconstrained ranking.
   - Ground effect: D's picks (97–118 mm, main up to 11 degrees) are well
     outside the one ground wing RANS checked (main 3 degrees, at 300, 150
     and 60 mm). The only RANS of an optimiser ground pick (30 mm) separated
     with Cd 0.51.

## 5. Recommended guards (1 to 4 and 6 are now in: see After the guards)

1. **Score a margin, not a line.** Give each separation test a soft penalty
   that starts about 2 degrees before the line. For example, take
   load × (1 − k·max(0, 2 − margin)²) for the deflection margin and for
   "front element past stall − 7". Or simply shrink MAX_DEFLECTION by 2
   degrees and FRONT_SEPARATION to 10 for scoring only, and keep the real
   lines for the separating verdict. Either way the pick moves back to where
   RANS held (26.9 degrees in problem A).
2. **Penalise untrusted rows.** Pass `trusted` and the minimum `confidence`
   through `evaluate_estimate`. Treat a row below 0.8 like a separating one,
   or mark it infeasible so `summary` cannot pick it as best.
3. **Require RANS on the finalists.** Make `checkBest` default to 3 with
   `until_pass`. Have Design say plainly "no RANS check: estimate only" when
   SU2 is missing, rather than quietly running 0. Show estimate-only
   finalists as unconfirmed, and never put one on the canvas by "Load Best"
   without saying so.
4. **Put induced drag in efficiency.** Refuse `max_efficiency` without an
   endplate height (or a typed AR). Or apply CL²/(πAR) with the typed factor
   as well. Label `max_ld` as 2D section L/D in the Study picker.
5. **Show the edge in the results.** Export the deflection margin and the
   front element's distance past stall with each trial. Flag any finalist
   within 2 degrees, and any finalist on a bound, so the user sees "this
   pick is on the model's limit" next to the number.
6. **Stamp studies with the estimate version.** Store the engine commit or
   a hash of the estimate constants in the study's `spec`. Refuse a resume
   across versions, and re-score or grey out stale exports on load.
7. **Keep the RANS rows.** Save every RANS check (geometry, flow, Cl, Cd,
   separated) to one log, so the estimate's ranking can be re-measured as
   it changes. Today the 22 overnight RANS trials behind the headline
   numbers are gone.

## After the guards

Guards added the same night (engine `wing/optimise.py`, `wing/estimate.py`;
app Wing Lab). The estimate itself is unchanged.

1. **A margin, not a line.** `optimise.separation_margin` gives an estimate
   row's degrees to its nearest line: a flap 25 degrees past the element in
   front or past the main, or a front element 9 degrees past its stall (where
   its lift stops growing). `optimise.score` takes `MARGIN_COST` x
   ((2 − margin)/2)² of the load off when the margin is under 2 degrees:
   nothing from 2 degrees out, half the load on the line, smooth in between.
   RANS checks have no margin and are scored as before.
2. **Untrusted rows fail.** `optimise.from_estimate` (the trial's view of an
   estimate row, used by `commands/wing.py` and `small_study.py`) fails a row
   NeuralFoil does not trust, like a separating one, with the element and its
   confidence as the reason.
3. **Version stamp.** `estimate.VERSION` (1) goes in an estimate study's
   `spec`. A resume of an estimate study scored by another version, or from
   before versions, is refused: "start a new study (another name)". So every
   saved study above must be started again under a new name.
4. **Efficiency counts induced drag.** With no endplate height,
   `max_efficiency` adds ClA²/(π b²) to CdA (lifting line on the typed span).
   The shown CdA is unchanged. `max_ld` is now "Best L/D (2D section)".
5. **App.** The Study header and results card mark a best no RANS run has held
   "unconfirmed" (`WingStudy.isConfirmed`), and the Design card's
   estimate-only finalists read "unconfirmed: estimate only". Study checks the
   best 3 with RANS by default when SU2 is set up. Without SU2 it runs no
   checks and says the best is unconfirmed.

`small_study.py` again, same seeds and trials (`small_study_after.json`;
before: `small_study.json`):

| Problem | Best value before → after | Pick before → after | Margin to the nearest line before → after |
|---|---|---|---|
| A: flap + gap, max Cl | 1.933–1.935 → 1.89 | flap 27.92–27.99° → **26.01–26.08°** | deflection 0.01–0.08° → **1.92–1.99°** |
| B: + main angle | 2.60–2.63 → 2.46–2.47 | main 11.0–11.7°, flap 33.0–36.6° → main 9.9–10.8°, flap 31.1–32.7° | main 9.0–9.6° past stall → **7.1–7.2°**; deflection 2.6–3.9° |
| C: max L/D | 50.8–58.7 → unchanged | flap 15.0–15.6° (one 22.3°) | unchanged: far from any line, still at the bounds (2D L/D) |
| D: over a ground | 3.57–3.76 → 2.95–3.18 | main 4.7–11.3°, flap 21.6–24.1° → main 2.1–10.7°, flap 15.4–21.0° | main 11.7–13.0° past stall → **7.0–7.3°** |

Problem A's pick now sits at 26.0 degrees, inside what RANS held (to 28.2;
RANS's own optimum 26.9, Cl 1.977). The estimate's best Cl falls 2% (A) to
16% (D), which is the price of staying where the estimate has been checked.
Separating trials fall too (A: 32–60 to 10–30 of 150). C does not move: the
margin cannot help a goal whose optimum is a 2D drag artefact at a bound.
Not re-checked with RANS: whether the new picks for B and D hold.

## Files

- `common.py`: job and study loading, the estimate call as a trial makes it, flags
- `saved_studies.py` → `saved_studies.json`: section 2
- `small_study.py` → `small_study.json`: section 1 (optimiser runs and the problem A grid); `small_study_after.json`: the same after the guards
- `rans_vs_estimate.py` → `rans_vs_estimate.json`: section 3

Run each from `engine/`: `uv run python ../docs/validation/optimiser/<script>.py`.
Each one takes under 4 minutes and none runs RANS.

## Estimate version 2 (9 November 2026)

Everything above was measured on estimate version 1. Version 2 finds effective
angles on the panel solver, closes blunt trailing edges and refits the
front-element limits (`docs/validation/published/README.md`). Separation lines in
degrees moved with it, so the picks and margins quoted above may have moved too.
The audit was not rerun. The margin test
(`test_the_estimate_study_keeps_off_the_deflection_line`) still passes.
