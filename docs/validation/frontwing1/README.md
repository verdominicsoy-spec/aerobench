# frontwing#1: the case that showed the RANS was wrong

The user's 4-element inverted front wing (main −10.5°, flaps 2.5°, 22°, 34.5°; 682 mm total chord, 1 m span), 20 m/s, free air, 0°, fine mesh. STAR-CCM+ (3D on the car, moving ground, fully turbulent k-ω SST) separated the **main on its upper (pressure) surface**; AeroBench's RANS of 12 Nov 2026 said only "Flap 1 separates from 74%".

`run.py` runs `job.json` (the user's run's parameters) through `rans.solve`; `results.json` holds the answers. Reversed flow is from skin friction along the surface (`rans.regions`), in % of each element's chord; every one is on the lower (suction) surface.

| Run | Tu at wing | Cl | Cd | Main | Flap 1 | Flap 2 | Flap 3 | Verdict |
|---|---|---|---|---|---|---|---|---|
| 12 Nov, SST-LM (before the fixes) | 0.14% | −2.371 | 0.0327 | nose bubble | sep. 74%–TE | bubble 42–68% | bubble 39–65%, sep. 85%–TE | "Flap 1" only |
| 13 Nov, SST-LM | 0.99% | −2.384 | 0.0302 | nose bubble 0.4–1.6% | bubble 80–90% | 96%–TE | bubble 42–58%, sep. 83%–TE | Flap 3 |
| 13 Nov, SST (fully turbulent) | 0.99% | −2.334 | 0.0340 | attached | attached | 94%–TE | sep. 79%–TE | Flap 3 |

13 Nov runs: 336,174 cells (fine, suction surfaces fine to the trailing edge); SST-LM settled on average after 4,000 iterations (residual down 3.7 orders), SST converged (5.9 orders).

What changed and why:
- **Turbulence**: the 1% set at the far field now reaches the wing (`SST_OPTIONS= SUSTAINING`). That removes Flap 2's 26%-chord bubble and turns Flap 1's separation into a bubble that closes.
- **The check**: Flap 3's trailing-edge separation (17–21% of chord) was always in the solution; the old check measured only up to 95% and needed 15%, so it missed it.
- **Transition against turbulent**: lift 2% apart, drag 12%, the same verdict.

None of these runs separates the main: the 2D section at its full angle does not. A diagnostic run with the flow turned +10° (fully turbulent, sustained; the induced angle lifting line gives this wing in free air without endplates is about 12°) does: the main's pressure surface reversed from 1% to 91% of chord, its Cl from −1.02 to −0.27. That is what `rans.solve_finite` (the run as on the car) is for.

## As on the car (`run_car.py`, results in `car.json`)

The first four rows assume span 1 m (the project's), the job's own angle (alpha 0) and the ride height to the main. STAR's CATIA wings turned out to differ on all three (see "STAR's wings from the CAD" below), so those rows are not STAR's case. Fine mesh, SST-LM, then the fully turbulent check at the same angle.

| Case | Induced angle | Cl (3D) | Cd (with induced) | Main | Flaps |
|---|---|---|---|---|---|
| Free air, endplate 250 mm (AR_eff 2.16), SST-LM | +10.7° (4 solves: 10.45, 11.24, 10.72; settles about 10.9) | −1.335 | 0.291 (0.262 induced) | **upper (pressure) surface stalled, 1% to 92%**; lower from 88% | Flap 2 from 97%, Flap 3 from 91% |
| same, fully turbulent SST | +10.7° | −1.302 | 0.282 | **upper surface stalled, 1% to 93%** | Flap 3 from 89% |
| Over a ground, 80 mm (h/b 0.08, ground factor 0.45) | none: stopped | 2D at the full angle did not converge (Cl about −6.3, swinging; residual down 3.2 orders) | | | |
| Over a ground, STAR's 35 mm, endplate 315 mm (AR_eff 2.34, ground factor 0.27), SST-LM | none: stopped (solve 1 +6.54°, from the estimate; solve 2 +2.03° did not converge) | −0.05 at +6.54° | 0.118 | **upper (pressure) surface stalled, LE to 88%** | every flap stalled on its pressure surface |

So with the wing run at the angle the flow meets it on the car, AeroBench separates the main on its upper (pressure) surface, as STAR did, and both models agree. Its lift falls from −1.04 (2D) to −0.23. The loop had not settled to 0.1° in 4 solves: the main is stalling there, Cl moves 0.16 a degree, and plain relaxation swung about the answer; it now takes a secant step from the third solve. The SST check's Cd here is the section's plus its own induced drag (the engine adds it since 8dbe072).

Over the ground the 2D section at its full angle has no steady answer at 80 mm (h/c 0.12): the loop steered by its swinging Cl to +12.5°, where the wing pitched against the ground failed outright (Cl +0.25, residual down 1.3 orders). Since 199d846 the loop stops at the first solve that does not converge and says so. To be redone with STAR's ride height; if the 2D solve at the full angle is unsteady there too, the loop needs a first angle from somewhere else (the quick estimate's lift) instead.

