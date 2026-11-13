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

None of these runs separates the main: the 2D section at its full angle does not. A diagnostic run with the flow turned +10° (fully turbulent, sustained; the induced angle lifting line gives this wing in free air without endplates is about 12°) does: the main's pressure surface reversed from 1% to 91% of chord, its Cl from −1.02 to −0.27. That is what `rans.solve_finite` (the run as on the car) is for; its numbers for this wing go here once it has run with the span, endplate and ride height of the STAR model.
