"""frontwing#1 as on the car (rans.solve_finite, then rans.bracket): span 1 m (the
project's), endplate and ride height as given (STAR's not known yet). Writes car.json.

    engine/.venv/bin/python docs/validation/frontwing1/run_car.py <endplate m> [<ride height m>]
"""
import json
import sys
import tempfile
from pathlib import Path

from aeroengine.wing import rans

HERE = Path(__file__).parent
endplate = float(sys.argv[1])
ride = float(sys.argv[2]) if len(sys.argv) > 2 else None
p = {**json.loads((HERE / "job.json").read_text()), "model": "sst-lm", "mesh": "fine", "ride_height": ride,
     "finite": {"span": 1.0, "endplate": endplate}}
work = Path(tempfile.mkdtemp())
log = lambda *a, **k: print(*a, flush=True)
r = rans.solve_finite(p, work, work / "wing.su2", None, 12, None, lambda *a: None, log, field=False)
r = rans.bracket(p, r, work, work / "wing.su2", None, 12, None, lambda *a: None, log)
key = f"endplate {endplate:g} m, " + (f"ride height {ride:g} m" if ride else "free air")
out_path = HERE / "car.json"
out = json.loads(out_path.read_text()) if out_path.exists() else {}
out[key] = {k: r.get(k) for k in ("cl", "cd", "converged", "separated", "separation", "regions", "finite", "bracket",
                                   "transition_decides", "tu_at_wing")}
out[key]["elements"] = [round(e["cl"], 4) for e in r["elements"]]
out_path.write_text(json.dumps(out, indent=1))
print("RESULT", key, round(r["cl"], 4), round(r["cd"], 5), r["separation"], "| SST:", r["bracket"]["sst"]["separation"], flush=True)
