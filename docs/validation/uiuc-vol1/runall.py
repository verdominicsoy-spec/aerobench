"""The app's solvers on the five UIUC sections at the tunnel's Reynolds numbers."""
import json, math, sqlite3, sys, time
from pathlib import Path
import numpy as np
from aeroengine.wing import rans
from aeroengine.wing.airfoils import naca4
from aeroengine.wing.viscous import polar

S = Path(sys.argv[1]); out = S / "results.json"
tunnel = json.loads((S / "tunnel.json").read_text())
db = sqlite3.connect("/Users/warthog/aerobench/data/airfoils/index.sqlite")
def coords(name):
    if name == "NACA 6409":
        return np.asarray(naca4("6409"), float)
    key = {"E387": "uiuc/e387", "FX 63-137": "uiuc/fx63137", "S1210": "uiuc/s1210", "S1223": "uiuc/s1223"}[name]
    return np.asarray(json.loads(db.execute("select coords from airfoils where key=?", (key,)).fetchone()[0]), float)
pick = {"E387": [213], "FX 63-137": [154], "NACA 6409": [191], "S1210": [131], "S1223": [136, 588]}
rho, mu, chord = 1.225, 1.81e-5, 0.30
results = json.loads(out.read_text()) if out.exists() else {}
for name, runs in pick.items():
    if name in results and results[name].get("rans"):
        continue
    rows = sorted(r for run in tunnel[name] if run["run"] in runs for r in run["rows"])
    re_ = float(np.mean([run["re"] for run in tunnel[name] if run["run"] in runs]))
    unit = coords(name)
    a_t = [r[0] for r in rows]
    nf = polar(unit, a_t, re_, 9.0, False)["rows"]
    speed = re_ * mu / (rho * chord)
    alphas = list(np.arange(math.ceil(min(a_t) / 2) * 2, math.floor(max(a_t) / 2) * 2 + 0.1, 2.0))
    el = {"coords": (unit * chord).tolist(), "unit": unit.tolist(), "chord": chord, "angle": 0.0, "inverted": False}
    p = {"elements": [el], "speed": speed, "rho": rho, "mu": mu, "alphas": alphas, "order": "rising", "time_limit": 0,
         "mesh": "fine", "model": "sst-lm", "transition": "auto", "n_crit": 9.0, "turbulence_intensity": 0.001}
    wd = S / "runs" / name.replace(" ", "_"); wd.mkdir(parents=True, exist_ok=True)
    t = time.time()
    sw = rans.sweep(p, wd, wd / "wing.su2", None, 12, None, lambda *a: None, lambda *a, **k: None)
    results[name] = {"re": re_, "speed": speed, "chord": chord, "tunnel": rows,
                     "neuralfoil": [[r["alpha"], r["cl"], r["cd"], r.get("cm"), r.get("trusted")] for r in nf],
                     "rans": [[r.get("alpha"), r["cl"], r["cd"], r.get("converged"), r.get("separated"), r.get("reason") or r.get("separation")]
                              for r in sw["rows"]], "skipped": sw.get("skipped"), "seconds": time.time() - t}
    out.write_text(json.dumps(results, indent=1))
    print(name, f"{time.time() - t:.0f} s", [(r[0], round(r[1], 3), r[3]) for r in results[name]["rans"]], flush=True)
