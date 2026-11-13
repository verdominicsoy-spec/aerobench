# A 3D wing in ground effect: Zerihan's Tyrrell 026 main element

The one published case found with a front wing's own geometry, endplates, a moving ground and both the whole wing's lift and where it separates: J. Zerihan, "An Investigation into the Aerodynamics of Wings in Ground Effect", PhD thesis, University of Southampton, 2001 (eprints.soton.ac.uk/426058; the user supplied the PDF).

- Wing: the 1998 Tyrrell 026 front-wing main element at 80% scale, 223.4 mm chord, 1100 mm span (AR 4.92), endplates 250 x 100 mm, 1.65 mm trailing edge. Coordinates: Table 2, at the reference incidence (1 deg quoted, 3.45 deg true). `run.py` puts them through the published cases' geometry path (`../published/build.py`): outline within 0.04% of chord, trailing edge 1.63 mm.
- Tunnel: 30 m/s, Re 0.43-0.46e6, moving belt, freestream turbulence 0.2%, transition free. Height h: ground to the wing's lowest point.
- Measured: the whole wing's CL from the balance and the mid-span sectional Cl from the chordwise pressures (Figure 9b, digitised to about +-0.01; the freestream CL of 0.69 from the text), and where the suction-surface boundary layer detaches at the semispan (Table 9, oil flow). Table 15's "experimental" column matches Figure 9b at h/c 0.671 but reads lower nearer the ground; the author calls it an estimate, so Figure 9b is used.

## Results so far (13 Nov 2026, SST-LM, fine mesh)

"2D" is the section at its full angle; "on the car" is `rans.solve_finite` (lifting-line induced angle on span and endplates, cut by the ground factor), whose Cl stands for the whole wing.

| h/c | 2D Cl | measured mid-span Cl | 2D separates from | measured | Induced angle | On-car Cl | measured wing CL | on car vs measured |
|---|---|---|---|---|---|---|---|---|
| free | 0.836 | 0.766 (Table 15) | attached | - | +1.97 deg | 0.623 | 0.69 | -10% |
| 0.448 | 1.122 | 1.026 | attached | - | +1.39 deg | 0.916 | 0.941 | -2.7% |
| 0.224 | 1.444 | 1.395 | 0.988 | 0.99 | +1.19 deg | 1.277 (unsteady mean) | 1.269 | +0.6% |
| 0.134 | 1.788 | 1.684 | 0.866 | 0.91 | not run | | 1.612 | |
| 0.090, 0.067 | not run | 1.759, 1.765 | | 0.80, 0.71 | | | 1.72, 1.71 | |

The 0.134 2D row is from the run log; the job was stopped before it saved that height.

What it says so far:
- In ground effect, the run as on the car lands within 3% of the balance (0.448 and 0.224). In free air it reads 10% low. Why, as far as it goes:
  - Not the downwash model. The measured 3D lift slope is 4.57 /rad (thesis section 3.2). Lifting line with AR_eff 5.77 on NeuralFoil's 2D slope at the reference (6.36 /rad) gives 4.71 /rad, 3% steeper than the tunnel. So the downwash is not too strong.
  - About 4 points are the tunnel. Every force test ran in the closed 2.1 x 1.7 m tunnel (section 2.5), and the thesis applies no wall corrections. The free-air test sat at its centre. For a closed rectangular section (Rae & Pope, delta about 0.125, S/C 0.069), the walls cut the wing's downwash by about 0.34 deg at CL 0.69. That is CL +0.027, so the free-air CL corrected to open air is about 0.663. Blockage is under 0.2% of q. Near the moving ground, the vortices and their images act as a pair, and the walls do much less.
  - About 6 points are the 2D section. RANS gives 0.836 at the reference angle; NeuralFoil gives 0.903. Lifting line on NeuralFoil gives CL 0.669, within 1% of the corrected 0.663. The thesis's oil flow at 1 deg puts transition near 0.3 chord through a small bubble (section 3.3.2). RANS puts its suction-side bubble at 0.64-0.81. The same RANS lands within 3% in ground effect, so this part is not explained.
- The 2D section at its full angle reads 4-9% above the mid-span pressures, which also carry the wing's own downwash, so the 2D number is not the one to compare with a car.
- Where it separates, 2D: 0.988 against 0.99 at h/c 0.224; 0.866 against 0.91 at 0.134 (early, as the post-bubble turbulent layer is too thin-walled, see ../uiuc-transition). The on-car runs separate less, as expected at the lower angle, but the oil flow is at the 3D wing's semispan, which sees less downwash than the average.
- Several runs here led to engine fixes: a continued run is judged from where the first began; an oscillating run settles over whole periods; a flow with no steady answer is reported as unsteady with its mean.

To finish: `cd engine && .venv/bin/python ../docs/validation/ground-3d/run.py 10 0.134 0.090 0.067` (two_d results already in results.json are kept), and run the free and 0.224 on-car again on the current engine.
