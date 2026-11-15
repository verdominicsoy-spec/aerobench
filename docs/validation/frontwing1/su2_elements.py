"""Each element's share of a 2D SU2 solve's lift, from its surface.csv (pressure only),
for the polars of run_polars.py: to set beside STAR's element forces (star_wing.py).

    engine/.venv/bin/python docs/validation/frontwing1/su2_elements.py <sweep folder>...

A sweep folder holds one a<angle>/ per solve. SU2's frame here has the flow along +x
and the wing's lift along y; Cl is on the 682 mm sum of the chords, as SU2 reports it.
"""
import sys
from pathlib import Path

import numpy as np
import scipy.sparse as sp
from scipy.sparse.csgraph import connected_components
from scipy.spatial import cKDTree

CHORD = 0.682


def elements(pts: np.ndarray) -> list[np.ndarray]:
    """Point indices of each element (connected within 4 mm), leading element first."""
    pr = cKDTree(pts).query_pairs(0.004, output_type="ndarray")
    _, lab = connected_components(sp.coo_matrix((np.ones(len(pr)), (pr[:, 0], pr[:, 1])), shape=(len(pts),) * 2),
                                  directed=False)
    sizes = np.bincount(lab)
    big = [b for b in np.argsort(-sizes) if sizes[b] > 0.03 * len(pts)]
    return [np.where(lab == b)[0] for b in sorted(big, key=lambda b: pts[lab == b, 0].min())]


def around(p: np.ndarray) -> np.ndarray:
    """The points in order around the outline, by walking to the nearest unvisited one."""
    tree, used, i = cKDTree(p), np.zeros(len(p), bool), int(np.argmax(p[:, 0]))
    order, used[i] = [i], True
    for _ in range(len(p) - 1):
        nxt = [k for k in tree.query(p[i], k=min(12, len(p)))[1] if not used[k]]
        if not nxt:
            break
        i = nxt[0]
        used[i] = True
        order.append(i)
    return np.array(order)


def lift(p: np.ndarray, cp: np.ndarray) -> float:
    """Lift (y force per unit q) of a closed outline: minus Cp times the outward normal."""
    o = around(p)
    a, c = p[o], cp[o]
    b, c2 = np.roll(a, -1, 0), np.roll(c, -1)
    turn = 1.0 if np.sum(a[:, 0] * b[:, 1] - b[:, 0] * a[:, 1]) > 0 else -1.0
    return float(np.sum(-(c + c2) / 2 * (-turn * (b[:, 0] - a[:, 0]))))


for folder in sys.argv[1:]:
    print(folder)
    for run in sorted(Path(folder).glob("a*"), key=lambda q: float(q.name[1:])):
        z = np.genfromtxt(run / "surface.csv", delimiter=",", skip_header=1)
        pts, cp = z[:, 1:3], 2 * z[:, 3]  # SU2 8.5's pressure is non-dimensional by rho V^2 (rans.surface_cp)
        cl = [lift(pts[i], cp[i]) / CHORD for i in elements(pts)]
        print(f"  {run.name[1:]:>5} deg: Cl {sum(cl):+.3f}, elements " + " ".join(f"{c:+.3f}" for c in cl))
