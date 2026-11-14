"""frontwing#1.02's section polars at the heights its strips sit at on the car,
for the spanwise strip model (finite.couple_strips, run_strips.py).

The wing drops 45 mm toward the inner endplate; the main's lowest point is
74.1 mm up inboard, 96.6 mm at mid-span, 119.1 mm outboard (README, STAR's
wings from the CAD). Fully turbulent SST, as car CFD usually runs: on this
wing SST-LM from rest does not converge at these angles. Angles are the
section's own (alpha_effective in car.json): the job's -7.45 deg pitch plus
the induced angle. Writes polars.json after each height.

    AEROBENCH_CORES=10 engine/.venv/bin/python docs/validation/frontwing1/run_polars.py [heights m...]
"""
import json
import os
import sys
import tempfile
from pathlib import Path

from aeroengine.wing import rans

HERE = Path(__file__).parent
ALPHAS = [2.0, 4.0, 6.0, 7.0, 8.0, 8.75, 9.5, 10.5]
heights = [float(h) for h in sys.argv[1:]] or [0.0966, 0.0741, 0.1191]
job = json.loads((HERE / "job.json").read_text())
cores = int(os.environ.get("AEROBENCH_CORES", 12))
log = lambda *a, **k: print(*a, flush=True)  # noqa: E731
out_path = HERE / "polars.json"
for h in heights:
    work = Path(tempfile.mkdtemp())
    p = {**job, "alphas": ALPHAS, "model": "sst", "mesh": "fine", "ride_height": h}
    r = rans.sweep(p, work, work / "wing.su2", None, cores, None, lambda *a: None, log)
    out = json.loads(out_path.read_text()) if out_path.exists() else {}
    out[f"{h:g}"] = [{k: row.get(k) for k in ("alpha", "cl", "cd", "converged", "unsteady", "reason", "separated",
                                               "separation", "regions")} for row in r["rows"]]
    out_path.write_text(json.dumps(out, indent=1))
    log("HEIGHT", h, [(row["alpha"], round(row["cl"], 3), row["converged"]) for row in r["rows"]])
