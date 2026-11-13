# Transition RANS on the ten UIUC benchmark sections (Re about 3e5)

SU2 SST with Langtry-Menter transition (`model: sst-lm`, `transition: auto`,
n_crit 9, turbulence intensity 0.1%, rising sweep), the ten sections of
`validation.benchmark_cases()`, 10 November 2026. Each file maps a section to
its rows `[alpha, cl, cd, converged]`, the errors from `validation.errors`
(only converged angles count), the angles planned and the seconds taken.

- `sst_lm_quick.json`: quick mesh. Lift 5.6%, drag 34%, 67 of 108 angles converged; sd7037 diverged.
- `sst_lm_fine.json`: fine mesh. Lift 4.0%, drag 18.5%, 82 of 108 converged, 4.0 h on 12 cores. Drag high on all ten (+5 to +34%).
- `sst_lm_extra_fine.json`: spacing 0.36, wall growth 1.07, e423 and sa7038 only. Drag 31.1% and 14.9% against 33.7% and 13.2% on fine: the mesh is not the cause.

Why the drag stays high: see "Root causes of the remaining errors" in
`../published/README.md`.

## Where the drag error comes from (13 Nov 2026)

On s1223 at 6 deg (Re 3e5; tunnel Cd 0.0225), SST-LM reads Cd 0.0278, 75% of it pressure drag. Every SU2 option was tried from the same solution:

| s1223, 6 deg | Cd |
|---|---|
| SST-LM as the app runs it (sustained Tu 0.1%) | 0.0278 |
| JST fourth-order dissipation 0.002 / least-squares gradients / second-order turbulence convection | 0.0277 / 0.0278 / 0.0279 |
| FDS upwind with least-squares reconstruction | 0.0302 |
| Correlations MALAN / MEDIDA_BAEDER (LM2015 is 3D only) | 0.0279 / 0.0361 |
| SST-1994m (production limiter 20 instead of 10) | 0.0276 |
| Fully turbulent SST | 0.0313 (NeuralFoil tripped at the nose: 0.0308) |
| Patched SU2 (`su2_lm_constants.patch`): F_reattach threshold 40 | 0.0278 |
| Patched SU2: separation-transition production s1 = 4 (published 2) | 0.0273 |

Fully turbulent, SU2 and XFOIL's method (NeuralFoil) agree within 2%, so the turbulence model is right on an ordinary turbulent layer. The difference is behind the laminar bubble (0.26-0.39 of chord in both): momentum thickness matches NeuralFoil within 3% from 0.5 chord on, but the shape factor is 1.7 against 1.35. Langtry-Menter's separation term (gamma_sep reaches 2 in the bubble) shuts off by itself once the strain Reynolds number drops after reattachment, not through F_reattach (raising its threshold changes nothing), so the layer behind the bubble is an ordinary equilibrium turbulent layer; the real one, and XFOIL's calibrated on it, is much fuller, stays attached to 0.98 chord and has less pressure drag. Doubling the production inside the bubble (s1 = 4) shortens it a little and takes off 2% (Cl unchanged), a tenth of the gap to the tunnel. A model-form limit of the transition model at these Reynolds numbers, not a setting: the app shows the measured band on RANS drag where it applies, and the stock SU2 stays.

`run_sustained.py` ran the sections again with sustained turbulence: s1223 lift 7.5%, drag 28.9% (was 7.4%, 29.1%); the others were not rerun.
