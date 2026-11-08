"""Where the owner's saved estimate studies ended up.

For each study export in Scratch/wing/studies, the best few distinct
feasible designs (as optimise.check picks them) are rebuilt from the study's
job, run through the estimate exactly as the trial was, and checked: does
the rebuild reproduce the stored Cl, which variables sit on a bound, how
close the design is to the 25-degree deflection cliff, how far a front
element sits past its own stall angle, and whether NeuralFoil trusted it.

    cd engine && uv run python ../docs/validation/optimiser/saved_studies.py
Writes saved_studies.json beside this script."""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import HERE, STUDIES, flags, library_units, study_base, trial_row  # noqa: E402

from aeroengine.wing.geometry import apply, reshape  # noqa: E402,F401
from aeroengine.wing.optimise import DISTINCT  # noqa: E402

TOP = 5


def distinct(trials, variables, direction):
    spans = {f"{v['kind']}_{v['element']}": v["high"] - v["low"] for v in variables}
    good = sorted((t for t in trials if t["state"] == "complete" and t.get("feasible")),
                  key=lambda t: t["value"], reverse=direction == "maximize")
    picked = []
    for t in good:
        if all(any(abs(t["params"][k] - p["params"].get(k, t["params"][k])) >= DISTINCT * spans.get(k, 0.0)
                   for k in t["params"] if spans.get(k)) for p in picked):
            picked.append(t)
        if len(picked) == TOP:
            break
    return picked


def at_bounds(params, variables):
    out = []
    for v in variables:
        name = f"{v['kind']}_{v['element']}"
        if v["kind"] == "airfoil" or name not in params:
            continue
        r = v["high"] - v["low"]
        x = params[name]
        if x - v["low"] <= 0.01 * r:
            out.append(f"{name}=low")
        elif v["high"] - x <= 0.01 * r:
            out.append(f"{name}=high")
    return out


def main():
    report = []
    for f in sorted(STUDIES.glob("*.json")):
        if f.name.endswith((".start.json", ".design.json", ".result.json")):
            continue
        s = json.loads(f.read_text())
        name = f.stem
        spec = s["spec"]
        got = study_base(name, spec)
        states = {}
        for t in s["trials"]:
            states[t["state"]] = states.get(t["state"], 0) + 1
        entry = {"study": name, "objective": spec["objective"], "trials": len(s["trials"]), "states": states,
                 "variables": [f"{v['kind']}_{v['element']}" for v in spec["variables"]], "designs": []}
        if got is None:
            entry["note"] = "no finished job found for this study file and objective"
            report.append(entry)
            continue
        base, p, jid = got
        entry["job"] = jid
        keys = [k for v in spec["variables"] if v["kind"] == "airfoil" for k in v["choices"]]
        lib = library_units(keys) if keys else {}
        for t in distinct(s["trials"], spec["variables"], s["direction"]):
            numbers, units = {}, {}
            for v in spec["variables"]:
                n = f"{v['kind']}_{v['element']}"
                if n not in t["params"]:
                    continue
                if v["kind"] == "airfoil":
                    units[v["element"]] = lib[v["choices"][int(round(t["params"][n]))]]
                else:
                    numbers[n] = float(t["params"][n])
            if s.get("base_sections"):  # shape studies reshape the study's starting sections
                for i, u in enumerate(s["base_sections"]):
                    units.setdefault(i, u)
            import numpy as np

            units = {i: np.asarray(u, float) for i, u in units.items()}
            wing = apply(base, numbers, units)
            row = trial_row(wing, p)
            fl = flags(row, [e.angle for e in wing.elements])
            entry["designs"].append({
                "number": t["number"], "value": t["value"], "cl_stored": t["cl"], "cd_stored": t["cd"],
                "cl_rebuilt": row["cl"], "cd_rebuilt": row["cd"],
                "reproduced": abs(row["cl"] - t["cl"]) < 1e-3 * max(1.0, abs(t["cl"])),
                "angles": [round(e.angle, 2) for e in wing.elements], "ride_height": wing.ride_height,
                "airfoils": t.get("airfoils"), "at_bounds": at_bounds(t["params"], spec["variables"]),
                "cl_cd": abs(row["cl"]) / row["cd"], **fl,
                "why_untrusted": [i for i, e in enumerate(row["elements"]) if not e["trusted"]],
            })
        report.append(entry)
    (HERE / "saved_studies.json").write_text(json.dumps(report, indent=1, default=float))
    for e in report:
        print(f"\n{e['study']} {e['objective']} trials={e['trials']} {e['states']} {e.get('note', '')}")
        for d in e["designs"]:
            print(f"  #{d['number']:<5} value={d['value']:.4g} Cl={d['cl_rebuilt']:.3f} Cd={d['cd_rebuilt']:.4f} "
                  f"L/D={d['cl_cd']:.0f} repro={d['reproduced']} angles={d['angles']} "
                  f"defl_margin={d['deflection_margin'] if d['deflection_margin'] is None else round(d['deflection_margin'], 2)} "
                  f"front_past_stall={d['front_past_stall'] if d['front_past_stall'] is None else round(d['front_past_stall'], 1)} "
                  f"trusted={d['trusted']} minconf={d['min_confidence']:.2f} h={d['ride_height']} "
                  f"bounds={d['at_bounds']} {d['airfoils'] or ''}")


if __name__ == "__main__":
    main()
