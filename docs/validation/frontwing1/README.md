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

STAR ran a half car: one side's wing and the body, with the report's reference area 0.5 m^2 (the 0.8 turned out to be the whole half car's, see below). Its CL of about 0.8 is 0.4 q of downforce, which is 1.22-1.27 on that side's planform (planform chord 602-625 mm) and -1.12 on AeroBench's reference (span times the 682 mm sum of the chords). To land there, the model's downwash wants +8.5 deg. That is on the cliff: at +8.25 deg RANS still carries -3.17, nearly three times STAR's, and by +10 deg it has lost it all with the main stalled from the leading edge. STAR's main does not stall at the leading edge, so its -1.12 is an attached wing near +8.5 deg or a wing partly separated somewhere AeroBench's strip cannot show (along the span, or on the flaps).

Why the method does not hold here:
- It is checked on one wing only: Zerihan's, AR 4.9, endplates a quarter of the span (../ground-3d). This one is AR 0.77, with endplates 60% of the span. Lifting line and Hoerner's endplate rule are made for slender wings.
- The endplates come down to 35 mm off the ground, 0.05 of the chord. Lifting line knew the wing's height, not the gap under the endplates, so it kept the full tip losses (on Zerihan's wing that read 5-10% low below 0.134 chords).
- One section at mid-span stands for a wing that drops 45 mm across its span.

### With the vortex lattice (14 Nov)

`run_car.py 0.315 0.0966 0.5245 -7.45 0.035`: the lattice has the wing, both 315 mm endplates and the 35 mm gap under them, and the ground as a mirror. Its angle is 6.83 deg per unit of Cl (AR_eff 1.58, ground factor 0.59), against lifting line's 7.6. The same lattice put Zerihan's two lowest heights at -2.7% and -0.7% of the balance, where lifting line read -5% and -10% (../ground-3d).

It does not change the answer here. The estimate starts the loop at +9.58 deg, past the cliff: SST-LM does not converge there (residual down 1.1 orders), and the SST fallback gives Cl +0.10, Cd 0.052, main stalled on its pressure side from the leading edge to 52%, every flap stalled. With the lattice, STAR's -1.12 wants the section at +7.6 deg (6.83 x 1.12), where RANS still carries Cl -3 to -4.5, attached. The loop's own answer, where the lattice's angle and the section's Cl agree, is still on the cliff between +8.25 and +10 deg. A better downwash does not move the cliff, so one strip cannot match STAR on this wing; what is left is the span (the 45 mm drop, the nose between the inner endplates) or the flaps, which this method cannot show.

STAR's half car includes the body (user, 14 Nov). So the nose sits between the two inner endplates (410 mm apart if CATIA y = 0 is the centreline) and changes the flow the wing sees: blockage and upwash ahead of the body, and the inner tip half sealed. AeroBench's strip has none of that. STAR's 0.8 is the whole half car's CL, body and wing together (user, 14 Nov). So the -1.12 above is not the wing's number, and the lift targets in the two paragraphs above are void; the wing's own share is unknown until STAR reports a force on the wing's surfaces alone.

What still compares is the separation: STAR's frontwing#1.02 keeps its main attached at the leading edge, and AeroBench's loop on this wing ends with the main stalled from its leading edge on the pressure side. That holds whatever the wing's share of the 0.8 is.
