# A 3D wing in ground effect: Zerihan's Tyrrell 026 main element

The one published case found with a front wing's own geometry, endplates, a moving ground and both the whole wing's lift and where it separates: J. Zerihan, "An Investigation into the Aerodynamics of Wings in Ground Effect", PhD thesis, University of Southampton, 2001 (eprints.soton.ac.uk/426058; the user supplied the PDF).

- Wing: the 1998 Tyrrell 026 front-wing main element at 80% scale, 223.4 mm chord, 1100 mm span (AR 4.92), endplates 250 x 100 mm, 1.65 mm trailing edge. Coordinates: Table 2, at the reference incidence (1 deg quoted, 3.45 deg true). `run.py` puts them through the published cases' geometry path (`../published/build.py`): outline within 0.04% of chord, trailing edge 1.63 mm.
- Tunnel: 30 m/s, Re 0.43-0.46e6, moving belt, freestream turbulence 0.2%, transition free. Height h: ground to the wing's lowest point.
- Measured: the whole wing's CL from the balance and the mid-span sectional Cl from the chordwise pressures (Figure 9b, digitised to about +-0.01; the freestream CL of 0.69 from the text), and where the suction-surface boundary layer detaches at the semispan (Table 9, oil flow). Table 15's "experimental" column matches Figure 9b at h/c 0.671 but reads lower nearer the ground; the author calls it an estimate, so Figure 9b is used.

## Results (13-14 Nov 2026, SST-LM, fine mesh, current engine)

"2D" is the section at its full angle; "on the car" is `rans.solve_finite`, whose Cl stands for the whole wing. Its induced angle came from lifting line (Hoerner endplates, Wieselsberger ground factor) on 13 Nov, and from the vortex lattice (`wing/vlm.py`: wing, endplates and the gap under them, the ground as a mirror) from 14 Nov. Down to h/c 0.134 the lattice angle is within 3% of lifting line's, which moves the lift under 0.6%, so those rows were not rerun; 0.090 and 0.067 are the lattice runs. "Unsteady" means the flow has no steady answer and the number is its mean.

| h/c | 2D Cl | measured mid-span Cl | 2D separates from | On-car separates from | measured | Induced angle | On-car Cl | measured wing CL | on car vs measured |
|---|---|---|---|---|---|---|---|---|---|
| free | 0.836 | 0.766 (Table 15) | attached | attached | - | +1.96 deg | 0.620 (unsteady) | 0.69 | -10.1% |
| 0.448 | 1.122 | 1.026 | attached | attached | - | +1.39 deg | 0.916 | 0.941 | -2.7% |
| 0.224 | 1.444 | 1.395 | 0.988 | attached | 0.99 | +1.31 deg | 1.291 (unsteady) | 1.269 | +1.7% |
| 0.134 | 1.721 (unsteady) | 1.684 | 0.866 | 0.931 | 0.91 | +1.33 deg | 1.608 (unsteady) | 1.612 | -0.2% |
| 0.090 | 1.579 (not converged) | 1.759 | 0.719 | 0.786 | 0.80 | +0.84 deg (lifting line +1.36: 1.634, -5.0%) | 1.673 | 1.72 | -2.7% |
| 0.067 | 1.669 (not converged) | 1.765 | 0.677 | 0.696 | 0.71 | +0.34 deg (lifting line +1.27: 1.535, -10.2%) | 1.698 (not converged) | 1.71 | -0.7% |

