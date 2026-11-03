# Car builder: modular front and rear wings on one car, with 2D car runs

Date: 2026-11-03. Status: design, awaiting approval.

## Intent

The user designs front and rear wings in Wing Lab (as practice, set as a
task) and wants to try them on one car: the same base car with any front
wing and any rear wing, compared in Lap Sim. Each wing should be a card
with its section and numbers that connects to the car, so it is obvious
what sits where. The results should be good enough to give a real idea
and fast enough to iterate.

There are two ways to judge a combination, and the user wants both:

- **Quick**: the bare car's numbers plus each wing's own numbers, with
  aero balance from where each wing sits. Seconds.
- **Full**: 2D CFD of the car's sections with the wings in them, so the
  wings and the car affect each other. Minutes.

The bare car's own numbers come from the best 2D runs AeroBench can make
of the base car, as strips across it (the user's choices).

## Goals

### Step 1: 2D car runs

- **Base car** from the user's STEP (`basemodel.stp`, CATIA V5, one part
  "Aero27", 32 solids, full size in mm, +x forward, z up, symmetric in y,
  no wings on it). Set up once in the Car tool: the app finds the four
  wheels (the large round solids) and the ground (the tyre bottoms); the
  user confirms or corrects them, and sets forward and up axes for other
  files.
- **Section plane**: a plane at a chosen y (across the car), slid like the
  CAD Viewer's section view, showing the cut outline live.
