# Design card: one run from rules box to RANS-checked finalists

Date: 2026-11-05. Status: approved.

## Intent

Designing a wing in Wing Lab is too much back and forth: the user's words,
"literally everything, cfd, rans, the car". Today it takes a starter job, a
Study, RANS checks, saving a card and placing it on the car, each a trip of
its own. The user wants one way to get a good wing, very intuitive but
customizable. It must reliably give the best design for the goal they set,
and the user picks the final design themselves.

A second problem feeds the first: the wings Wing Lab makes don't use the
space the rules allow. The starter begins at a fixed 440 mm total chord and
only shrinks (the front box is 700 mm long). The Study lets chords move only
±25%. "Most downforce" scores Cl, which is divided by the wing's own chord,
so a bigger wing scores no better. From scratch and from an existing wing
should both maximise the area the wing is allowed to use.

## Goals

- **A Design card** at the top of Wing Lab's inspector (mockup A, the user's
  pick). Every setting is a chip with a default, changed in place:
  - **End**: front or rear wing. With a base car it uses the car's rules box
    for that end and the car's ride height there; without one, Wing Lab's
    own box and ride height.
  - **Elements**: 2 to 5.
  - **Goal** (the user's list):
    - most downforce (ClA);
    - best efficiency (ClA/CdA);
    - fastest lap (the Lap Sim's track);
    - most downforce under a drag limit (a CdA you type);
    - hit an aero balance: the most downforce that keeps the car's rear
      share at a target you type (needs a base car; within ±1% of the
      target counts as on it).
  - **Start**: from scratch, or from the wing on the canvas.
  - **RANS check**: the best 1, 3 or 5 (default 3).
  - **More**: everything the Study has today (trials, sections, variable
    ranges, mesh, model, speed, sampler).
- **One Design button** runs the whole chain as one engine job,
  `wing-design`, with one progress line in the card and one entry in Jobs.
  Cancel and resume work as for any job.
- **Fill the box.** From scratch, the layout grows until it just fits the
  box (not only shrinks). From the canvas wing, each chord may grow up to
  what the box allows. The goal is scored in car terms (ClA, CdA per the
  wing's span, with its 3D factor), so a bigger wing that makes more
  downforce scores better.
- **Reliable**: the quick estimate only shortlists; RANS picks. A finalist
  counts only if RANS converged, the flow stays attached, and it is inside
  the box. Finalists are ranked by RANS's value for the goal.
- **Finalists in the card**: each shows ClA, CdA and ClA/CdA (the user's
  words) and RANS's verdict, best first. Selecting one shows it on the
  canvas.
- **The user picks the final design** (the user's words). "Use this wing"
  puts it on the canvas, saves it as a card and puts it on the car's
  selected combination (the existing save and put-on-car paths).
- If no finalist passes RANS, the card says so plainly and offers to check
  the next few. It never hands over an estimate's guess as the answer.

## Non-goals

- Removing the existing tools. Solvers, the Study's full controls and the
  Car section stay for hand edits and odd cases; they stop being the route
  you must take.
- 3D CFD, new turbulence models, or new solvers.
- Changing how the car's strips or Lap Sim compute.

## Anti-goals

- A "best" design that RANS has not confirmed, or one separated in RANS,
  shown as the answer.
- A design that breaks the rules box.
- Results that silently mix estimate and RANS numbers: each number says
  which it came from.
- Settings hidden so deep that changing one takes more clicks than today.

## Approaches considered

- **A. The app chains existing jobs** (starter, then Study with checks). Least
  new code; two jobs and an app-side hand-off that must survive a quit.
- **B. One engine job, `wing-design` (chosen by the user).** Lays out the
  wing, searches with the estimate, RANS-checks the best few and returns the
  finalists ranked by RANS, built from the existing starter, optimiser,
  calibration and RANS functions.
- Card layouts: A (one card with chips) chosen over B (four folding steps).

## How it works

### Engine

- **Layout to fill the box**: `layout` scales the standard arrangement up
  as well as down, to the largest scale with no issues inside the box
  (bisection on the scale), instead of starting at a fixed total chord.
- **Chord ranges**: a chord's upper bound is what the box allows for it,
  not +25% of its start; its lower bound stays as now.
- **Goals in car terms**: the score uses `car_contribution` (span,
  endplate or 3D factor) so "most downforce" is ClA and "best efficiency"
  is ClA/CdA. Fastest lap keeps the lap objective (the base car with the
  other wing when there is one, as Wing Lab now does).
- **`wing-design` job**: params hold the box, elements, goal, start (none,
  or the canvas wing), flow, ride height, span and 3D settings, the More
  settings, and the check count. It runs: layout or the given wing, the
  estimate study (with the existing calibration RANS run alongside), then
  RANS on the best distinct designs. Its result lists the finalists with
  their params, estimate and RANS numbers, ClA, CdA, ClA/CdA and verdict,
  ranked by RANS for the goal.
- **Attached in RANS**: converged is not enough (the 30 mm study wing
  converged at Cd 0.51, stalled). A finalist is "separated" when its RANS
  surface shows reversed flow (negative skin friction) over a set share of
  an element's suction side, or its drag is far above the estimate's.

### App

- The Design card in the inspector, the chips' defaults remembered per
  project, a progress line, and the finalists list.
- Selecting a finalist loads it on the canvas (undoable, as a study trial
  is now); "Use this wing" saves the card and puts it on the car.
- A design run's study is kept like any study, so "check the next few"
  resumes it.

## Calls made after the builder check

- **Efficiency on the car (the user's answer).** With a base car set up,
  "best efficiency" is the whole car's ClA/CdA (base car, the other end's
  wing and this one, as fastest lap scores it now); with no base car, the
  wing's own. Finalists show the matching numbers and say which.
- **The wing may move in the box (builder's call).** To use the area it is
  allowed, the design may place the wing anywhere inside its box: its
  height and fore-aft position are design variables, and the ride height
  follows from where it sits (the box and the ground go to the engine in
  car coordinates). "Use this wing" writes that placement to the car.
- **Start from the canvas (builder's call).** The Elements chip locks to the
  canvas wing's count, and sections are still searched among each
  element's shortlist, as the Study does now.
- **More is the Study's settings (builder's call).** Not a copy: changing
  one under More changes it in the Study section, so there is one way to
  set each thing, and "check the next few" resumes the same study.
- **Skin friction from RANS (builder's call).** SU2's surface output gains
  skin friction (it writes pressure only now), checked on SU2 8.5 against
  one of the ground runs already made, before the separation test uses it.

## Constraints

- Engine: Python, existing dependencies (Optuna, NeuralFoil, SU2, gmsh).
- App: SwiftUI, sage37, the existing job system.
- RANS checks use the mesh and model chosen under More (default: the
  Solvers section's).

## Left to the builder

- The exact separation threshold on the RANS surface, from the runs at
  hand (the stalled study wing, the 6212 and 4412 ground runs).
- Default trial count and how the progress line reads.
- How "check the next few" is offered.
- Where the More settings live in the card (a popover or an expanded
  section).
