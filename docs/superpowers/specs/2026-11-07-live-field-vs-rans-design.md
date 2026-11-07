# Live field against RANS: findings and design

Wing Lab's live colour field (`PanelSolution.field`, `AeroBenchKit/PanelField.swift`) was measured against
every saved RANS field on this machine (12 runs in `~/Library/Application Support/AeroBench/Scratch/jobs`,
each with `job.json`, `result.json`, `field.json`/`field.bin`), built exactly as `WingLabModel.recompute()`
builds it, with the live estimate's `cd_own` sizing the wakes. Commit at measurement: `04730ed`.

## Cases

| Run | Elements | Mesh, model | Ride height | Converged | RANS Cl / Cd | Use |
|---|---|---|---|---|---|---|
| 20261106-171046-1b32 | 2 | fine, SST-LM | free air | yes | −1.897 / 0.0194 | trusted |
| 20261106-165749-4fb8 | 2 (same wing) | quick, SST | free air | yes | −1.852 / 0.0274 | trusted |
| 20261104-172944-23aa | 3 | quick, SA | free air | yes | −1.980 / 0.0340 | trusted |
| 20261104-173556-baec | 3 | quick, SA | free air | yes | −2.469 / 0.0464 | trusted |
| 20261106-120151-c003 | 5 | medium, SST | 0.707 m | yes | −2.793 / 0.0863 | trusted (ground) |
| 20261103-170524-8b6b | 5 | medium, SA | free air | no (Cl moving 1e-4) | −1.236 / 0.0312 | near-trusted |
| 20261104-174508-2ed3 | 2 | quick, SA | 0.03 m | yes, Cd 0.51 | −1.809 / 0.5136 | separated |
| c608, a352, 90cd, b194 | 2–3 | various | free, 0.16 m | no | — | separated / unconverged |

`c132` duplicates `1b32`. RANS drag itself moves 41% between the quick and fine mesh on the same wing (4fb8 vs 1b32).

## What the numbers say (trusted cases, live grid 400 cells as the app)

1. **Too much circulation.** The panel solution carries 4–29% more lift than RANS in free air and 45% more over
   the ground (`c003`: −4.05 vs −2.79; `groundCorrected` rescales only the reported lift, not the flow).
   The live estimate's per-element lift is far closer: total within 0.10, worst element 0.17 (panel: 0.37–0.58, 0.40).
   Consequences measured: field Cp bias −0.06 to −0.41 near the wing; streamline ends off by 2–6% of the
   reference chord (median), 5–18% (p95); wake centroid 0.025–0.12 reference chords too high (steeper path).
2. **Wake spreads too slowly.** Second-moment wake width, live over RANS, at 0.25–1 reference chord behind the
   last trailing edge: 0.40–0.96, falling downstream. The zero-pressure-gradient law (half-width 0.3 √(θ s))
   underestimates wakes behind high-lift wings. Both meshes of the same wing agree, so it is not mesh diffusion.
3. **Wake loss follows the estimate's drag.** ∫ −Cp0 dy live over RANS is 0.46–1.06, tracking est/RANS Cd
   (0.60–1.33). Not a field fault; RANS drag is itself ±40% between meshes.
4. **Surface layers and near wake.** Fixed in `04730ed` (virtual origin 4 θ). At a 1.4 mm grid: 2–6 mm to half
   loss against RANS 1–3 mm. At the app's grid (about 4 mm cells) they draw one cell wide, faded.
5. **Slot jet missing.** RANS shows the flap's thin layer, a clean jet 2–8 mm thick, then the main wake 8–15 mm
   off the flap. Live puts the main wake centre 2.5–9 mm off, and its width covers the jet. Sub-grid at the app's
   resolution; not fixed (see Rejected).
6. **Separated or extreme-ground cases** (`2ed3`, unconverged runs): panel Cp to −180…−380, streamline errors
   0.37 reference chords. The estimate misses these too (`2ed3` Cl −2.51 vs −1.81, Cd 0.086 vs 0.51).

## Experiments (prototype in `docs/validation/live-field/prototype/`: `prototype.patch` against `04730ed`, the harness `LiveVsRans.swift.txt` and `engine_numbers.py`; not built)

**Prescribed circulation from the estimate** (each Kutta row replaced by Σ ½(γj + γj+1)|Δsj| = Γe; Γe scaled
three times by the element's target/achieved lift, clamped 0.3–1.5):

| Metric (6 trusted) | Kutta | Prescribed |
|---|---|---|
| Near-field Cp RMS / bias | 0.15–0.30 / −0.06…−0.41 | 0.03–0.11 / −0.02…+0.02 |
| Outer-field Cp RMS | 0.07–0.34 | 0.01–0.05 |
| Streamline end error p50 / p95 (÷ ref chord) | 0.021–0.057 / 0.05–0.18 | 0.005–0.021 / 0.007–0.057 |
| Wake centroid offset at s = 0.5 ref | +0.025…+0.12 | −0.008…+0.009 |
| Surface Cp RMS, 5–95% chord | 0.26–1.09 | 0.11–0.45 |
| Surface Cp RMS, whole surface | 0.47–1.59 | 6.6–113 (trailing-edge singularity) |

Field Cp within 2–5% of a reference chord of each trailing edge stays inside RANS's range at the app's grid,
so the singularity shows only on the surface Cp chart.

**Wake growth factor k** on θ s in σ² (sweep 1, 2, 3, 4, 6; mean |ln(width ratio)|): 0.48, 0.28, 0.22, 0.21, 0.26.
k = 3 chosen (±24% mean width error, was ±62%).

**Clearance** (wake centre held ≥ 1.5 or 2.5 σ off other elements): centroid error 0.007 → 0.031/0.053 reference
chords, width error worse, slot still not clean at the app's grid. Rejected.

## Decisions

- The preview (field, streamlines, surface Cp chart) uses circulation prescribed from the live estimate's
  per-element lift when the estimate is of the wing as drawn; otherwise the Kutta solution as today.
- Over the ground the image solution takes the targets directly; `groundCorrected` stays for the Kutta fallback.
- The surface Cp chart leaves out each surface's last 5% of chord when lift-matched, and says so in its title.
- Wake width: σ = 0.255 √(θ (3 s + 4 θ)).
- A committed fixture of three RANS fields and a validation test pin the gains.
- When the estimate row says the wing separates, the canvas says the live field cannot show it.

## Rejected

- Trailing-edge vortex keeping the Kutta condition (cleaner surface, more work): the trailing-edge singularity
  is invisible in the field at the app's grid, and trimming 5% of the chart removes it.
- Wake clearance off other elements: shifts wakes downstream (above).
- Calibrating wake loss to RANS: RANS drag itself moves ±40% with the mesh; the estimate owns drag.