- **Strips** (the user's choice): the bare car's numbers come from several
  sections across half the car, doubled by symmetry. Default 7 planes from
  the centreline to the outside of the wheels; each stands for a strip of
  the width around it; the user can change the count and positions.
- **Mesh** (the user's words): high y+ (wall functions) on the car's body
  and wheels; y+ about 1 on any wing present. A "maxed out" setting gives
  the finest mesh the 2D solver handles; the bare car's numbers use it.
- **Ground and wheels** (the user's choice): ground moving or fixed, at a
  set speed; wheels rotating or fixed, at a set speed; both default to the
  car's speed.
- **Solver**: SU2 RANS (k-omega SST), as Wing Lab uses; one job per plane,
  run together as one strips job, progress in the Jobs view.
- **Result**: per strip, downforce and drag per metre of width and where
  the downforce acts; for the car, ClA and CdA (strips summed, doubled),
  and the split of downforce between front and rear axle.

### Step 2: the builder

- A **Car** tool in the dock.
- **Wing cards**: every wing saved in Wing Lab, marked front or rear, with
  its section, span, ClA and CdA (Wing Lab's own numbers) and which solver
  they came from.
- **Placing a wing** (the user's words): drag it on the car's side view or
  type its position (leading edge in mm from its axle and above the
  ground); the two stay in step.
- **Rules boxes from the car**: the FS limits in
  `data/rules/fs2027_aero.json` (700 mm ahead of the front tyres, 350 mm
  high ahead of the front tyre leading edge, 250 mm behind the rear tyres,
  1100 mm high behind the head restraint, 30 mm ground clearance) are
  worked out from the confirmed wheels and a head restraint position the
  user marks once. A wing cannot be placed outside its box.
- **The front wing may run through the nose** (the user's words), within
  its box, as the real car does: in a section that cuts both, the wing's
  outline and the nose's are merged into one shape before meshing.
- **A combination**: the base car, one front card, one rear card, either
  optional. It shows the quick result at once; a Run Full button runs the
  strips with the wings in every section their span covers (a wing spans
  y from the centreline to half its span), each at its placed position.
- **Send to Lap Sim**: a combination becomes one of Lap Sim's cars A to E:
  ClA, CdA and aero balance on the driven axle, from the axle split. The
  car is rear-wheel drive (the user), so the balance sent is the rear
  axle's share of the downforce. The
  other car numbers (mass, tyres) are kept from the Lap Sim car it lands
  on. Quick and full results are labelled as such wherever shown.

## Non-goals

- Mounting brackets (not the user's job).
- 3D CFD, yaw, and steering.
- Running the sections in STAR-CCM+.
- Editing the base car's shape (Edit Part does that).
- Endplates and wing tips as geometry in the sections: a wing's 3D effects
  come from Wing Lab's numbers in quick mode; full mode is 2D.

## Anti-goals

- A wing outside its rules box.
- Quick and full results mixed without saying which is which.
- Car numbers from runs that did not converge, shown as if they did.
- A combination's numbers silently going stale: when a wing card or the
  base car changes, combinations that use it say their results are old.

## Approaches considered

- **A. A new Car tool, car work in the engine (chosen).** The Car view
  holds the base car, wing cards, side view and combinations; the engine
  gains section cutting, a car mesher (reusing Wing Lab's wing meshing),
  SU2 runs with the ground and wheel options, and a strips job. Most new
  code; the section cut and the car mesher are the hard parts.
- **B. Inside Lap Sim.** Reuses Lap Sim's cars, but side views, section
  planes and CFD do not belong in a lap-time tool, already one of the
  largest views.
- **C. Sections run in STAR-CCM+.** Better high-y+ meshing, but every run
  needs STAR-CCM+ outside the app and results come back by hand: slow for
  quick comparisons.

The user delegated the choice ("do whatever makes the most sense"); A is
the recommendation, taken as the builder's call.

## How it works

### Engine

- **Section**: cut the base car (and any wing placed as 2D outlines) with
  the plane `y = c`, join the cut edges into closed loops, drop loops
  smaller than a set area, merge overlapping loops (the wing through the
  nose), keep wheel loops separate so they can rotate.
- **Mesh** (gmsh, as `wing/mesh.py`): a rectangular domain over a ground
  line at the tyre bottoms; wall layers sized for y+ about 30 to 100 on
  the body and wheels, y+ about 1 on wing elements; refinement behind the
  car; far field several car lengths away.
- **SU2**: ground marker moving at its speed or fixed; wheel markers
  rotating about their axles at their speed or fixed; wall functions on
  body and wheels; forces per marker so the wing's share can be reported.
- **Strips job**: plans the planes, runs each section, and sums
  `ClA = 2 * sum(L'_i * w_i) / q`, `CdA` the same with drag, and the axle
  split from each strip's centre of pressure, where `L'_i` is downforce
  per metre of strip i, `w_i` its width, `q` the dynamic pressure.

### App

- **Car tool** in the dock: base car setup, section plane and strip runs,
  wing tray, side view with slots and rules boxes, combination list, Send
  to Lap Sim.
- Wing Lab gets **Save as Card** (front or rear), from the box the wing
  was designed in.
- Everything lives in the project folder: the base car's setup and strip
  results, the cards, the combinations.

## Constraints

- Engine: Python, `cadquery-ocp`, gmsh and SU2 as Wing Lab's RANS uses
  them; no new dependencies.
- Jobs through the existing job system; one strips job with progress.
- STEP in mm; the car file's axes are set by the user (this one: +x
  forward, z up).
- The UI follows the app's style (sage37).

## Calls made after the builder check

- **Wing height in quick mode (builder's call).** A card's saved numbers
  hold only at the height they were made at. Placed at another height, the
  quick result re-estimates the wing there with Wing Lab's quick estimate
  (the warm engine, milliseconds), and says which numbers it used.
- **3D in full mode (builder's call).** In 2D a wing has infinite span and
  no tip losses, so each wing's share of a full run (its markers' forces)
  is corrected with its card's 3D factor and endplate estimate, as Wing Lab
  does, keeping quick and full comparable. The raw 2D sum is shown too.
- **Full-run mesh (builder's call).** A full run uses the same mesh setting
  as the bare-car baseline it is compared with. Choosing a coarser setting
  re-runs the bare car at it too (cached), so a comparison never mixes mesh
  levels.
- **Speed (builder's call).** One car speed in the Car tool (default
  15 m/s, Wing Lab's default) for Reynolds number and the ground and wheel
  defaults; a card made at another speed gets a warning.

## Left to the builder

- How cut edges are joined into loops, and the tolerance.
- Mesh sizes, growth, domain size, and the exact y+ targets inside the
  ranges above.
- Default strip positions within the 7-plane default.
- Convergence criteria, and what "did not converge" shows.
- Wheel detection heuristic.
- File formats in the project folder.
- How a wing card's quick numbers split onto the axles (its centre of
  pressure from its own section, placed on the car).
