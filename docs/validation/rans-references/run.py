"""The estimate's RANS reference cases (validation.RANS_REFERENCES) run again
with the engine's default model and mesh (SST with transition, fine), each
free-air angle restarted from the one before. The old references were SA on
the quick mesh, which reads drag high at these Reynolds numbers.

Run: cd engine && uv run python ../docs/validation/rans-references/run.py <workdir> [case ...]
  case: free | design | ground300 | ground150 | ground60 (default: all)
Results merge into results.json beside this script; the SU2 files go to <workdir>.
"""
import json
import sys
import time
from pathlib import Path

from aeroengine.wing import rans, su2
from aeroengine.wing.airfoils import naca4
from aeroengine.wing.design import layout
from aeroengine.wing.geometry import apply

HERE = Path(__file__).resolve().parent
DESIGN = {"angle_0": 7.2759, "angle_1": 32.0653, "gap_1": 0.0213, "overlap_1": 0.0073}
CASES = {"free": (None, None, [0.0, -3.0, -6.0, -9.0]), "design": (DESIGN, None, [2.0, 0.0]),
         "ground300": (None, 0.30, [0.0]), "ground150": (None, 0.15, [0.0]), "ground60": (None, 0.06, [0.0])}

work = Path(sys.argv[1])
names = sys.argv[2:] or list(CASES)
base = layout([naca4("6212")] * 2, 0.44, True)  # as validation.against_rans builds it
out_f = HERE / "results.json"
for name in names:
    values, height, alphas = CASES[name]
    w = apply(base, values) if values else base
    els = [{"coords": e.placed().tolist(), "unit": e.unit.tolist(), "chord": e.chord, "angle": e.angle,
            "inverted": e.inverted} for e in w.elements]
    p = {"elements": els, "speed": 15.0, "rho": 1.225, "mu": 1.81e-5, "alphas": alphas, "order": "rising",
         "time_limit": 0, "transition": "auto", "n_crit": 9.0}
    if height is not None:
        p["ride_height"] = height
    wd = work / name
    wd.mkdir(parents=True, exist_ok=True)
    t = time.time()
    sw = rans.sweep(p, wd, wd / "wing.su2", None, 12, None, lambda *a: None,
                    lambda msg, level="info": print(f"   [{level}] {msg}", flush=True))
    keep = ("alpha", "cl", "cd", "cm", "converged", "reason", "separated", "separation", "iterations", "seconds",
            "model", "mesh_level", "transition", "elements")
    rows = [{k: r.get(k) for k in keep} for r in sw["rows"]]
    for r in rows:
        print(f"{name}: alpha {r['alpha']:g} cl {r['cl']:.4f} cd {r['cd']:.4f} converged {r['converged']} "
              f"separated {r['separated']} ({r.get('reason') or r.get('separation') or ''})", flush=True)
    out = json.loads(out_f.read_text()) if out_f.exists() else {}
    out[name] = {"ride_height": height, "values": values, "model": su2.DEFAULT_MODEL, "skipped": sw.get("skipped"),
                 "seconds": time.time() - t, "rows": rows}
    out_f.write_text(json.dumps(out, indent=1))
    print(f"{name}: {time.time() - t:.0f} s", flush=True)
