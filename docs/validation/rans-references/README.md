# The estimate's RANS references, run again with transition RANS

`validation.RANS_REFERENCES` holds the two-element NACA 6212 starting wing
(15 m/s, Re about 3e5 on the main) as SA on the quick mesh. On 2026-11-10 the
engine's default became SST with Langtry-Menter transition on the fine mesh,
so the cases were run again that way (`run.py`, results in `results.json`;
free-air angles each restarted from the one before).

| Case | SA quick Cl, Cd | SST-LM fine Cl, Cd | Estimate Cl, Cd | Estimate against SST-LM |
|---|---|---|---|---|
| starting wing, 0° | -2.168, 0.0347 | -2.131, 0.0328 | -2.177, 0.0357 | Cl +2.2%, Cd +8.8% |
| starting wing, -3° | -2.410, 0.0443 | -2.387, 0.0403 | -2.441, 0.0481 | Cl +2.3%, Cd +19.3% |
| starting wing, -6° | -2.504, 0.0642 | -2.488, 0.0726 | -2.440, 0.0658 | Cl -1.9%, Cd -9.4% |
| starting wing, -9° | separated | separated, not converged | separating | agrees |
| 300 mm over a ground | -2.827, 0.0476 | -2.771, 0.0437 | -2.858, 0.0488 | Cl +3.1%, Cd +11.7% |
| 150 mm over a ground | -3.484, 0.0707 | -3.428, 0.0616 | -3.375, 0.0643 | Cl -1.5%, Cd +4.4% |
| 60 mm over a ground | not converged | not converged (Cl -4.82) | separating | no reference |
| design check (flap 32.1°) | -2.438, 0.0545 | not converged, flap separated | -2.520, 0.0572 | no reference |

The two models agree on lift to 2%. SST-LM drag is 5-13% lower at the low
angles and 13% higher at -6°. SST-LM also reports the flap separating from
76-80% of its chord in every attached case, the same early trailing-edge
separation every SU2 model shows on aft-loaded sections at this Reynolds
number (SST-LM's turbulent layer behind the laminar bubble: shape factor 1.7
against XFOIL's 1.35; see ../uiuc-transition/README.md). So neither set's
drag is good to better than about 15% here, and the estimate was not refitted
to these: fitting its drag constants to a reference with a known model error
would only move the error. The references in the code stay as they were. A
multi-element tunnel case at FS Reynolds numbers is what would settle it.
