"""The live estimate and the inviscid panel method on the published cases,
at the published angles and a sweep around them. Writes results_quick.json.

Run: cd engine && uv run python ../docs/validation/published/quick.py
"""
import json
from pathlib import Path

import numpy as np
from aeroengine.wing import panel
from aeroengine.wing.estimate import estimate

HERE = Path(__file__).resolve().parent
RHO, MU = 1.225, 1.81e-5  # the app's sea-level air; only the Reynolds number matters here

CASES = {  # file, Reynolds number on the reference (stowed / cruise) chord, published angles, sweep
    "30P30N": ("data/30p30n/elements.json", 9.0e6, [8.10, 16.21, 21.34, 23.28], np.arange(0.0, 28.1, 1.0)),
    "NLR 7301 gap 2.6": ("data/nlr7301/elements_gap26.json", 2.51e6, [13.1], np.arange(0.0, 22.1, 1.0)),
    "NLR 7301 gap 1.3": ("data/nlr7301/elements_gap13.json", 2.51e6, [6.0], np.arange(0.0, 22.1, 1.0)),
}


def run(name):
    f, re_, pub, sweep = CASES[name]
    case = json.loads((HERE / f).read_text())
    ref = case["ref_chord"]
    els = [{k: e[k] for k in ("coords", "unit", "chord", "angle", "inverted")} for e in case["elements"]]
    speed = re_ * MU / (RHO * ref)
    alphas = sorted(set([float(a) for a in pub] + [float(a) for a in sweep]))
    est = estimate(els, alphas, speed, rho=RHO, mu=MU, ref_chord=ref, ride_height=None)
    solver = panel.Solver([np.asarray(e["coords"], float) for e in els], ref)
    rows = []
    for a, r in zip(alphas, est["rows"]):
        s = solver.solve(a)
        rows.append({"alpha": a, "published": a in pub,
                     "est": {"cl": r["cl"], "cd": r["cd"], "separating": r["separating"], "why": r["why"],
                             "trusted": r["trusted"],
                             "el_cl": [x["cl"] for x in r["elements"]], "el_cd": [x["cd"] for x in r["elements"]],
                             "el_eff": [x["effective_angle"] for x in r["elements"]],
                             "el_stall": [x["stall_angle"] for x in r["elements"]],
                             "el_conf": [x["confidence"] for x in r["elements"]]},
                     "panel": {"cl": s.cl_total, "el_cl": list(s.cl), "cm": s.cm_total,
                               "cp": [c.tolist() for c in s.cp] if a in pub else None}})
    return {"re": re_, "speed": speed, "ref_chord": ref, "element_re": est["re"],
            "names": [e["name"] for e in case["elements"]], "rows": rows}


if __name__ == "__main__":
    out = {n: run(n) for n in CASES}
    (HERE / "results_quick.json").write_text(json.dumps(out, indent=1))
    for n, c in out.items():
        print(n, "element Re", [f"{r:.3g}" for r in c["element_re"]])
        for r in c["rows"]:
            e, p = r["est"], r["panel"]
            print(f"  {'*' if r['published'] else ' '} a {r['alpha']:6.2f}  est cl {e['cl']:.3f} cd {e['cd']:.4f} "
                  f"el {[round(x, 3) for x in e['el_cl']]} eff {[round(x, 1) for x in e['el_eff']]} | panel cl {p['cl']:.3f} "
                  f"el {[round(x, 3) for x in p['el_cl']]} {'SEP: ' + e['why'][:90] if e['separating'] else ''}")
