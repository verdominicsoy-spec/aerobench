# AeroBench against published multi-element wind-tunnel data

November 2026. Engine at commit e1ba409. Every number here comes from the
scripts in this folder; how to rerun them is at the end.

## What was compared

Three methods, each run the way the app runs it:

- **Estimate**: `aeroengine.wing.estimate.estimate`, the live result in Wing
  Lab (panel method for the interaction, NeuralFoil for each element).
- **Panel**: `aeroengine.wing.panel`, the inviscid multi-element panel method
  on its own (no boundary layer, no stall).
- **RANS**: `aeroengine.wing.rans.sweep`, SU2 incompressible with the app's
  default model (SST, fully turbulent), its own mesher, `quick` and `medium`
  mesh levels, angles run low to high with each angle restarted from the one
  below, 4000 iterations at most.

All three are incompressible. Both tunnels ran at M 0.185 to 0.2, so on lift
alone the Prandtl-Glauert factor would put the tests about 2% above an
incompressible result; at 30P30N's highest angles the slat peak reaches
Cp -17 (locally supersonic, per NASA TM-112858), which no method here can
represent.

Geometry goes through the same path as an imported section: each element is
re-panelled to 161 points by `airfoils.normalise` and placed by
`geometry.Element` (chord, angle, leading edge). `build.py` prints how far the
re-panelled outline lies from the published one (largest distance, in
reference chords): 30P30N slat 0.0005, main 0.0040 (the cove corners are
rounded off), flap 0.0001; NLR 7301 main 0.0002, flap 0.0002 (gap 2.6%) and
0.0005 (gap 1.3%).

## Sources

### Reproduced

**McDonnell Douglas 30P30N, three elements (slat, main, flap at 30/30 deg).**
- Data and geometry: NASA / AIAA 4th High Lift Prediction Workshop auxiliary
  test case, `AuxTestCase_HLPW4_30p30n_v1.tar.gz` (SHA-256
  9a6e4ae5625eb4a03cdaab22d375effcf3c3b821409daa5b1278d1c16d074127) inside
  https://hlpw4.s3.us-east-1.amazonaws.com/website/Workshop4.zip. The files
  used are copied unchanged into `data/30p30n/` (geometry
  `2010_30p30n_thik_te_18inches.crv.dat`, `clalpha_exp.dat`, `cp_exp.dat`,
  the three READMEs).
- Experiment: NASA Langley LTPT, M 0.2, Re 9 million on the stowed chord,
  corrected angles 8.10, 16.21, 21.34, 23.28 deg. Klausmeyer, S. M. and Lin,
  J. C., "Comparative Results From a CFD Challenge Over a 2D Three-Element
  High-Lift Airfoil", NASA TM-112858, May 1997; Chin, V. D., Peters, D. W.,
  Spaid, F. W. and McGhee, R. J., "Flowfield Measurements About a
  Multi-Element Airfoil at High Reynolds Numbers", AIAA 93-3137, 1993.
- Geometry caveat (from the package): this is the BANC version with a
  thicker slat trailing edge than the LTPT model; otherwise "very close to
  the original". The package itself says the data "should be used only as a
  rough guide" because of three-dimensional effects at high lift.
- Rigging: slat -30 deg, gap 2.95% c, overhang -2.5% c; flap 30 deg, gap
  1.27% c, overhang 0.25% c. Slat chord 15% c, flap 30% c (engine chord
  lines: slat 0.152 c, main 0.832 c, flap 0.300 c).

**NLR 7301 with 32% flap at 20 deg (AGARD AR-138 case A2 / ERCOFTAC UFR 3-01).**
- Geometry: the solid walls of the SAAB FLOWNET structured grids for the
  2.6% and 1.3% gap settings (overlap 5.3% c), archive
  https://kbwiki-images.s3.amazonaws.com/5/5f/UFR3-01_nlr7301grid.zip
  (SHA-256 28aa28b47d981681df3b6300a41a6a9e1c029514ca28cb91bda699b32b7bfc62),
  linked from the ERCOFTAC UFR 3-01 test-case page. `build.py` extracts the
  two wall loops (block sides no other block side shares) into
  `data/nlr7301/nlr7301_gap26.dat` and `nlr7301_gap13.dat`. Both elements
  have finite trailing-edge bases (0.0009 c and 0.0012 c), kept as the gap
  between the outline's two ends.
