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

Span 1 m (the project's), endplate 250 mm and ride height 80 mm assumed: STAR's model's are not known yet, so rerun `run_car.py <endplate> [<ride height>]` with them. Fine mesh, SST-LM, then the fully turbulent check at the same angle.

| Case | Induced angle | Cl (3D) | Cd (with induced) | Main | Flaps |
|---|---|---|---|---|---|
| Free air, endplate 250 mm (AR_eff 2.16), SST-LM | +10.7° (4 solves: 10.45, 11.24, 10.72; settles about 10.9) | −1.335 | 0.291 (0.262 induced) | **upper (pressure) surface stalled, 1% to 92%**; lower from 88% | Flap 2 from 97%, Flap 3 from 91% |
| same, fully turbulent SST | +10.7° | −1.302 | 0.282 | **upper surface stalled, 1% to 93%** | Flap 3 from 89% |
| Over a ground, 80 mm (h/b 0.08, ground factor 0.45) | none: stopped | 2D at the full angle did not converge (Cl about −6.3, swinging; residual down 3.2 orders) | | | |
| Over a ground, STAR's 35 mm, endplate 315 mm (AR_eff 2.34, ground factor 0.27), SST-LM | none: stopped (solve 1 +6.54°, from the estimate; solve 2 +2.03° did not converge) | −0.05 at +6.54° | 0.118 | **upper (pressure) surface stalled, LE to 88%** | every flap stalled on its pressure surface |

So with the wing run at the angle the flow meets it on the car, AeroBench separates the main on its upper (pressure) surface, as STAR did, and both models agree. Its lift falls from −1.04 (2D) to −0.23. The loop had not settled to 0.1° in 4 solves: the main is stalling there, Cl moves 0.16 a degree, and plain relaxation swung about the answer; it now takes a secant step from the third solve. The SST check's Cd here is the section's plus its own induced drag (the engine adds it since 8dbe072).

Over the ground the 2D section at its full angle has no steady answer at 80 mm (h/c 0.12): the loop steered by its swinging Cl to +12.5°, where the wing pitched against the ground failed outright (Cl +0.25, residual down 1.3 orders). Since 199d846 the loop stops at the first solve that does not converge and says so. To be redone with STAR's ride height; if the 2D solve at the full angle is unsteady there too, the loop needs a first angle from somewhere else (the quick estimate's lift) instead.

At STAR's 35 mm and 315 mm endplate (14 Nov) the loop does not settle. The quick estimate puts the induced angle at +6.5° (Cl about −3, AR_eff 2.34, ground factor 0.27). RANS there stalls the main and every flap on the pressure surface (Cl −0.05, wanting +0.1°), and at +2.0° it does not converge. The main's pressure-side stall agrees with STAR; the downforce does not stand. Over a ground the loop pitches the wing by the induced angle, with its lowest point held at the ride height. That also lifts the flaps away from the ground: 6.5° over 0.68 m of chord is tens of millimetres at a 35 mm ride height. On Zerihan's wing (AR_eff 5.8) the angle is 1.3° and the pitch barely moves it (within 3%, ../ground-3d). On a low-aspect-ratio wing this close to the ground it is not checked. STAR's downforce is what decides it.

