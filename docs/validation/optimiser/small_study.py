"""Small estimate studies run through the real optimiser (optimise.run, the
same Optuna set-up and penalties the app's Study uses), several seeds each,
plus a dense grid of the same estimate for the 2-variable problem so the
landscape and the separation cliff can be seen.

Problems (inverted wings, free air unless said, 15 m/s, 0 degrees):
  A  overnight acceptance problem (DECISIONS.md): NACA 4412 main 300 mm at 3
     degrees, flap 140 mm; flap angle 15-45, gap 6-25 mm; most downforce.
     RANS optimum (medium mesh, SA): flap 26.9 deg, gap 9.1 mm, Cl 1.977;
     RANS held the flap to 28.2 deg and separated it from 29.0.
  B  A with the main angle free too (-4 to 12): most downforce.
  C  A's variables, best L/D.
  D  NACA 6212 starting wing (design.layout), ride height 30-300 mm, main
     and flap angles free: most downforce over a ground.

    cd engine && uv run python ../docs/validation/optimiser/small_study.py [scratch_dir] [out.json]
Writes small_study.json beside this script (or out.json). Runs no RANS."""

from __future__ import annotations

import json
import sys
import tempfile
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import HERE, flags, trial_row  # noqa: E402

from aeroengine.wing import optimise  # noqa: E402
from aeroengine.wing.airfoils import naca4  # noqa: E402
from aeroengine.wing.design import layout  # noqa: E402
from aeroengine.wing.estimate import estimate  # noqa: E402,F401
from aeroengine.wing.geometry import Element, Variable, Wing, apply  # noqa: E402

FLOW = {"speed": 15.0, "alpha": 0.0}


def overnight() -> Wing:
    s = naca4("4412")
    w = Wing([Element(s, 0.30, 3.0, np.zeros(2), True), Element(s, 0.14, 25.0, np.array([0.27, 0.025]), True)])
    w.set_gap(0.012, 1)
    return w


def evaluate(wing, folder):
    """commands/wing.py _study.evaluate_estimate, verbatim in effect (it calls the same optimise.from_estimate)."""
    return optimise.from_estimate(trial_row(wing, FLOW))


PROBLEMS = {
    "A": (overnight, [Variable(1, "angle", 15.0, 45.0), Variable(1, "gap", 0.006, 0.025)], "max_cl"),
    "B": (overnight, [Variable(0, "angle", -4.0, 12.0), Variable(1, "angle", 15.0, 45.0),
                      Variable(1, "gap", 0.006, 0.025)], "max_cl"),
    "C": (overnight, [Variable(1, "angle", 15.0, 45.0), Variable(1, "gap", 0.006, 0.025)], "max_ld"),
    "D": (lambda: _ground(layout([naca4("6212")] * 2, 0.44, True)),
          [Variable(0, "height", 0.03, 0.30), Variable(0, "angle", -4.0, 12.0), Variable(1, "angle", 12.0, 45.0)],
          "max_cl"),
}


def _ground(w):
    w.ride_height = 0.15
    return w


def run(problem, sampler, seed, trials, root):
    make, variables, objective = PROBLEMS[problem]
    base = make()
    spec = optimise.Spec([Variable(v.element, v.kind, v.low, v.high) for v in variables], objective=objective,
                         sampler=sampler, trials=trials, seed=seed, solver="estimate")
    t0 = time.time()
    out = optimise.run(base, spec, evaluate, root / f"{problem}-{sampler}-{seed}.db", "s", root)
    best = next(t for t in out["trials"] if t["number"] == out["best"])
    wing = apply(base, {k: float(v) for k, v in best["params"].items()})
    row = trial_row(wing, FLOW)
    fl = flags(row, [e.angle for e in wing.elements])
    # Which trial first got within 0.5% of the final best: how fast it settles.
    vals = [t["value"] for t in out["trials"] if t["state"] == "complete" and t.get("feasible")]
    order = [t for t in out["trials"] if t["state"] == "complete" and t.get("feasible")]
    first = next(t["number"] for t in order if abs(t["value"] - best["value"]) <= 0.005 * abs(best["value"]))
    bounds = []
    for v in spec.variables:
        x = best["params"][v.name]
        if x - v.low <= 0.01 * (v.high - v.low):
            bounds.append(f"{v.name}=low")
        elif v.high - x <= 0.01 * (v.high - v.low):
            bounds.append(f"{v.name}=high")
    return {"problem": problem, "sampler": sampler, "seed": seed, "trials": trials, "seconds": round(time.time() - t0, 1),
            "best": best["number"], "value": best["value"], "params": best["params"], "cl": best["cl"], "cd": best["cd"],
            "gap_mm": 1000 * wing.gap(1), "min_gap_mm": 1000 * wing.min_gap, "ride_height": wing.ride_height,
            "angles": [e.angle for e in wing.elements], "at_bounds": bounds, "first_within_half_pct": first,
            "failed_separating": out["failed"], "invalid": out["invalid"], "n_feasible": len(vals), **fl}


