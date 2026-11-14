"""Zerihan's T026 wing in spanwise strips (finite.couple_strips on vlm.Lattice.strips)
from the RANS already run: no new solves. Each height's section polar is the
straight line through its two RANS points, the 2D section at the drawn angle
and the on-car run at its effective angle, carried on past both. Prints the
wing's CL and the mid-span strip's Cl against the balance and Figure 9b.

    engine/.venv/bin/python docs/validation/ground-3d/strips.py
"""
import json
from pathlib import Path

import numpy as np

from aeroengine.wing.finite import couple_strips
from aeroengine.wing.vlm import Lattice

HERE = Path(__file__).resolve().parent
CHORD, SPAN, ENDPLATE, STRIPS = 0.2234, 1.1, 0.100, 12
res = json.loads((HERE / "results.json").read_text())
out = {}
print("h/c   strips CL  balance  err    mid Cl  Fig 9b  err    single strip  angles (deg) tip..mid")
for case, r in res.items():
    two, car, m = r["two_d"], r["on_car"], r["measured"]
    a1 = car["finite"]["alpha_effective"]
    # The section's own sign: results carry downforce positive.
    x = np.array([0.0, a1])
    y = -np.array([two["cl"], car["cl"]])
    slope = (y[1] - y[0]) / (x[1] - x[0])
    angles = np.array([-10.0, 10.0])
    polar = (list(angles), list(y[0] + slope * angles))
    ride = None if case == "free" else float(case) * CHORD
    s = Lattice(span=SPAN, chord=CHORD, height=ride, endplate=ENDPLATE, endplate_bottom=ride).strips(STRIPS)
    if slope <= 0:  # the two points say Cl falls with angle: the 2D solve stalled early, no polar to run on
        print(f"{case:5} no strips: the 2D point ({'converged' if two['converged'] else 'not converged'}) "
              f"puts the polar past stall")
        out[case] = {"past_stall": True}
        continue
    c = couple_strips([polar] * STRIPS, s.k, s.width, 0.0)
    cl, mid = -c["cl_wing"], -0.5 * (c["cl"][STRIPS // 2 - 1] + c["cl"][STRIPS // 2])
    w, ctr = m.get("cl_wing"), m.get("cl_centre")
    pct = lambda a, b: f"{100 * (a / b - 1):+5.1f}%" if b else "   -  "  # noqa: E731
    print(f"{case:5} {cl:8.3f} {w or float('nan'):8.3f} {pct(cl, w)} {mid:7.3f} {ctr or float('nan'):7.3f} {pct(mid, ctr)} "
          f"{car['cl']:8.3f}      " + " ".join(f"{a:+.2f}" for a in c["alpha"][:STRIPS // 2]))
    out[case] = {"cl_wing": round(cl, 4), "cl_mid": round(mid, 4), "alpha": [round(a, 3) for a in c["alpha"]],
                 "two_d_converged": two["converged"], "on_car_converged": car["converged"]}
(HERE / "strips.json").write_text(json.dumps(out, indent=1))
