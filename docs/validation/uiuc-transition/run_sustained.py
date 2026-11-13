"""The ten UIUC benchmark sections again with transition RANS after the 13 Nov 2026
fixes (sustained freestream turbulence, suction surfaces fine to the trailing edge),
in the same form as sst_lm_quick.json / sst_lm_fine.json so the two compare.

    cd engine && .venv/bin/python ../docs/validation/uiuc-transition/run_sustained.py <workdir> <mesh> <tu> [section ...]

Writes sst_lm_<mesh>_sustained.json beside this script, one section at a time.
"""
import json
import sys
import time
from pathlib import Path

from aeroengine import validation

HERE = Path(__file__).resolve().parent
work, mesh, tu = Path(sys.argv[1]), sys.argv[2], float(sys.argv[3])
only = set(sys.argv[4:])
out_f = HERE / f"sst_lm_{mesh}_sustained.json"
out = json.loads(out_f.read_text()) if out_f.exists() else {}
settings = {"mesh": mesh, "model": "sst-lm", "turbulence_intensity": tu}
for case in validation.benchmark_cases():
    if (only and case.key not in only) or case.key in out:
        continue
    t0 = time.time()
    err = None
    try:
        rows = validation._sweep(case, work, 12, None, settings)
    except Exception as exc:  # one section's failure must not sink the others
        rows, err = [], str(exc)
    out[case.key] = {"rows": [list(r) for r in rows], "err": err,
                     "errors": validation.errors(case, *validation.rans_at_tunnel(case, rows)),
                     "planned": len(validation.rans_alphas(case)), "seconds": time.time() - t0, "tu": tu}
    out_f.write_text(json.dumps(out, indent=1))
    e = out[case.key]["errors"]
    print(case.key, "lift", round(e["lift"] or 0, 3), "drag", round(e["drag"] or 0, 3), flush=True)