def grid(root):
    """Problem A's estimate on a grid: Cl, separating, trusted."""
    base = overnight()
    out = []
    for a in np.arange(15.0, 45.01, 0.5):
        for g in np.arange(0.006, 0.0251, 0.001):
            w = apply(base, {"angle_1": float(a), "gap_1": float(g)})
            if w.issues():
                out.append({"angle": float(a), "gap": float(g), "invalid": True})
                continue
            r = trial_row(w, FLOW)
            out.append({"angle": float(a), "gap": float(g), "invalid": False, "load": -r["cl"], "cd": r["cd"],
                        "separating": r["separating"], "trusted": r["trusted"],
                        "min_confidence": min(e["confidence"] for e in r["elements"])})
    return out


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(tempfile.mkdtemp(prefix="optaudit-"))
    root.mkdir(parents=True, exist_ok=True)
    runs = []
    for problem in PROBLEMS:
        for sampler, seeds in (("tpe", (1, 2, 3, 4, 5)), ("cmaes", (1, 2, 3))):
            for seed in seeds:
                r = run(problem, sampler, seed, 150, root)
                runs.append(r)
                print(f"{problem} {sampler:5} seed {seed}: value {r['value']:.4f} Cl {abs(r['cl']):.3f} Cd {r['cd']:.4f} "
                      f"angles {[round(a, 2) for a in r['angles']]} gap {r['gap_mm']:.1f} mm "
                      f"h {r['ride_height']} defl margin {r['deflection_margin']:.2f} "
                      f"front past stall {r['front_past_stall']:.1f} trusted {r['trusted']} "
                      f"bounds {r['at_bounds']} settled by #{r['first_within_half_pct']} "
                      f"sep-failed {r['failed_separating']} ({r['seconds']} s)", flush=True)
    g = grid(root)
    # The best grid point and the cliff: Cl just inside and just past the separation line, at each gap.
    ok = [p for p in g if not p["invalid"] and not p["separating"]]
    top = max(ok, key=lambda p: p["load"])
    cliff = {}
    for gap in sorted({p["gap"] for p in g}):
        col = sorted((p for p in g if p["gap"] == gap and not p["invalid"]), key=lambda p: p["angle"])
        held = [p for p in col if not p["separating"]]
        if held:
            cliff[round(gap * 1000)] = {"highest_valid_attached_angle": held[-1]["angle"], "load_there": held[-1]["load"],
                                        "best_angle": max(held, key=lambda p: p["load"])["angle"]}
    print(f"\ngrid best: flap {top['angle']} deg, gap {top['gap'] * 1000:.0f} mm, Cl {top['load']:.3f}, trusted {top['trusted']}")
    for k, v in cliff.items():
        print(f"  gap {k} mm: highest valid and attached {v['highest_valid_attached_angle']} deg (Cl {v['load_there']:.3f}), best at {v['best_angle']}")
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else HERE / "small_study.json"
    out.write_text(json.dumps({"runs": runs, "grid": g, "grid_best": top, "cliff": cliff},
                                                      indent=1, default=float))


if __name__ == "__main__":
    main()
