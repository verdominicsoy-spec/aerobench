"""Zerihan's single-element wing in ground effect (Tyrrell 026 front-wing main, 80% scale) against
AeroBench's RANS: 2D at the full angle, and as on the car (rans.solve_finite, span and endplates).

Source: J. Zerihan, "An Investigation into the Aerodynamics of Wings in Ground Effect", PhD thesis,
University of Southampton, 2001 (eprints.soton.ac.uk/426058). Geometry: Table 2 (coordinates at the
reference incidence, 1 deg quoted = 3.45 deg true). Measured: Table 15 (sectional Cl at the wing
centre from the chordwise pressures, which the author calls an estimate: 45 tappings), Table 9 (where
the boundary layer detaches on the suction surface, oil flow at the semispan). Transition free,
30 m/s, Re 0.43-0.46e6 on the 223.4 mm chord, span 1100 mm (AR 4.92), endplates 250 x 100 mm,
moving belt, freestream turbulence 0.2%. Height h: ground to the wing's lowest point.

    cd engine && .venv/bin/python ../docs/validation/ground-3d/run.py <cores> [h/c ...]   (h/c: free, 0.448, ...)
Results merge into results.json beside this script.
"""
import json
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "published"))
from build import selig, to_element  # noqa: E402  the published cases' geometry path

from aeroengine.wing import rans  # noqa: E402

HERE = Path(__file__).resolve().parent
CHORD, SPAN, ENDPLATE, SPEED, RHO, MU, TU = 0.2234, 1.1, 0.100, 30.0, 1.2, 1.8e-5, 0.002
# Figure 9b (chapter 4, transition free, 1 deg), digitised to about +-0.01: sectional Cl at the wing centre
# from the chordwise pressures, and the whole wing's CL from the balance (downforce positive). Table 15 (the
# CFD chapter's "experimental" column) matches the first at h/c 0.671 but reads lower nearer the ground
# (1.385 against 1.684 at 0.134), and the author calls it an estimate; the figure is the chapter 4 data.
CL_CENTRE = {0.671: 0.903, 0.448: 1.026, 0.313: 1.186, 0.224: 1.395, 0.179: 1.540, 0.134: 1.684, 0.112: 1.730,
             0.090: 1.759, 0.067: 1.765}
CL_WING = {0.671: 0.835, 0.448: 0.941, 0.313: 1.083, 0.224: 1.269, 0.179: 1.418, 0.134: 1.612, 0.112: 1.690,
           0.090: 1.72, 0.067: 1.71}
# Freestream (h/c 3.36): Table 15's pressure estimate only.
CL_CENTRE_FREE_TABLE15 = 0.766
# Table 9: x/c where the suction-surface boundary layer detaches (oil flow, semispan).
X_SEP = {0.224: 0.99, 0.179: 0.96, 0.134: 0.91, 0.112: 0.87, 0.090: 0.80, 0.082: 0.78, 0.076: 0.75, 0.067: 0.71}
# Table 2 (x/c, y/c): suction surface (y < 0, faces the ground) and pressure surface, leading edge to trailing edge.
SUCTION = [(0, 0), (.0010, -.0076), (.0020, -.0107), (.0049, -.0168), (.0099, -.0228), (.0149, -.0266), (.0199, -.0294),
           (.0249, -.0320), (.0298, -.0345), (.0348, -.0369), (.0398, -.0393), (.0448, -.0416), (.0498, -.0438),
           (.0548, -.0460), (.0598, -.0481), (.0698, -.0520), (.0797, -.0557), (.0897, -.0591), (.0997, -.0622),
           (.1197, -.0676), (.1396, -.0718), (.1596, -.0750), (.1796, -.0769), (.1996, -.0778), (.2496, -.0762),
           (.2996, -.0732), (.3496, -.0692), (.3996, -.0645), (.4496, -.0590), (.4996, -.0526), (.5497, -.0454),
           (.5997, -.0373), (.6497, -.0285), (.6997, -.0188), (.7498, -.0083), (.7998, .0031), (.8498, .0152),
           (.8999, .0282), (.9199, .0336), (.9399, .0392), (.9599, .0449), (.9799, .0507), (.9900, .0537), (1.0, .0567)]
