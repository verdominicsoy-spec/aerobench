"""frontwing#1.02 as STAR ran it, in spanwise strips on the SST polars of
run_polars.py (polars.json): 6 strips between the 315 mm endplates, the wing
45 mm lower at the inner end, endplate bottoms 35 mm off the ground. Each
strip's polar is interpolated in height between the two run heights about
it. Also the single strip on the mid-span polar, for the same answer as
rans.solve_finite without its loop. Writes strips.json.

    engine/.venv/bin/python docs/validation/frontwing1/run_strips.py
"""
import json
from pathlib import Path

import numpy as np

from aeroengine.wing.finite import couple_strips, lattice_factors
from aeroengine.wing.vlm import Lattice

HERE = Path(__file__).resolve().parent
SPAN, CHORD, PLANFORM, ENDPLATE, BOTTOM, MID, DROP, ALPHA, STRIPS = 0.5245, 0.682, 0.6245, 0.315, 0.035, 0.0966, 0.045, -7.45, 6

runs = json.loads((HERE / "polars.json").read_text())
polars = {}
for h, rows in runs.items():  # converged solves, and unsteady ones by their mean; never an unconverged Cl
    good = sorted((r["alpha"], r["cl"]) for r in rows if r["converged"] or r.get("unsteady"))
    polars[float(h)] = (np.array([a for a, _ in good]), np.array([c for _, c in good]))
heights = sorted(polars)
for h in heights:
    print(f"polar at {h * 1000:.1f} mm: " + ", ".join(f"{a:+.2f} deg {c:+.3f}" for a, c in zip(*polars[h])))


def polar_at(h: float):
    """Cl against angle at height h, straight between the two run heights about it (held at the ends)."""
    lo = max([x for x in heights if x <= h], default=heights[0])
    hi = min([x for x in heights if x >= h], default=heights[-1])
    angles = np.intersect1d(polars[lo][0], polars[hi][0])
    t = 0.0 if hi == lo else (h - lo) / (hi - lo)
    c = [(1 - t) * np.interp(a, *polars[lo]) + t * np.interp(a, *polars[hi]) for a in angles]
    return list(angles), c


lat = Lattice(span=SPAN, chord=PLANFORM, height=MID, endplate=ENDPLATE, endplate_bottom=BOTTOM, drop=DROP)
s = lat.strips(STRIPS)
k = s.k * CHORD / PLANFORM  # per unit Cl on the elements' summed chord, as RANS reports it
c = couple_strips([polar_at(h) for h in s.height], k, s.width, ALPHA)
ar, gf = lattice_factors(SPAN, CHORD, ENDPLATE, MID, PLANFORM, BOTTOM)
one = couple_strips([polar_at(MID)], np.array([[gf / (np.pi * ar)]]), np.array([1.0]), ALPHA)
print(f"strips: wing Cl {c['cl_wing']:+.3f} on {SPAN} x {CHORD} m, converged {c['converged']}")
for i, (y, h, a, cl) in enumerate(zip(s.y, s.height, c["alpha"], c["cl"])):
    flag = " past stall" if i in c["past_stall"] else " on a cliff" if i in c["steep"] else \
        " outside its polar" if i in c["out_of_range"] else ""
    print(f"  y {y * 1000:+6.1f} mm, {h * 1000:5.1f} mm up: {a:+.2f} deg, Cl {cl:+.3f}{flag}")
print(f"single strip at mid-span: {one['alpha'][0]:+.2f} deg, Cl {one['cl'][0]:+.3f}"
      + (" on a cliff" if one["steep"] else " past stall" if one["past_stall"] else ""))
(HERE / "strips.json").write_text(json.dumps({"strips": {**c, "y": s.y.tolist(), "height": s.height.tolist()},
                                              "single": one}, indent=1))
