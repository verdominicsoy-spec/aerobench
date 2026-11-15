"""frontwing#1 as on the car (rans.solve_finite, then rans.bracket): endplate,
ride height, span (default 1 m, the project's), wing angle (default the
job's 0) and the endplates' lower edge over the ground (default level with
the wing) as given. Writes car.json.

    engine/.venv/bin/python docs/validation/frontwing1/run_car.py <endplate m> [<ride height m> [<span m> [<alpha deg> [<endplate bottom m> [<model>]]]]]

frontwing#1.02 as STAR ran it: run_car.py 0.315 0.0966 0.5245 -7.45 0.035 sst (see README). model defaults to
sst-lm, then rans.bracket checks it against the other; with sst the run is the fully turbulent one alone.
"""
import json
import sys
import tempfile
from pathlib import Path

from aeroengine.wing import rans

HERE = Path(__file__).parent
endplate = float(sys.argv[1])
ride = float(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] != "free" else None
span = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
job = json.loads((HERE / "job.json").read_text())
alpha = float(sys.argv[4]) if len(sys.argv) > 4 else job["alpha"]
bottom = float(sys.argv[5]) if len(sys.argv) > 5 else None
model = sys.argv[6] if len(sys.argv) > 6 else "sst-lm"
p = {**job, "alpha": alpha, "model": model, "mesh": "fine", "ride_height": ride,
     "finite": {"span": span, "endplate": endplate, "endplate_bottom": bottom}}
work = Path(tempfile.mkdtemp())
log = lambda *a, **k: print(*a, flush=True)
cores = int(__import__("os").environ.get("AEROBENCH_CORES", 12))
r = rans.solve_finite(p, work, work / "wing.su2", None, cores, None, lambda *a: None, log, field=False)
if model == "sst-lm":
    r = rans.bracket(p, r, work, work / "wing.su2", None, cores, None, lambda *a: None, log)
key = f"endplate {endplate:g} m, " + (f"ride height {ride:g} m" if ride else "free air")
if span != 1.0 or alpha != job["alpha"]:
    key += f", span {span:g} m, alpha {alpha:g} deg"
if bottom is not None:
    key += f", endplate bottom {bottom:g} m, vortex lattice"
if model != "sst-lm":
    key += f", {model}, each element at its own induced angle"
out_path = HERE / "car.json"
out = json.loads(out_path.read_text()) if out_path.exists() else {}
out[key] = {k: r.get(k) for k in ("cl", "cd", "converged", "separated", "separation", "regions", "finite", "bracket",
                                   "transition_decides", "tu_at_wing")}
out[key]["elements"] = [round(e["cl"], 4) for e in r["elements"]]
out_path.write_text(json.dumps(out, indent=1))
print("RESULT", key, round(r["cl"], 4), round(r["cd"], 5), r["separation"], out[key]["elements"], r["finite"], flush=True)