PRESSURE = [(0, 0), (.0010, .0079), (.0020, .0109), (.0051, .0173), (.0101, .0232), (.0151, .0271), (.0201, .0300),
            (.0251, .0313), (.0301, .0322), (.0351, .0330), (.0401, .0338), (.0451, .0346), (.0501, .0354), (.0551, .0361),
            (.0601, .0369), (.0701, .0382), (.0801, .0395), (.0902, .0407), (.1002, .0417), (.1202, .0436), (.1402, .0451),
            (.1602, .0463), (.1802, .0472), (.2002, .0480), (.2501, .0498), (.3001, .0515), (.3501, .0527), (.4001, .0534),
            (.4501, .0537), (.5001, .0535), (.5501, .0529), (.6001, .0518), (.6500, .0503), (.7000, .0482), (.7500, .0456),
            (.8000, .0438), (.8500, .0443), (.9000, .0479), (.9200, .0502), (.9400, .0530), (.9600, .0562), (.9800, .0599),
            (.9900, .0619), (1.0, .0640)]


def element() -> dict:
    # Selig order: upper (pressure) trailing edge, round the nose, lower (suction) trailing edge; no base.
    loop = np.array(PRESSURE[::-1] + SUCTION[1:], float) * CHORD
    el = to_element(selig(loop), "T026 main")
    return {k: el[k] for k in ("coords", "unit", "chord", "angle", "inverted")}


def run(case, cores: int, done: dict | None = None) -> dict:
    ride = None if case == "free" else float(case) * CHORD
    base = {"elements": [element()], "speed": SPEED, "rho": RHO, "mu": MU, "alpha": 0.0, "ref_chord": CHORD,
            "model": "sst-lm", "mesh": "fine", "transition": "auto", "n_crit": 9.0, "turbulence_intensity": TU,
            "ride_height": ride}
    log = lambda *a, **k: print(f"[{case}]", *a, flush=True)
    out = {k: v for k, v in (done or {}).items() if k == "two_d"}  # a 2D answer already run is kept
    for name, p in (("two_d", base), ("on_car", {**base, "finite": {"span": SPAN, "endplate": ENDPLATE}})):
        if name in out:
            continue
        work = Path(tempfile.mkdtemp())
        fn = rans.solve_finite if "finite" in p else rans.solve
        r = fn(p, work, work / "wing.su2", None, cores, None, lambda *a: None, log, field=False)
        sep = [q for q in r.get("regions") or [] if q["surface"] == "lower" and q["kind"] in
               ("trailing-edge separation", "leading-edge stall")]
        out[name] = {"cl": -r["cl"], "cd": r["cd"], "converged": r["converged"], "reason": r.get("reason"),
                     "x_sep": min((q["start"] for q in sep), default=None), "regions": r.get("regions"),
                     "finite": r.get("finite"), "tu_at_wing": r.get("tu_at_wing")}
        log(name, "Cl", round(-r["cl"], 3), "x_sep", out[name]["x_sep"], "converged", r["converged"])
    return out


if __name__ == "__main__":
    cores = int(sys.argv[1])
    cases = [c if c == "free" else float(c) for c in sys.argv[2:]] or ["free", 0.448, 0.224, 0.134, 0.090, 0.067]
    f = HERE / "results.json"
    res = json.loads(f.read_text()) if f.exists() else {}
    for c in cases:
        res[str(c)] = {**run(c, cores, res.get(str(c))), "measured": {"cl_centre": CL_CENTRE.get(c), "cl_wing": CL_WING.get(c),
                                                     "x_sep": X_SEP.get(c)}}
        f.write_text(json.dumps(res, indent=1))
