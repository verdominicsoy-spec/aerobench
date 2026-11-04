# Wing Lab and Car in one tool

Date: 2026-11-04. Status: approved.

## Intent

Wing Lab and the Car tool have the same final goal (the user's words): a
front and a rear wing that make the car fast in the Lap Sim. Today they
are two dock tools; a wing goes from one to the other only as a saved
card, so while shaping a wing you never see what it does to the car. The
user wants them merged into one tool where the car's numbers are in
front of you as you edit the wing.

## Goals

- **One tool.** The Car tool leaves the dock; everything it does lives in
  Wing Lab.
- **The wing you edit sits on the car, live** (the user's choice). Its
  rules box (Front or Rear) decides which end. It replaces that end's wing
  in the selected combination, at that wing's placement; if the end is
  empty it goes at the box's default spot (as Put on Car does today).
  Nothing is written to the card until Save.
- **Car view on the canvas.** A Wing | Car switch over Wing Lab's canvas.
  Car shows the side view (the Car tool's, unchanged in what it does):
  both wings, the rules boxes, drag or type placement, the section plane.
- **Car tab in the results pane**, beside Pressure, Polar, Estimate, CFD
  and Study: the quick sum as you edit (ClA, CdA, rear share), the change
  against the bare car and against the saved card, and the full run's
  result with Run Full.
- **Car section in the inspector**: base car setup, section plane and
  strips, mesh and speeds, ground and wheel options, the combination
  picker, Send to Lap Sim.
- **Cards in the library sidebar**: a Cards list beside the airfoils.
  Opening a card loads its wing to edit; Save updates it, Save as New
  makes a new card. Put on Car stays for a card you are not editing.
- Every Car tool feature keeps working: quick and full, strips, stale
  results, undo, failed strips, gaps, Send to Lap Sim with warnings.

## Non-goals

- No change to the engine, the strip runner, the solvers or the files in
  the project folder (cards, combinations, car state stay as they are).
- No new car physics.

## Anti-goals

- Numbers from an unsaved wing shown as if they were the card's. The Car
  tab says when it is using the wing being edited, not the saved card.
- A combination's full result looking current after the edited wing has
  changed it (the existing stale rule covers saved cards; the draft must
  count too).
- Two ways to send to the Lap Sim that disagree without saying why.
- Wing Lab getting slower to edit: the car sum must not hold up typing
  or dragging.

## Approaches considered

- **A. One tool, two modes**: a Wing | Car switch that swaps the whole
  screen. Small, but you still flip between two screens.
- **B. The car inside Wing Lab (chosen by the user)**: car view on the
  canvas, Car results tab, Car inspector section, cards in the sidebar.
  Most work, matches the shared goal.
- **C. Wing Lab inside Car**: the wing editor in a side panel of the car.
  Wing Lab's editor is too large for a panel.

## How it works

- **Draft card.** The edited wing becomes a card in memory, built the way
  Save as Car Card builds one now (`carContribution` on the best numbers
  there are: converged CFD, then the live estimate, then the inviscid
  preview). The quick sum uses it in place of its end's card.
- **Which slot.** If the wing was opened from a card that is on the
  selected combination, it takes that card's placement. Otherwise it
  replaces whatever card is on its end, keeping that placement, or gets
  the box's default spot.
- **Height.** Builder's call: for the edited wing, its placed height above
  the ground and Wing Lab's ride height are one number. Dragging it on the
  car sets the ride height (when the wing is in ground effect) and the
  wing's own estimate follows, so the car's re-estimate at height and
  Wing Lab's estimate never disagree.
- **Run Full.** Builder's call: Run Full saves the edited wing to its
  card first (Update, or a new card if it has none), so the full result
  is tied to a saved card and the stale rule keeps working.
- **Lap Sim.** Builder's call: with a base car set up, the Lap Sim section
  sends the combination (the Car tool's Send to Lap Sim). Without a base
  car it keeps today's per-wing send, which needs no car.

## Calls made after the builder check

- **Draft and combination (builder's call).** The draft is an overlay on
  the selected combination, not written into it: the stored combination
  keeps its card until Save (or Run Full, which saves), and then the
  saved card takes that end's slot for good. Dragging or typing the
  draft's position writes the placement to the combination as the Car
  tool does now, so the position survives switching wings.
- **Height on the car (builder's call).** Placing the edited wing on the
  car turns on Wing Lab's ground and sets its ride height to the placed
  height, front and rear alike (Wing Lab's ground effect fades out at
  height, so a high rear wing still reads near free air). A drag is a
  Wing Lab edit: it goes through Wing Lab's undo and makes its CFD out of
  date, as any height change does now. The car then never re-estimates
  the draft at a height Wing Lab is not showing.
- **Rules box (builder's call).** Once a base car is set up, Wing Lab's
  box for the wing's end is the car's box (`CarRules.box`) and its box
  fields are read-only, so the Study cannot make a wing that will not fit
  on the car. With no base car, the box stays free as now.
- **Study's lap goal (builder's call).** With a base car, the
  fastest-lap goal scores the combination (base car plus both wings, the
  same numbers Send to Lap Sim sends) instead of swapping a wing in Lap
  Sim car A. Without a base car it keeps today's goal.
- **No combination yet (builder's call).** With a base car and no
  combination, the first one is made for you ("Combination 1") the first
  time a wing is put on the car.

## Constraints

- SwiftUI app, sage37 (as the rest of the app); no engine changes.
- Reuse the Car tool's panes rather than rewriting them.
- Wing Lab's inspector is 320 to 440 points wide; the car panes must fit.

## Left to the builder

- Exact layout inside each pane, and what the Car tab shows before a base
  car is set up.
- How often the quick sum recomputes while editing (it is cheap; the
  height re-estimate goes through the warm engine).
- Where the wing tray's "unsaved" mark sits.
