"""frontwing#1.02 alone in STAR (wing, endplates, moving ground, half model, 20 m/s,
SST), from the files WingNumbers.java writes next to the sim: the force on each
element and endplate, the spanwise loading in AeroBench's 6 strips, and each strip's
Cl on AeroBench's reference (the 682 mm sum of the element chords). Writes star_wing.json.

    engine/.venv/bin/python docs/validation/frontwing1/star_wing.py <the sim's _wing folder>

STAR's axes: flow along -x, z up, span along y (outer endplate at the most negative y).
The surface table is the last iteration; its sum is checked against STAR's own force.
"""
import glob
import json
import sys
from pathlib import Path

import numpy as np
import scipy.sparse as sp
from scipy.sparse.csgraph import connected_components
from scipy.spatial import cKDTree

HERE = Path(__file__).resolve().parent
RHO, U, CHORD, STRIPS = 1.184, 20.0, 0.682, 6
NAMES = ["main", "flap 1", "flap 2", "flap 3"]
Q = 0.5 * RHO * U ** 2

d = sys.argv[1]
a = np.loadtxt(glob.glob(d + "/*_surface.csv")[0], delimiter=",", skiprows=1)
cp, p, tx, ty, tz, yplus, ax, ay, az, x, y, z = a.T
area = np.c_[ax, ay, az]
F = p[:, None] * area + np.c_[tx, ty, tz] * np.linalg.norm(area, axis=1)[:, None]  # on the body, N
total = F.sum(0)
print(f"surface table: Fx {total[0]:+.2f} Fy {total[1]:+.2f} Fz {total[2]:+.2f} N (STAR's report: -45.75, +1.79, -162.93)")

# The endplates' inner faces, from where the faces facing along y pile up at each end.
ny = np.abs(ay) / np.linalg.norm(area, axis=1)
flat = ny > 0.9


def face(lo, hi):
    m = flat & (y > lo) & (y < hi)
    h, e = np.histogram(y[m], bins=200, weights=np.linalg.norm(area[m], axis=1))
    return h, e


h, e = face(y.min(), y.min() + 0.03)
outer = e[np.argmax(h * (e[:-1] > y.min() + 0.004)) + 1]  # the biggest pile clear of the outside face
h, e = face(y.max() - 0.03, y.max())
inner = e[np.argmax(h * (e[1:] < y.max() - 0.004))]
span = inner - outer
wing = (y > outer + 0.001) & (y < inner - 0.001) & ~flat
print(f"endplate inner faces at y {outer:+.4f} and {inner:+.4f} m: span {span * 1000:.1f} mm")

# Each wing face to its element: connected in (x, z) within a slab 12 mm wide; elements ranked by leading edge.
element = np.full(len(x), -1)
for yc in np.arange(outer + 0.006, inner, 0.006):
    m = wing & (np.abs(y - yc) < 0.006)
    idx = np.where(m)[0]
    pts = np.c_[x[idx], z[idx]]
    pr = cKDTree(pts).query_pairs(0.006, output_type="ndarray")
    n, lab = connected_components(sp.coo_matrix((np.ones(len(pr)), (pr[:, 0], pr[:, 1])), shape=(len(idx),) * 2),
                                  directed=False)
    sizes = np.bincount(lab)
    big = [b for b in np.argsort(-sizes)[:4] if sizes[b] > 0.02 * len(idx)]
    if len(big) != 4:
        raise SystemExit(f"slab at y {yc:+.3f}: {len(big)} elements, not 4")
    order = sorted(big, key=lambda b: -x[idx][lab == b].max())
    near = np.abs(y[idx] - yc) < 0.003 + 1e-9
    for k, b in enumerate(order):
        sel = idx[(lab == b) & near]
        element[sel[element[sel] < 0]] = k
left = wing & (element < 0)
print(f"wing faces not assigned: {left.sum()} ({np.abs(F[left, 2]).sum():.2f} N of Fz)")

out = {"total_N": total.round(3).tolist(), "span_m": round(span, 4), "elements": {}, "endplates": {}}
print("\npart        Fz (N)   Fx (N)   share of Fz   Cl on 682 mm x span")
for k, nm in enumerate(NAMES):
    f = F[element == k].sum(0)
    out["elements"][nm] = {"Fz": round(f[2], 3), "Fx": round(f[0], 3), "cl": round(f[2] / (Q * span * CHORD), 4)}
    print(f"{nm:10} {f[2]:8.2f} {f[0]:8.2f}   {100 * f[2] / total[2]:5.1f}%      {f[2] / (Q * span * CHORD):+.3f}")
for nm, m in (("outer endplate", y < outer + 0.001), ("inner endplate", y > inner - 0.001)):
    f = F[m].sum(0)
    out["endplates"][nm] = {"Fz": round(f[2], 3), "Fx": round(f[0], 3)}
    print(f"{nm:14} {f[2]:6.2f} {f[0]:8.2f}   {100 * f[2] / total[2]:5.1f}%")
rest = total - F[element >= 0].sum(0) - F[y < outer + 0.001].sum(0) - F[y > inner - 0.001].sum(0)
print(f"other faces (element tips facing along y, unassigned): Fz {rest[2]:+.2f} Fx {rest[0]:+.2f}")
w = F[wing].sum(0)
print(f"wing between the endplates: Cl {w[2] / (Q * span * CHORD):+.3f}, Cd {-w[0] / (Q * span * CHORD):.3f} on {CHORD} m x span"
      f"; whole part {total[2] / (Q * span * CHORD):+.3f}")
out["cl_wing"] = round(w[2] / (Q * span * CHORD), 4)
out["cl_part"] = round(total[2] / (Q * span * CHORD), 4)

# Spanwise loading in AeroBench's strips, outer end first, with the main's lowest point above the ground.
ground = z.min() - 0.035  # the endplates' bottoms sit 35 mm off the ground
edges = np.linspace(outer, inner, STRIPS + 1)
out["strips"] = []
print("\nstrip (from outer)  y mid (m)  main up (mm)  Cl     main   flap 1 flap 2 flap 3")
for i in range(STRIPS):
    m = wing & (y >= edges[i]) & (y < edges[i + 1])
    width = edges[i + 1] - edges[i]
    cl = F[m, 2].sum() / (Q * width * CHORD)
    per = [F[m & (element == k), 2].sum() / (Q * width * CHORD) for k in range(4)]
    up = (z[m & (element == 0)].min() - ground) * 1000
    out["strips"].append({"y": round((edges[i] + edges[i + 1]) / 2, 4), "main_up_mm": round(up, 1),
                          "cl": round(cl, 4), "cl_elements": [round(c, 4) for c in per]})
    print(f"{i + 1:3}               {(edges[i] + edges[i + 1]) / 2:+.4f}   {up:6.1f}     {cl:+.3f}  "
          + " ".join(f"{c:+.3f}" for c in per))

# Reversed flow: faces whose wall shear runs upstream (+x), as a share of each element's area.
print("\nwall shear against the flow (tau_x > 0), share of each element's wetted area")
out["reversed"] = {}
amag = np.linalg.norm(area, axis=1)
for k, nm in enumerate(NAMES):
    m = element == k
    r = amag[m & (tx > 0)].sum() / amag[m].sum()
    out["reversed"][nm] = round(r, 4)
    print(f"  {nm:8} {100 * r:5.1f}%")
print(f"y+ on the wing: median {np.median(yplus[wing]):.2f}, 95% {np.percentile(yplus[wing], 95):.2f}")
(HERE / "star_wing.json").write_text(json.dumps(out, indent=1))
