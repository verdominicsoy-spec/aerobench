"""The estimate against every saved RANS result, on the same geometry and
flow: lift, drag and L/D errors, rank correlation, and what the estimate's
own flags (separating, trusted, deflection margin, front element past stall)
said about each case.

Sources:
  jobs   every wing-rans job in Scratch/jobs with a result (exact geometry
         from its params; most are RANS runs of a study's best design)
  check  RANS checks stored in a study export (geometry rebuilt from the study)
  ref    validation.RANS_REFERENCES, the runs the estimate was fitted to
         (in-sample: shown for completeness, not as evidence)

    cd engine && uv run python ../docs/validation/optimiser/rans_vs_estimate.py
Writes rans_vs_estimate.json beside this script. Runs no RANS."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import HERE, STUDIES, flags, jobs, library_units, spearman, study_base  # noqa: E402

from aeroengine.validation import RANS_REFERENCES  # noqa: E402
from aeroengine.wing.airfoils import naca4  # noqa: E402
from aeroengine.wing.design import layout  # noqa: E402
from aeroengine.wing.estimate import estimate  # noqa: E402
from aeroengine.wing.geometry import apply  # noqa: E402


def matches_study(angles):
    """The study trial with these element angles (to 0.01 degree), if any."""
    for f in sorted(STUDIES.glob("*.json")):
        if f.name.endswith((".start.json", ".design.json", ".result.json")):
            continue
        for t in json.loads(f.read_text())["trials"]:
            pl = t.get("placement") or []
            if len(pl) == len(angles) and all(abs(a["angle"] - b) < 0.01 for a, b in zip(pl, angles)):
                return f"{f.stem} #{t['number']}"
    return None


def els_of(wing):
    return [{"coords": e.placed().tolist(), "unit": e.unit.tolist(), "chord": e.chord, "angle": e.angle,
             "inverted": e.inverted} for e in wing.elements]


def row_for(source, name, els, height, p, rans, extra=None):
    r = estimate(els, [float(p.get("alpha", 0.0))], float(p.get("speed", 15)), float(p.get("rho", 1.225)),
                 float(p.get("mu", 1.81e-5)), float(p.get("n_crit", 9.0)), p.get("ref_chord"),
                 ride_height=height)["rows"][0]
    angles = [float(e["angle"]) for e in els]
    out = {"source": source, "name": name, "n": len(els), "angles": [round(a, 2) for a in angles],
           "ride_height": p.get("ride_height"), "mesh": p.get("mesh"), "model": p.get("model"),
           "rans_cl": rans.get("cl"), "rans_cd": rans.get("cd"), "converged": rans.get("converged"),
           "separated": rans.get("separated"), "est_cl": r["cl"], "est_cd": r["cd"], "why": r["why"],
           **flags(r, angles), **(extra or {})}
    if out["rans_cl"] is not None:
        out["cl_err"] = abs(r["cl"]) / abs(out["rans_cl"]) - 1
        out["cd_err"] = r["cd"] / out["rans_cd"] - 1
        out["ld_err"] = (abs(r["cl"]) / r["cd"]) / (abs(out["rans_cl"]) / out["rans_cd"]) - 1
    # "Attached" for scoring: RANS converged and neither its skin friction
    # nor a drag 3x the estimate's (optimise.SEPARATED_DRAG) says separated.
    out["rans_attached"] = bool(out["converged"]) and not out["separated"] and (
        out["rans_cd"] is not None and out["rans_cd"] < 3 * r["cd"])
    return out


def main():
    rows = []
    for jid, p, data in jobs("wing-rans"):
        if data is None:
            continue
        els = [{k: e[k] for k in ("coords", "unit", "chord", "angle", "inverted")} for e in p["elements"]]
        rows.append(row_for("jobs", jid, els, p.get("ride_height"), p, data, {"study_trial": matches_study([e["angle"] for e in p["elements"]])}))

    for f in sorted(STUDIES.glob("*.json")):
        if f.name.endswith((".start.json", ".design.json", ".result.json")):
            continue
        s = json.loads(f.read_text())
        for c in s.get("checks") or []:
            got = study_base(f.stem, s["spec"])
            if got is None:
                continue
            base, p, _ = got
            t = next(t for t in s["trials"] if t["number"] == c["number"])
            keys = [k for v in s["spec"]["variables"] if v["kind"] == "airfoil" for k in v["choices"]]
            lib = library_units(keys) if keys else {}
            numbers, units = {}, {}
            for v in s["spec"]["variables"]:
                n = f"{v['kind']}_{v['element']}"
                if v["kind"] == "airfoil":
                    units[v["element"]] = lib[v["choices"][int(round(t["params"][n]))]]
                elif n in t["params"]:
                    numbers[n] = t["params"][n]
            wing = apply(base, numbers, units)
            rows.append(row_for("check", f"{f.stem} #{c['number']}", els_of(wing), wing.ride_height, {**p, "mesh": s.get("info", {}).get("mesh"),
                                "model": s.get("info", {}).get("model")}, c,
                                {"estimate_at_study_time": t["cl"]}))

    six = layout([naca4("6212")] * 2, 0.44, True)
    for name, alpha, height, values, cl, cd in RANS_REFERENCES:
        w = apply(six, values) if values else six
        rows.append(row_for("ref", name, els_of(w), height, {"alpha": alpha, "speed": 15.0, "ride_height": height, "mesh": "quick",
                                             "model": "sst" if "SST" in name else "sa"},
                            {"cl": cl, "cd": cd, "converged": cl is not None, "separated": None if cl else True}))

    (HERE / "rans_vs_estimate.json").write_text(json.dumps(rows, indent=1, default=float))

    def pct(x):
        return "" if x is None else f"{100 * x:+.0f}%"

    print("| src | case | study trial | n | angles | h | mesh/model | RANS Cl | RANS Cd | RANS state | est Cl | est Cd | "
          "Cl err | Cd err | L/D err | est separating | trusted (min conf) | defl margin | front past stall |")
    print("|" + "---|" * 19)
    for r in rows:
        state = ("attached" if r["rans_attached"] else
                 "separated" if (r["separated"] or (r["converged"] and r["rans_cd"] and r["rans_cd"] >= 3 * r["est_cd"]))
                 else "not converged") if r["rans_cl"] is not None else "never settled"
        if r["rans_cl"] is not None and not r["converged"] and not r["separated"]:
            state = "not converged"
        print(f"| {r['source']} | {r['name']} | {r.get('study_trial') or ''} | {r['n']} | {r['angles']} | "
              f"{'' if r['ride_height'] is None else round(r['ride_height'] * 1000)} | {r['mesh']}/{r['model']} | "
              f"{'' if r['rans_cl'] is None else f'{abs(r['rans_cl']):.3f}'} | "
              f"{'' if r['rans_cd'] is None else f'{r['rans_cd']:.4f}'} | {state} | {abs(r['est_cl']):.3f} | "
              f"{r['est_cd']:.4f} | {pct(r.get('cl_err'))} | {pct(r.get('cd_err'))} | {pct(r.get('ld_err'))} | "
              f"{'yes' if r['separating'] else 'no'} | {'yes' if r['trusted'] else 'no'} ({r['min_confidence']:.2f}) | "
              f"{'' if r['deflection_margin'] is None else f'{r['deflection_margin']:.1f}'} | "
              f"{'' if r['front_past_stall'] is None else f'{r['front_past_stall']:.1f}'} |")

    def stats(sel, label):
        sel = [r for r in sel if r["rans_cl"] is not None]
        if not sel:
            return
        cl = [abs(r["cl_err"]) for r in sel]
        cd = [r["cd_err"] for r in sel]
        print(f"\n{label}: n={len(sel)} |Cl err| mean {100 * np.mean(cl):.1f}% max {100 * np.max(cl):.1f}%; "
              f"Cd err mean {100 * np.mean(cd):+.1f}% range {100 * min(cd):+.0f}..{100 * max(cd):+.0f}%; "
              f"Spearman Cl {spearman([abs(r['est_cl']) for r in sel], [abs(r['rans_cl']) for r in sel])}, "
              f"Cd {spearman([r['est_cd'] for r in sel], [r['rans_cd'] for r in sel])}, "
              f"L/D {spearman([abs(r['est_cl']) / r['est_cd'] for r in sel], [abs(r['rans_cl']) / r['rans_cd'] for r in sel])}")

    out_of_sample = [r for r in rows if r["source"] != "ref" and "92.5" not in str(r["angles"])]
    stats([r for r in out_of_sample if r["rans_attached"]], "out-of-sample, RANS attached and converged")
    stats(out_of_sample, "out-of-sample, every RANS result (last iterate where unconverged)")
    stats([r for r in rows if r["source"] == "ref"], "fit set (validation.RANS_REFERENCES), in-sample")
    sep = [r for r in out_of_sample if not r["rans_attached"]]
    print(f"\nout-of-sample RANS separated/unconverged: {len(sep)}; estimate called separating on "
          f"{sum(r['separating'] for r in sep)}; untrusted on {sum(not r['trusted'] for r in sep)}; "
          f"deflection margin < 2 deg or front element > 9 deg past stall on "
          f"{sum((r['deflection_margin'] is not None and r['deflection_margin'] < 2) or (r['front_past_stall'] or -99) > 9 for r in sep)}")


if __name__ == "__main__":
    main()
