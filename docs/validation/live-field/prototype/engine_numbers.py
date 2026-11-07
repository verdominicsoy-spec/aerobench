"""Per saved RANS case: RANS forces, the live estimate and free-air inviscid panel lift, as the app would get them."""
import json, os, glob
import numpy as np
from aeroengine.wing.estimate import estimate
from aeroengine.wing import panel
root = os.path.expanduser("~/Library/Application Support/AeroBench/Scratch/jobs")
out = {}
for f in sorted(glob.glob(root + "/*/field.json")):
    case = os.path.basename(os.path.dirname(f))
    j = json.load(open(os.path.join(root, case, "job.json")))["params"]
    r = json.load(open(os.path.join(root, case, "result.json")))["data"]
    els = [{k: e[k] for k in ("coords", "unit", "chord", "angle", "inverted")} for e in j["elements"]]
    row = {"case": case, "n": len(els), "mesh": j["mesh"], "model": j.get("model"), "ride": j.get("ride_height"),
           "speed": j["speed"], "ref": j["ref_chord"], "converged": r.get("converged"), "separated": r.get("separated"),
           "rans": {"cl": r["cl"], "cd": r["cd"], "el_cl": [e["cl"] for e in r["elements"]], "el_cd": [e["cd"] for e in r["elements"]]}}
    try:
        e = estimate(els, [float(j.get("alpha", 0))], j["speed"], rho=j["rho"], mu=j["mu"], ref_chord=j["ref_chord"],
                     ride_height=j.get("ride_height"))["rows"][0]
        row["est"] = {"cl": e["cl"], "cd": e["cd"], "el_cl": [x["cl"] for x in e["elements"]],
                      "cd_own": [x["cd_own"] for x in e["elements"]], "why": e.get("why") or e.get("reason")}
    except Exception as ex:
        row["est"] = {"error": str(ex)}
    s = panel.solve([np.asarray(e["coords"], float) for e in els], float(j.get("alpha", 0)), ref_chord=j["ref_chord"])
    row["inviscid_free"] = {"cl": float(s.cl_total) if hasattr(s, "cl_total") else float(sum(s.cl)), "el_cl": [float(c) for c in s.cl]}
    out[case] = row
json.dump(out, open(os.environ["OUT"], "w"), indent=1)
for c, r in out.items():
    e = r["est"]
    print(c, r["n"], "conv" if r["converged"] else "NOCONV", "ride", r["ride"], "| RANS cl %.3f cd %.4f" % (r["rans"]["cl"], r["rans"]["cd"]),
          "| est cl %.3f cd %.4f" % (e.get("cl", float("nan")), e.get("cd", float("nan"))), "| inv cl %.3f" % r["inviscid_free"]["cl"],
          "| cd_own", [round(x, 4) for x in e.get("cd_own", [])])
