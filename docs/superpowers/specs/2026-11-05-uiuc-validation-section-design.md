# UIUC comparison in the accuracy window

Date: 2026-11-05. Status: for approval.

## Intent

The user wants to see, inside AeroBench, how close Wing Lab gets to real
wind-tunnel data, and to watch that change as the solvers improve. The
source is the University of Illinois low-speed airfoil tests
(https://m-selig.ae.illinois.edu/uiuc_lsat.html, volumes 1 to 6). The
user's bar: the physics should work reliably and get close; it does not
need to match exactly, and geometry differences between a tunnel model and
the design are fine.

The comparison is rerun when a big, fundamental change lands (Claude reruns
it then and commits the results) or when the user presses Recompute in the
section.

## Goals

- **A section in the accuracy window** (the "?" at the top right of Wing
  Lab, `AccuracyHelpView`), the user's pick, titled "Against the UIUC wind
  tunnel".
- **A fixed benchmark set**: ten single-element sections, each at its clean
  tunnel run nearest Re 300,000 (an FS wing's range), on the tunnel model's
  coordinates as tested (`.dap`), so geometry is taken out and the
  comparison measures the physics:

  | Section | Volume | Why |
  |---|---|---|
  | S1223 | 1 | heavy camber, high lift (FS favourite) |
  | E423 | 2 | heavy camber, high lift |
  | S1210 | 1 | high lift, thinner |
  | SG6043 | 3 | cambered, long laminar run |
  | SD7062 (B) | 3 | moderate camber, stall in range (to 15°) |
  | E387 (A) | 1 | the standard low-Re benchmark |
  | SD7037 (B) | 1 | widely used benchmark |
  | Clark-Y (B) | 3 | classic flat-bottom section (its crossed trailing edge is trimmed before meshing) |
  | SA7038 | 3 | light camber |
  | S8052 | 3 | light camber, 12% (in place of S8037, whose measured trailing edge hooks back) |

- **Both solvers** on each section:
  - the quick estimate (NeuralFoil, what Wing Lab's live estimate gives a
    single element) at the tunnel's own angles;
  - RANS, a Full polar every 2° over the tunnel's range, with the app's
    default model and the Fine mesh.
- **What the section shows** (sage37, solid panes, one prominent button):
  - a summary strip: mean |Cl error| and mean |Cd error| for the estimate
    and for RANS, RANS's converged share, and when it was last run with
    which settings;
  - per section: Cl–α, Cd–α and Cl–Cd with tunnel (points), estimate and
    RANS overlaid on each chart, plus that section's errors;
  - a history table, one row per run (date, model and mesh, the four mean
    errors, converged share), so improvements show over time;
  - a Recompute button with the expected time, a progress line while it
    runs, and Cancel.
- **Stale settings flagged**: when the app's current RANS defaults differ
  from those of the run shown, the section says so above the summary.

## Non-goals

- Multi-element and flapped sections (volumes 5 and 6). Their flapped
  polars are the next step, as the slot and flap check; no measured shapes
  are given for them.
- Ground effect: the volumes are free air.
- Tuning the solvers to these sections. The benchmark measures; it is not
  fitted to (the rule `validation.py` already states).

## Anti-goals

- Results from different settings mixed into one comparison or one history
  row.
- A RANS point that did not converge counted in the errors. It is drawn
  hollow and left out of the means; the converged share says how many.
- Committing the UIUC data itself (see Constraints).

## Constraints

- **Licence.** The UIUC data are under the GNU GPL and the authors' terms.
  The earlier decision (docs/DECISIONS.md, the validation entry) stands:
  fetched from the source on first use into `data/validation/downloads`,
  never committed. Committed results hold only AeroBench's numbers (angles,
  Cl, Cd, converged) and the errors; the tunnel points in the charts are
  read from the download. If the download is missing and cannot be fetched,
  the section shows the errors and history without tunnel points and says
  why.
- Engine: Python, existing code. `aeroengine.validation` already fetches
  volumes 1 to 3, parses coordinates and runs, finds the tested model
  (`_model`) and compares NeuralFoil (`compare`). `rans.sweep` runs a Full
  polar.
- App: SwiftUI, sage37, the existing job system. The accuracy window is its
  own `Window` scene and does not get the `AppState` environment today; it
  needs it for the Recompute job.
- Cost: about 10 sections x 8 angles x 45 s on 12 cores, about an hour for
  a Recompute.

## Approaches considered

- **A. In the accuracy window (chosen by the user).** It already answers
  "how far to trust each solver"; live evidence belongs beside it.
- B. A new Validation tool in the dock: more room, but a whole tool for an
  occasional look.
- C. A tab in Wing Lab's results: close to the work, but those results are
  about the wing on the canvas.

Reruns: both. Claude reruns after a big fundamental change and commits the
results; the user can press Recompute any time (the user's answer).

## How it works

### Engine

- A `validate-uiuc` job: fetches volumes 1 to 3 if missing, builds the ten
  cases, runs the estimate and RANS on each, and appends one run to
  `data/validation/uiuc_results.json`. A run holds the date, the git commit
  (when there is one), the settings (model, mesh, turbulence intensity,
  cores), each case's estimate and RANS rows, and the summary errors.
- Errors use the existing rules in `validation.py` (lift against
  LIFT_FLOOR near zero lift, the attached range up to STALL_BACKOFF short of
  the measured maximum lift), so the numbers match the existing survey.
- Cancel and resume as any job: a resumed run skips sections it already has.
- Also runnable from the command line for the reruns Claude does.

### App

- `AccuracyHelpView` gains the section and the `AppState` environment.
- The section reads `uiuc_results.json` and the downloaded tunnel data
  (through the engine, so the parsing lives in one place).

## Calls made after the builder check

- **Errors, both solvers alike (answered by the Vol 1 workbook).** Errors are
  taken at the tunnel's angles. RANS values there are linear interpolations
  between neighbouring converged RANS angles; a tunnel angle outside the
  converged RANS range gets no RANS error. Both solvers use `compare()`'s
  rules: relative errors, lift against LIFT_FLOOR near zero lift, over the
  attached range (up to STALL_BACKOFF short of the measured maximum lift).
- **Converged share (builder's call)** counts every RANS angle run, attached
  or not: it says how reliable the solver was, not how good the errors are.
- **The section goes through the existing wing path (answered by the Vol 1
  run).** One element, `rans.sweep` with no ride height, chord 0.30 m, air
  at rho 1.225 and mu 1.81e-5, speed set so each run's Reynolds number
  equals that tunnel run's own (not a round 300,000).
- **Settings that make results comparable (builder's call)**: the RANS model,
  mesh level, turbulence intensity and the engine's git commit. Cores only
  change speed and are recorded but never mark a run as stale.
- **One results file (builder's call).** Recompute appends to the committed
  `data/validation/uiuc_results.json`; the user and Claude share one
  machine and one repo, so Claude commits those rows like any other change.
  In a packaged app the file sits in the app's own data folder (as
  BundledEngine already arranges for `data`).
- **Picking each run (builder's call).** "Clean" means the run's comment is
  exactly "clean" (ignoring case), never a flapped or tripped run; among
  those within 5% of Re 300,000, the run with the most angles wins, then the
  nearest Reynolds number. SD7037 (B) comes from volume 1.
- **The job alongside other work (builder's call).** Recompute is an ordinary
  job in Jobs: it keeps running when the accuracy window closes, and Wing
  Lab's own RANS runs are not blocked (both share the cores, so each is
  slower; the section says so while it runs).

## Left to the builder

- Chart reuse: Wing Lab's `PolarCharts` or a small chart of its own.
- How many history rows show before the rest fold away.
- Where the section sits in the window (top, or after the solver cards).
- Exactly how a resumed run is detected.
