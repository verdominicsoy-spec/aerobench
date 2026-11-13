"""frontwing#1 (the user's 4-element front wing, 12 Nov 2026) through rans.solve:
free air, 0 deg, fine mesh, SST-LM and fully turbulent SST. Writes results.json.

    engine/.venv/bin/python docs/validation/frontwing1/run.py [model ...]
"""
import json
import sys
import tempfile
from pathlib import Path

from aeroengine.wing import rans

HERE = Path(__file__).parent
job = json.loads((HERE / "job.json").read_text())
out_path = HERE / "results.json"
results = json.loads(out_path.read_text()) if out_path.exists() else {}
for model in sys.argv[1:] or ["sst-lm", "sst"]:
    p = {**job, "model": model, "mesh": "fine"}
    work = Path(tempfile.mkdtemp())
    r = rans.solve(p, work, work / "wing.su2", None, 12, None, lambda *a: None, lambda *a, **k: print(*a), field=False)
    results[model] = {k: r.get(k) for k in ("cl", "cd", "converged", "reason", "separated", "separation", "regions",
                                            "tu_at_wing", "rans_version", "residual_drop")}
    results[model]["elements"] = [round(e["cl"], 4) for e in r["elements"]]
    results[model]["cells"] = r["mesh"]["cells"]
    out_path.write_text(json.dumps(results, indent=1))
    print(model, results[model]["cl"], results[model]["cd"], results[model]["separation"])