- Experiment: van den Berg, B. and Oskam, B., "Boundary layer measurements on
  a two-dimensional wing with flap and a comparison with calculations", NLR MP
  79034 U (1979), also AGARD CP-271 and AGARD AR-138 case A2. M 0.185, Re 2.51
  million on the cruise chord (0.57 m chord model); lift from integrated
  pressures with wall corrections, Cl accuracy +/- 0.01, Cd +/- 2%. The two
  data points used, Cl 3.141 / Cd 0.0445 (gap 2.6%, alpha 13.1) and Cl 2.416
  / Cd 0.0229 (gap 1.3%, alpha 6.0), are the experimental row of Table 3 of
  ERCOFTAC UFR 3-01 "Evaluation" (https://kbwiki.ercoftac.org/w/index.php/UFR_3-01_Evaluation),
  which takes them from the EUROVAL / ECARP data (Haase et al. (eds.),
  EUROVAL, Notes on Numerical Fluid Mechanics 42, Vieweg, 1992, as cited by ERCOFTAC). I could not
  get the original AR-138 tables (no open copy found), so no lift curve, no
  Cl max and no surface Cp are compared for this case.
- Measured transition (UFR 3-01, Table 1): main upper surface 2.4 to 4.0% c,
  main lower 64 to 74% c, flap upper surface at x/c 1.063 to 1.081 (about
  55% of the flap chord), flap lower surface laminar throughout. RANS here is
  fully turbulent.

### Looked for and not reproduced

- **Zerihan and Zhang, Tyrrell 026 single element in ground effect**
  (J. Aircraft 37(6), 2000) and **Zhang and Zerihan double element in ground
  effect** ("Aerodynamics of a Double-Element Wing in Ground Effect", AIAA J.
  41(6), 2003). The section coordinates
  are not in the journal papers. They are in Zerihan's PhD thesis
  (University of Southampton, 2001, https://eprints.soton.ac.uk/426058), but
  the repository served a bot-protection page instead of the PDF and I did
  not try to get round it. No other public copy of the coordinates was
  found. **So nothing in this report tests ground effect against
  experiment.** Fetching the thesis by hand would make this the most useful
  next case for a racing user.
- **GA(W)-1 with 29% Fowler flap** (Wentz and Seetharam, NASA CR-2443, 1974,
  https://ntrs.nasa.gov/citations/19750004871). The report tabulates the
  GA(W)-1 and flap coordinates and the flap pivot points, but the main
  element's cove (the main is cut to 96% of the nested chord) is not
  tabulated, and the force data are only in plotted figures. Not reproducible
  without digitising plots and guessing the cove.
- **30P30N JAXA (APC-IV/V, M 0.17, Re 1.71 million)**: open geometry and
  Cp, but the angles are "open-air CFD-equivalent" angles set with SA
  computations, so the data are partly a CFD product; not used.
- **NLR 7301 Texas A&M tests** (van Dam et al., AIAA SciTech 2021,
  NTRS 20210025480): modified, thicker flap whose coordinates are not
  published.

## How to rerun

From the repository root (the engine's uv environment has NeuralFoil,
matplotlib and SU2 on its path as the app uses them):

```sh
cd engine
# 1. geometry -> data/*/elements.json (pass the ERCOFTAC zip to re-extract the NLR walls)
uv run python ../docs/validation/published/build.py [UFR3-01_nlr7301grid.zip]
# 2. estimate and panel method at 1-degree steps and the published angles -> results_quick.json (seconds)
uv run python ../docs/validation/published/quick.py
# 3. RANS sweeps -> results_rans.json (quick mesh 4 to 15 min per case on 12 cores; medium longer)
uv run python ../docs/validation/published/rans_runs.py /tmp/rans "NLR 7301 gap 2.6" quick sst 0 4 8 11 13.1 16
uv run python ../docs/validation/published/rans_runs.py /tmp/rans "NLR 7301 gap 1.3" quick sst 0 3 6 10
uv run python ../docs/validation/published/rans_runs.py /tmp/rans 30P30N quick sst 0 4 8.1 12 16.21 19 21.34 23.28
uv run python ../docs/validation/published/rans_runs.py /tmp/rans "NLR 7301 gap 2.6" medium sst 0 4 8 11 13.1
uv run python ../docs/validation/published/rans_runs.py /tmp/rans "NLR 7301 gap 1.3" medium sst 0 3 6
uv run python ../docs/validation/published/rans_runs.py /tmp/rans 30P30N medium sst 4 8.1 16.21
# 4. tables (printed) and plots/*.png
uv run python ../docs/validation/published/compare.py
```

The single-angle "from rest" NLR run in `results_rans.json` was
`rans_runs.py ... "NLR 7301 gap 2.6" quick sst 13.1`, relabelled by hand
afterwards so the sweep would not overwrite it.

Files: `build.py`, `quick.py`, `rans_runs.py`, `compare.py`;
`data/30p30n/` (NASA files, unchanged, plus `elements.json`);
`data/nlr7301/` (extracted walls and `elements_gap*.json`);
`results_quick.json`, `results_rans.json` (RANS forces, per-element forces
and surface Cp; the SU2 files themselves are not kept); `plots/`.
