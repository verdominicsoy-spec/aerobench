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