At STAR's 35 mm and 315 mm endplate (14 Nov) the loop does not settle. The quick estimate puts the induced angle at +6.5° (Cl about −3, AR_eff 2.34, ground factor 0.27). RANS there stalls the main and every flap on the pressure surface (Cl −0.05, wanting +0.1°), and at +2.0° it does not converge. The main's pressure-side stall agrees with STAR; the downforce does not stand. Over a ground the loop pitches the wing by the induced angle, with its lowest point held at the ride height. That also lifts the flaps away from the ground: 6.5° over 0.68 m of chord is tens of millimetres at a 35 mm ride height. On Zerihan's wing (AR_eff 5.8) the angle is 1.3° and the pitch barely moves it (within 3%, ../ground-3d). On a low-aspect-ratio wing this close to the ground it is not checked. STAR's downforce is what decides it.


## STAR's wings from the CAD (14 Nov)

`cad_sections.py` cuts the STEP files at chosen spanwise stations (OpenCascade, every face spanning over 100 mm, each element's cut joined into one outline). Both wings are prismatic: chords and angles hold at six stations; only the height changes.

- frontwing#1.02 (the one STAR ran without leading-edge separation) is this job's wing, every element within 0.3 mm, pitched 7.45 deg toward more downforce: `alpha -7.45` here. The main's trailing edge is 2.83 deg below its leading edge, against 10.27 deg in the job.
- frontwing#1.01 is pitched 4.9 deg, with the main and Flap 1 at 232.9 and 180.9 mm.
- Each side is one 524.5 mm wing between two 315 mm endplates. The wing drops about 45 mm toward the inner endplate. With the ground 35 mm under the endplate bottoms (CATIA z -49), the main's lowest point at mid-span is 96.6 mm up.

So the 35 mm row above set the main 35 mm off the ground at the job's angle on a 1 m span: not STAR's case.

### frontwing#1.02 as STAR ran it

`run_car.py 0.315 0.0966 0.5245 -7.45`: AR_eff 1.65, ground factor 0.69, so the model's induced angle is 7.6 deg per unit of Cl.

| Solve | Induced angle | Cl | Wants | State |
|---|---|---|---|---|
| 1 (from the estimate) | +10.60 deg | +0.10 | -8.2 deg | main stalled on its pressure side |
| 2 | +5.60 deg | -4.50 | +26.8 deg | not converged |
| 3 | +8.25 deg | -3.17 | +16.6 deg | not converged |
| 4 | +9.98 deg | +0.05, Cd 0.089 | -7.8 deg | unsteady; main pressure side stalled from the leading edge to 33%, every flap stalled |

The loop does not settle. The section carries Cl -3 to -4.5 up to +8.25 deg and has lost it all by +10 deg. The lifting line's answer sits on that cliff, so the loop jumps from one side to the other.

STAR ran a half car: one side's wing and the body, with the report's reference area 0.5 m^2 (the 0.8 turned out to be the whole car's CL, body and wing, see below). Its CL of about 0.8 is 0.4 q of downforce, which is 1.22-1.27 on that side's planform (planform chord 602-625 mm) and -1.12 on AeroBench's reference (span times the 682 mm sum of the chords). To land there, the model's downwash wants +8.5 deg. That is on the cliff: at +8.25 deg RANS still carries -3.17, nearly three times STAR's, and by +10 deg it has lost it all with the main stalled from the leading edge. STAR's main does not stall at the leading edge, so its -1.12 is an attached wing near +8.5 deg or a wing partly separated somewhere AeroBench's strip cannot show (along the span, or on the flaps).

Why the method does not hold here:
- It is checked on one wing only: Zerihan's, AR 4.9, endplates a quarter of the span (../ground-3d). This one is AR 0.77, with endplates 60% of the span. Lifting line and Hoerner's endplate rule are made for slender wings.
- The endplates come down to 35 mm off the ground, 0.05 of the chord. Lifting line knew the wing's height, not the gap under the endplates, so it kept the full tip losses (on Zerihan's wing that read 5-10% low below 0.134 chords).
- One section at mid-span stands for a wing that drops 45 mm across its span.

### With the vortex lattice (14 Nov)

`run_car.py 0.315 0.0966 0.5245 -7.45 0.035`: the lattice has the wing, both 315 mm endplates and the 35 mm gap under them, and the ground as a mirror. Its angle is 6.83 deg per unit of Cl (AR_eff 1.58, ground factor 0.59), against lifting line's 7.6. The same lattice put Zerihan's two lowest heights at -2.7% and -0.7% of the balance, where lifting line read -5% and -10% (../ground-3d).

It does not change the answer here. The estimate starts the loop at +9.58 deg, past the cliff: SST-LM does not converge there (residual down 1.1 orders), and the SST fallback gives Cl +0.10, Cd 0.052, main stalled on its pressure side from the leading edge to 52%, every flap stalled. With the lattice, STAR's -1.12 wants the section at +7.6 deg (6.83 x 1.12), where RANS still carries Cl -3 to -4.5, attached. The loop's own answer, where the lattice's angle and the section's Cl agree, is still on the cliff between +8.25 and +10 deg. A better downwash does not move the cliff, so one strip cannot match STAR on this wing; what is left is the span (the 45 mm drop, the nose between the inner endplates) or the flaps, which this method cannot show.

STAR's half car includes the body (user, 14 Nov). So the nose sits between the two inner endplates (410 mm apart if CATIA y = 0 is the centreline) and changes the flow the wing sees: blockage and upwash ahead of the body, and the inner tip half sealed. AeroBench's strip has none of that. STAR's 0.8 is the whole car's CL, body and wing together (user, 14 Nov): the half car's force on half the reference, so the same coefficient as the full car on 1.0 m^2. So the -1.12 above is not the wing's number, and the lift targets in the two paragraphs above are void; the wing's own share is unknown until STAR reports a force on the wing's surfaces alone.

What still compares is the separation: STAR's frontwing#1.02 keeps its main attached at the leading edge, and AeroBench's loop on this wing ends with the main stalled from its leading edge on the pressure side. That holds whatever the wing's share of the 0.8 is.

### In spanwise strips (14 Nov, `run_polars.py`, `run_strips.py`)

Section polars at the three heights the wing's main sits at across the span (74.1 mm inboard, 96.6 mm mid-span, 119.1 mm outboard), fully turbulent SST on the fine mesh, 2 to 10.5 deg in the section's own angle (`polars.json`, about 14 min a solve). Then 6 strips between the 315 mm endplates, each on the polar at its own height (straight between the two run heights about it), the lattice with the 45 mm drop and the 35 mm gap coupling them (`finite.couple_strips`, `strips.json`).

What the polars say, Cl on the 682 mm sum of the chords:

| Height | Last settled point | Then | Main stalls from its leading edge |
|---|---|---|---|
| 74.1 mm | +7 deg, -3.68 | +8 deg, -0.38, not settling (Cl swings 0.7) | from +7 deg |
| 96.6 mm | +8.75 deg, -2.75 | +9.5 deg, +0.01, not settling | from +8 deg |
| 119.1 mm | +9.5 deg, -2.38 | +10.5 deg, +0.06, settled on average | from +8 deg |

- Of 24 solves, 11 converged and 1 ran unsteady (6 deg at 96.6 mm, the mean used). 6 more stopped at the iteration cap with Cl moving less than 0.005 over the last 200 iterations (one on Cd alone); `run_strips.py` uses those (its `drift` limit, 0.01). The 6 left out are all past the cliff, Cl swinging 0.09 to 2.5.
- The two lower flaps separate at the trailing edge (the last 10-23% of their chord) at every angle and every height.
- The cliff moves 2 to 3 deg with the 45 mm of height: the low end of the wing loses its lift first.

The strips on the settled points: the three outboard strips settle at +7.3 to +8.1 deg (Cl -3.38 to -2.90). The polars keep the main attached at the leading edge to between +7 and +8 deg, so the outermost strip, at +8.07, is at that edge. The three inboard strips run past their polars' last settled angle (+7 deg, since the polars between 74 and 97 mm stop where the 74 mm one does), so the wing's Cl from that run, -3.39, is not an answer. The single strip at mid-span runs past its polar too, at +11.3 deg.

With the 6 unsettled stalled points put in as well (`run_strips.py 99`, only a look at where they land, since those Cl are not converged): every strip lands on the cliff, +7.6 deg at the low end to +9.3 deg at the high end, wing Cl -2.26 on the summed chord (-2.47 on the planform chord). The single strip at mid-span lands at +8.85 deg, Cl -2.39, also on the cliff. Between two run heights the strip's polar is a blend of a stalled and an attached section, which no real section is, so these numbers say where the cliff is, not what the wing carries on it.

So the strips do not change the single strip's answer: at STAR's setup the lattice puts the section's angle where SST stalls the main from its leading edge, across the whole span, the low end first. STAR's main stays attached there. Either the induced angle is too large (the body between the inner endplates, which neither the strips nor the lattice have) or SST stalls this section 1 to 2 deg early. Telling those apart needs STAR's wing-surface force or its sectional pressures at one span station.

### STAR's wing alone (15 Nov, `star_wing.py`, `su2_elements.py`)

STAR ran frontwing#1.02 alone: wing and both endplates, half model, moving ground, 20 m/s, fully turbulent SST, the endplate bottoms 35 mm off the ground. It stopped at 368 iterations on the aero lead's criteria; over the last 100 its CL moved 0.0016 and its CD 0.0010. `WingNumbers.java` (in OneDrive `AERO/starccm macros`) wrote the forces, the whole wetted surface (154 273 faces) and three cuts. The surface table adds up to STAR's own force to 0.01 N. Wing y+ is 1.6 median and 2.8 at the 95th percentile.

On AeroBench's reference (the 524.5 mm span times the 682 mm sum of the chords):

| | Fz (N) | Fx (N) | Cl | Share of the downforce |
|---|---|---|---|---|
| main | -60.5 | +0.2 | -0.714 | 37% |
| flap 1 | -50.8 | -10.4 | -0.600 | 31% |
| flap 2 | -32.3 | -18.0 | -0.382 | 20% |
| flap 3 | -17.0 | -15.5 | -0.201 | 10.5% |
| endplates | -1.9 | -2.0 | | 1% |
| wing between the endplates | | | **-1.902**, Cd 0.517 | |
| whole part | -162.9 | -45.8 | -1.924 | |

- **Nothing separates.** The wall shear runs against the stream on 0.2% of the main's wetted area, 0.4% of flap 1's, 1.6% of flap 2's and 3.0% of flap 3's (small patches at the trailing edges and the endplate corners). STAR does not stall the main at its leading edge.
- **The spanwise loading is nearly flat.** The 6 strips carry Cl -1.83 to -2.00, outer end to inner end.
- **The drop is not straight.** The section moves down without twisting (its leading edge and flap 3's trailing edge both drop 43 mm), but the main is level outboard, 98-102 mm above the ground, and drops only across the inner half: 97 mm at mid-span, 87 mm, 72 mm, then 53 mm in the innermost strip. The strip run took a straight 45 mm drop, 119 mm down to 74 mm, so its outboard strips sat about 20 mm too high and its inboard strips up to 20 mm too low at the far end.

AeroBench against it: the strips with every polar point (`run_strips.py 99`) gave Cl -2.26, **+19%** on the wing between the endplates, every strip on the cliff, with the main's leading edge stalled. The single strip gave -2.39, +26%. The separation call is wrong.

Element by element, at mid-span (STAR's strip 3, the main 96.7 mm up, against the 2D polar at 96.6 mm), Cl on the 682 mm chord:

| | main | flap 1 | flap 2 | flap 3 | Cl |
|---|---|---|---|---|---|
| STAR, 3D | -0.77 | -0.61 | -0.41 | -0.21 | -2.00 |
| SU2 2D, +7 deg | -0.90 | -1.51 | -0.89 | -0.29 | -3.59 |
| SU2 2D, +8 deg | -0.60 | -1.36 | -0.83 | -0.28 | -3.07 |

STAR's main carries what the 2D main carries at about +7.4 deg. SST keeps it attached at that angle too: the 96.6 mm polar's main first stalls at its leading edge at +8 deg. The flaps behind it carry 40-70% of what they carry in 2D at that angle. So SST is not stalling the section early. What fails is the single induced angle per strip.

The wing's chord is longer than its span (aspect ratio 0.77). On a wing like that the downwash grows along the chord, so the flaps meet the flow at a larger angle than the main. One angle per strip turns every element by the same amount. To shed the flaps' load, the coupling has to turn the whole section to +8 or +9 deg, past where the main stalls at its leading edge. The lattice already has chordwise panels, but `couple_strips` uses only each strip's mean far-field downwash.

Next, the fix at the cause: each element's own induced angle from the lattice's downwash at that element, and the 2D section solved with each element turned by its own angle. Not done. The SU2 polars' surface files are in temp folders and will not last: the element table above is what is kept.

### Each element at its own induced angle (15 Nov, plan `2026-11-15-element-induced-angles`)

The fix at the cause found above: the vortex lattice now gives the induced angle along the chord (`Lattice.chordwise`), and `rans.solve_finite` bends the 2D section along its chord by each point's angle about the mean (`finite.element_turns`, `rans.bend_section`). The mean stays the validated lifting-line angle, and a single element gets no turn, so Zerihan's wing is unchanged. Turning each element rigidly about its own quarter chord was tried first: it shut the main-to-flap slot to 0.09 mm and the mesher refused it. Bending moves points at the same x together, so the slots keep their gaps (12.5, 11.1 and 9.9 mm become 12.7, 11.0 and 9.9 at Cl -2).

On frontwing#1.02 at STAR's setup (`run_car.py 0.315 0.0966 0.5245 -7.45 0.035 sst`), the lattice turns the main -7 deg and the flaps +0.8, +4.0 and +5.6 deg about the mean. The run was stopped after 3 solves, before the loop settled: it wanted +10.7 deg and sat at +9.5. Mid-span Cl on the 682 mm chord:

| | main | flap 1 | flap 2 | flap 3 | Cl |
|---|---|---|---|---|---|
| STAR, strip 3 (main 96.7 mm up) | -0.77 | -0.61 | -0.41 | -0.21 | -2.00 |
| Before: 2D at +8.75 deg, the last angle before the main stalls | -0.43 | -1.24 | -0.79 | -0.28 | -2.74 |
| Bent, solve 3 at +9.54 deg (not settled) | -0.72 | -0.97 | -0.71 | -0.26 | -2.65 |

- The main now carries what STAR's does, within 7%, at an angle where the unbent section had stalled (+9.5 deg: Cl +0.01).
- The flaps still carry 25-73% more than STAR's. They turn too little: the lattice's chordwise loading is a flat plate's, heaviest at the front, while the real one is spread over four elements.
- The loop moved the angle the wrong way between solves 2 and 3. Each solve changes the turns as well as the angle, so the secant on the angle alone mis-steers.

Next: build the lattice's chordwise loading from the RANS element loads instead of the flat plate's, steer the loop on the angle with the turns held for each step, then run to the end.

Second run (15 Nov, later): the lattice now carries the elements' own loads (each a thin airfoil over its own extent, shared as the last solve loaded them) instead of a flat plate's, and each solve's turns follow from its angle (those for the Cl the fixed point needs there), so the loop steers on the angle alone. Fully turbulent SST, 3 solves. It brackets the answer between +9.26 deg (Cl -2.57) and +9.46 deg (Cl -2.41), a 6% step in Cl: the bend grows with the angle, so the section is steep there, not stalled (the loop now says settled for a step under 10%, a cliff over it). The main stays attached at its leading edge; flap 3 separates over its last 21%.

| | main | flap 1 | flap 2 | flap 3 | Cl |
|---|---|---|---|---|---|
| STAR, strip 3 | -0.77 | -0.61 | -0.41 | -0.21 | -2.00 |
| First bent run, solve 3 (flat-plate loading, not settled) | -0.72 | -0.97 | -0.71 | -0.26 | -2.65 (+33%) |
| Second run, +9.46 deg | -0.67 | -0.87 | -0.63 | -0.24 | -2.41 (+21%) |

Between the two ends the answer is about Cl -2.47 (+24%). Against STAR the main is 13% light and the flaps 16-54% heavy: the bend is in the right direction and not yet steep enough. The lattice turns the main -7.9 deg and the flaps +0.4, +5.7 and +8.4 deg about a mean of +16.9 deg, but it is a flat wing at one height: the real section climbs about 0.24 m from the main to flap 3's trailing edge, so its flaps sit nearer the endplates' top edges and their vortices than the flat lattice puts them. Next: the lattice with each element at its own height and angle.
