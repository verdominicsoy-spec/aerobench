# The estimate's RANS references, run again with transition RANS

`validation.RANS_REFERENCES` holds the two-element NACA 6212 starting wing
(15 m/s, Re about 3e5 on the main) as SA on the quick mesh. On 2026-11-10 the
engine's default became SST with Langtry-Menter transition on the fine mesh,
so the cases were run again that way (`run.py`, results in `results.json`;
free-air angles each restarted from the one before).

| Case | SA quick Cl, Cd | SST-LM fine, 10 Nov | SST-LM fine sustained, 13 Nov | Estimate Cl, Cd | Estimate against 13 Nov |
|---|---|---|---|---|---|
| starting wing, 0° | -2.168, 0.0347 | -2.131, 0.0328 | -2.153, 0.0312 | -2.177, 0.0357 | Cl +1.1%, Cd +14.3% |
| starting wing, -3° | -2.410, 0.0443 | -2.387, 0.0403 | -2.413, 0.0378 | -2.441, 0.0481 | Cl +1.2%, Cd +27.4% |
| starting wing, -6° | -2.504, 0.0642 | -2.488, 0.0726 | -2.555, 0.0626 | -2.440, 0.0658 | Cl -4.5%, Cd +5.2% |
| starting wing, -9° | separated | separated, not converged | main separates from 37%, not converged | separating | agrees |
| 300 mm over a ground | -2.827, 0.0476 | -2.771, 0.0437 | -2.803, 0.0417 | -2.858, 0.0488 | Cl +2.0%, Cd +17.0% |
| 150 mm over a ground | -3.484, 0.0707 | -3.428, 0.0616 | -3.462, 0.0607 (unsteady mean) | -3.375, 0.0643 | Cl -2.5%, Cd +5.9% |
| 60 mm over a ground | not converged | not converged (Cl -4.82) | not converged (Cl -4.38), main separates from 87% | separating | no reference |
| design check (flap 32.1°) | -2.438, 0.0545 | not converged, flap separated | -2.437, 0.0487, flap separates from 52% | -2.520, 0.0572 | Cl +3.4%, Cd +17.5% |

The 13 Nov column is the current engine: far-field turbulence sustained to the
wing (`SST_OPTIONS= SUSTAINING`), unsteady flows settled over whole periods and
reported as their mean. It moved lift by at most 3% and cut drag 2-14% from
10 Nov; the design check now converges and lands on the SA lift.

The models agree on lift to 2% (SA against SST-LM sustained). SST-LM drag is
3-15% lower than SA's. The estimate's lift is within 5% of it in every
attached case; its drag is 5-27% higher. SST-LM also reports the flap
separating from 72-80% of its chord in every attached case, the same early trailing-edge
separation every SU2 model shows on aft-loaded sections at this Reynolds
number (SST-LM's turbulent layer behind the laminar bubble: shape factor 1.7
against XFOIL's 1.35; see ../uiuc-transition/README.md). So neither set's
drag is good to better than about 15% here, and the estimate was not refitted
to these: fitting its drag constants to a reference with a known model error
would only move the error. The references in the code stay as they were. A
multi-element tunnel case at FS Reynolds numbers is what would settle it.
