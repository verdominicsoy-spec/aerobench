"""The engine's RANS (SU2 through aeroengine.wing.rans.sweep, as the app runs
it) on the published cases. Results merge into results_rans.json.

Run: cd engine && uv run python ../docs/validation/published/rans_runs.py <workdir> <case> <mesh> <model> <alpha> [alpha ...]
  case: 30P30N | "NLR 7301 gap 2.6" | "NLR 7301 gap 1.3"; mesh: quick | medium | fine; model: sa | sst | sst-lm
The SU2 files go to <workdir> (large; not committed).
"""
import json
import sys
import time
from pathlib import Path

from aeroengine.wing import rans

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from quick import CASES, MU, RHO  # noqa: E402

work, name, mesh, model = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
alphas = [float(a) for a in sys.argv[5:]]
f, re_, _, _ = CASES[name]
case = json.loads((HERE / f).read_text())
ref = case["ref_chord"]
els = [{k: e[k] for k in ("coords", "unit", "chord", "angle", "inverted")} for e in case["elements"]]
speed = re_ * MU / (RHO * ref)
p = {"elements": els, "speed": speed, "rho": RHO, "mu": MU, "ref_chord": ref, "alphas": alphas, "order": "rising",
     "time_limit": 0, "mesh": mesh, "model": model, "transition": "auto", "n_crit": 9.0,
     "turbulence_intensity": 0.001}
tag = f"{name} | {mesh} | {model}"
wd = work / tag.replace(" | ", "_").replace(" ", "_")
wd.mkdir(parents=True, exist_ok=True)
t = time.time()
sw = rans.sweep(p, wd, wd / "wing.su2", None, 12, None, lambda *a: None,
                lambda msg, level="info": print(f"   [{level}] {msg}", flush=True))
keep = ("alpha", "cl", "cd", "cm", "converged", "reason", "separated", "separation", "iterations", "seconds", "y_plus",
        "elements", "surface", "transition")
rows = [{k: r.get(k) for k in keep} for r in sw["rows"]]
for r in rows:
    print(f"{tag}: alpha {r['alpha']:g} cl {r['cl']:.4f} cd {r['cd']:.4f} converged {r['converged']} "
          f"separated {r['separated']} ({r.get('reason') or r.get('separation') or ''})", flush=True)
mesh_info = sw["rows"][0].get("mesh") if sw["rows"] else None
out_f = HERE / "results_rans.json"
out = json.loads(out_f.read_text()) if out_f.exists() else {}
old = {r["alpha"]: r for r in out.get(tag, {}).get("rows", [])}
old.update({r["alpha"]: r for r in rows})
out[tag] = {"case": name, "mesh": mesh, "model": model, "re": re_, "speed": speed, "mesh_info": mesh_info,
            "skipped": sw.get("skipped"), "seconds": time.time() - t, "rows": [old[a] for a in sorted(old)]}
out_f.write_text(json.dumps(out, indent=1))
print(f"{tag}: {time.time() - t:.0f} s", flush=True)