What it says:
- From h/c 0.448 down to 0.134 the run as on the car lands within 3% of the balance, and where the wing separates within about 0.02 chord of the oil flow.
- Below 0.134 lifting line read low: -5% at 0.090, -10% at 0.067, with separation still within 0.03 chord of the oil flow, so the stall was right and the induced angle wrong. The thesis's PIV shows the tip vortex weakening suddenly below h/c 0.134, as the gap under the endplate is too small for it to roll up (section 4.7), so the tip losses shrink. The balance agrees: the whole wing's CL sits 8-9% under the mid-span Cl at 0.448 and 0.224 but only 2-3% under it at 0.090 and 0.067. Lifting line with the Wieselsberger factor keeps the induced angle near 1.3 deg all the way down.
- The vortex lattice sees the gap close: its angle falls to +0.84 deg at 0.090 and +0.34 deg at 0.067, and the runs land at -2.7% and -0.7%, separation within 0.015 chord of the oil flow. Nothing is fitted to this wing. The 0.067 run is not converged (residual down 1.6 orders, one solve of the angle loop), so its -0.7% is a moving number; 0.090 settled in three solves. A linear lattice cannot roll a vortex up or let it collapse, so the agreement comes from the mirror closing the gap, not from the vortex physics.
- In free air it reads 10% low. Why, as far as it goes:
  - Not the downwash model. The measured 3D lift slope is 4.57 /rad (thesis section 3.2). Lifting line with AR_eff 5.77 on NeuralFoil's 2D slope at the reference (6.36 /rad) gives 4.71 /rad, 3% steeper than the tunnel. So the downwash is not too strong.
  - About 4 points are the tunnel. Every force test ran in the closed 2.1 x 1.7 m tunnel (section 2.5), and the thesis applies no wall corrections. The free-air test sat at its centre. For a closed rectangular section (Rae & Pope, delta about 0.125, S/C 0.069), the walls cut the wing's downwash by about 0.34 deg at CL 0.69. That is CL +0.027, so the free-air CL corrected to open air is about 0.663. Blockage is under 0.2% of q. Near the moving ground, the vortices and their images act as a pair, and the walls do much less.
  - About 6 points are the 2D section. RANS gives 0.836 at the reference angle; NeuralFoil gives 0.903. Lifting line on NeuralFoil gives CL 0.669, within 1% of the corrected 0.663. The thesis's oil flow at 1 deg puts transition near 0.3 chord through a small bubble (section 3.3.2). RANS puts its suction-side bubble at 0.64-0.81. The same RANS lands within 3% in ground effect, so this part is not explained.
- Down to h/c 0.134 the 2D section at its full angle reads 2-9% above the mid-span pressures, which also carry the wing's own downwash, so the 2D number is not the one to compare with a car.
- The 2D section at its full angle separates 0.03-0.08 chord early below 0.224 (the post-bubble turbulent layer, see ../uiuc-transition) and does not settle; the on-car runs, at the lower angle, match the oil flow.
- Several runs here led to engine fixes: a continued run is judged from where the first began; an oscillating run settles over whole periods; a flow with no steady answer is reported as unsteady with its mean.

## In spanwise strips (14 Nov, `strips.py`, no new solves)

The same wing in 12 strips across the span (`finite.couple_strips` on `vlm.Lattice.strips`), each meeting the flow at its own induced angle from every strip's lift. Each height's section polar is the straight line through its two RANS points (2D at the drawn angle, on the car at its effective angle). The strips give the spanwise load, so the mid-span strip can be checked against the mid-span pressures as well as the wing against the balance.

| h/c | strips: wing CL | balance | error | mid-span Cl | Figure 9b | error | tip strip's angle | mid-span strip's angle |
|---|---|---|---|---|---|---|---|---|
| free | 0.619 | 0.69 | -10.3% | 0.670 | 0.766 (Table 15) | -12.5% | +2.87 deg | +1.52 deg |
| 0.448 | 0.895 | 0.941 | -4.9% | 1.008 | 1.026 | -1.8% | +2.93 deg | +0.77 deg |
| 0.224 | 1.251 | 1.269 | -1.4% | 1.390 | 1.395 | -0.4% | +4.04 deg | +0.45 deg |
| 0.134 | 1.570 | 1.612 | -2.6% | 1.701 | 1.684 | +1.0% | +5.15 deg | +0.22 deg |
| 0.090, 0.067 | not run | | | | | | | |

- The mid-span Cl lands within 2% of the pressures from h/c 0.448 to 0.134, so the spanwise load is right where it can be checked: the tips carry less, by an angle that grows from 2 to 5 deg as the ground comes up.
- The wing's CL reads 1-5% under the balance, a point or two lower than the single strip. Part is the endplates' own side force: about 2% of the induced drag, a thrust no wing strip sees, which the single strip's angle counts in and the strips leave out. The tip strips also run 2-5 deg past the two RANS points the straight polar is drawn through.
- At 0.090 and 0.067 the 2D point (not converged, separating early) has more lift than the on-car one at a smaller angle, so the straight line through them says Cl falls as the angle rises, which is a stalled section. `couple_strips` names such strips past stall and these rows are left out rather than run on a polar that is not the section's.

