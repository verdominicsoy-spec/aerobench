"""Cut three saved RANS runs down to test fixtures for LiveFieldValidationTests.

Run from engine/: uv run python -I ../docs/validation/live-field/make_fixtures.py
Each case folder gets field.json/field.bin (WingField's format, every third cell in x and y, only cp
and cp0), and case.json: the elements, the RANS forces and surface Cp, and the live estimate's per-element
lift and drag as the app would get them.
"""
import json
import os
import sys

import numpy as np
from aeroengine.wing.estimate import estimate

CASES = ["20261106-171046-1b32", "20261104-173556-baec", "20261106-120151-c003"]
KEEP = ("cp", "cp0")  # no metric reads speed; dropping it keeps each case under 400 kB
STEP = 3  # keep every third cell: about 7 mm, against the app's 4 mm live grid
JOBS = os.path.expanduser("~/Library/Application Support/AeroBench/Scratch/jobs")
OUT = os.path.dirname(os.path.abspath(sys.argv[0]))


def thin(line, every):
    """Every `every`-th point, always keeping the last, so a line keeps its ends."""
    kept = line[::every]
    return kept if kept[-1] == line[-1] else kept + [line[-1]]


def fixture(case):
    src = os.path.join(JOBS, case)
    job = json.load(open(os.path.join(src, "job.json")))["params"]
    res = json.load(open(os.path.join(src, "result.json")))["data"]
    head = json.load(open(os.path.join(src, "field.json")))
    nx, ny = head["nx"], head["ny"]
    keys = [s["key"] for s in head["scalars"]]
    blocks = np.fromfile(os.path.join(src, "field.bin"), dtype="<f4").reshape(len(keys), ny, nx)
    # New cell k covers old cells 3k..3k+2 and takes the middle one's value.
    mx, my = nx // STEP, ny // STEP
    x0, y0, x1, y1 = head["window"]
    dx, dy = (x1 - x0) / nx, (y1 - y0) / ny
    sub = blocks[:, 1::STEP, 1::STEP][:, :my, :mx]
    keep = [keys.index(k) for k in KEEP]
    out = os.path.join(OUT, case)
    os.makedirs(out, exist_ok=True)
    np.ascontiguousarray(sub[keep], dtype="<f4").tofile(os.path.join(out, "field.bin"))
    head = {
        "nx": mx, "ny": my, "window": [x0, y0, x0 + STEP * mx * dx, y0 + STEP * my * dy], "v_inf": head.get("v_inf"),
        "scalars": [{**head["scalars"][i], "colormap": []} for i in keep],
        "streamlines": [thin(s, 3) for s in head["streamlines"]],
        "outlines": head.get("outlines") or [],
    }
    json.dump(head, open(os.path.join(out, "field.json"), "w"), separators=(",", ":"))

    els = [{k: e[k] for k in ("coords", "unit", "chord", "angle", "inverted")} for e in job["elements"]]
    alpha = float(job.get("alpha", 0))
    row = estimate(els, [alpha], job["speed"], rho=job["rho"], mu=job["mu"], ref_chord=job["ref_chord"],
                   ride_height=job.get("ride_height"))["rows"][0]
    r5 = lambda v: [round(float(a), 5) for a in v]
    case_json = {
        "elements": [[[round(x, 6), round(y, 6)] for x, y in e["coords"]] for e in job["elements"]],
        "alpha": alpha, "ride_height": job.get("ride_height"), "ref_chord": job["ref_chord"],
        "rans": {"cl": res["cl"], "cd": res["cd"],
                 "surface": [{"x": r5(s["x"][::2]), "y": r5(s["y"][::2]), "cp": r5(s["cp"][::2])} for s in res["surface"]]},
        "estimate": {"el_cl": [e["cl"] for e in row["elements"]], "cd_own": [e["cd_own"] for e in row["elements"]],
                     "cl": row["cl"], "cd": row["cd"]},
    }
    json.dump(case_json, open(os.path.join(out, "case.json"), "w"), separators=(",", ":"))
    print(case, f"{mx}x{my}", "est cl %.3f" % row["cl"], "RANS cl %.3f" % res["cl"])


for c in CASES:
    fixture(c)
