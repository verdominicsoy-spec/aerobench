"""Tables and plots: experiment against the estimate, the panel method and RANS.

Run: cd engine && uv run python ../docs/validation/published/compare.py
Reads results_quick.json, results_rans.json and data/; writes plots/*.png and
prints the README's tables.
"""
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

HERE = Path(__file__).resolve().parent
PLOTS = HERE / "plots"
PLOTS.mkdir(exist_ok=True)
quick = json.loads((HERE / "results_quick.json").read_text())
rans = json.loads((HERE / "results_rans.json").read_text()) if (HERE / "results_rans.json").exists() else {}

# Experiment. 30P30N: NASA LTPT, HLPW-4 package (corrected angles). NLR 7301:
# van den Berg (1979) as tabulated by ERCOFTAC UFR 3-01 (EUROVAL values).
exp30 = np.loadtxt(HERE / "data/30p30n/clalpha_exp.dat", skiprows=1)
EXP = {"30P30N": {round(a, 2): {"cl": cl} for a, cl in exp30},
       "NLR 7301 gap 2.6": {13.1: {"cl": 3.141, "cd": 0.0445}},
       "NLR 7301 gap 1.3": {6.0: {"cl": 2.416, "cd": 0.0229}}}


def cp_exp():
    zones, cur = {}, None
    for line in (HERE / "data/30p30n/cp_exp.dat").read_text().split("\n"):
        if line.startswith("zone"):
            t = line.split('"')[1]
            el, a = t.split(",")[0], float(t.split("alpha =")[1].split("deg")[0])
            cur = zones.setdefault(a, {}).setdefault(el, [])
        elif line.strip() and not line.startswith("variables") and cur is not None:
            cur.append([float(v) for v in line.split()])
    return {a: {k: np.array(v) for k, v in z.items()} for a, z in zones.items()}


def pct(model, exp):
    return 100 * (model / exp - 1)


def rans_at(case, alpha):
    out = []
    for tag, r in rans.items():
        if r["case"] != case:
            continue
        for row in r["rows"]:
            if abs(row["alpha"] - alpha) < 1e-6:
                label = r["mesh"] + (" from rest" if "from rest" in tag else "")
                out.append((label, r["model"], row))
    return out


def table(case):
    q = quick[case]
    names = q["names"]
    print(f"\n### {case}\n")
    print("| alpha | Cl exp | Cl estimate (err) | Cl panel (err) | Cl RANS (err) | Cd exp | Cd estimate | Cd RANS |")
    print("|---|---|---|---|---|---|---|---|")
    for a, e in sorted(EXP[case].items()):
        row = next(r for r in q["rows"] if abs(r["alpha"] - a) < 1e-6)
        est, pan = row["est"], row["panel"]
        rr = rans_at(case, a)
        rs = "; ".join(f"{x['cl']:.3f} ({pct(x['cl'], e['cl']):+.1f}%) {m}/{mo}{'' if x['converged'] else ' NOT CONVERGED'}"
                       f"{' SEPARATED' if x['separated'] else ''}" for m, mo, x in rr) or "not run"
        rd = "; ".join(f"{x['cd']:.4f} {m}" for m, mo, x in rr) or "-"
        ecd = f"{e['cd']:.4f}" if "cd" in e else "-"
        ecd_est = f"{est['cd']:.4f}" + (f" ({pct(est['cd'], e['cd']):+.0f}%)" if "cd" in e else "")
        print(f"| {a:g} | {e['cl']:.3f} | {est['cl']:.3f} ({pct(est['cl'], e['cl']):+.1f}%) | "
              f"{pan['cl']:.3f} ({pct(pan['cl'], e['cl']):+.1f}%) | {rs} | {ecd} | {ecd_est} | {rd} |")
    print("\nPer element Cl on the reference chord (" + ", ".join(names) + "):\n")
    print("| alpha | estimate | panel | RANS |")
    print("|---|---|---|---|")
    for a in sorted(EXP[case]):
        row = next(r for r in q["rows"] if abs(r["alpha"] - a) < 1e-6)
        rr = rans_at(case, a)
        rs = "; ".join(f"{m}: " + ", ".join(f"{el['cl']:.3f}" for el in x["elements"]) for m, mo, x in rr if x.get("elements")) or "-"
        print(f"| {a:g} | {', '.join(f'{v:.3f}' for v in row['est']['el_cl'])} | "
              f"{', '.join(f'{v:.3f}' for v in row['panel']['el_cl'])} | {rs} |")
    sep = [r for r in q["rows"] if r["published"] and r["est"]["separating"]]
    for r in sep:
        print(f"\nEstimate flag at {r['alpha']:g}: {r['est']['why']}")


def sweep_table(case):
    """Every angle RANS ran, with the estimate and panel there (no experiment at most of them)."""
    runs = {tag: r for tag, r in rans.items() if r["case"] == case and "from rest" not in tag}
    if not runs:
        return
    q = quick[case]
    alphas = sorted({x["alpha"] for r in runs.values() for x in r["rows"]})
    print(f"\nLift curve, {case}: " + " | ".join(f"RANS {r['mesh']}" for r in runs.values()) + "\n")
    print("| alpha | exp | estimate | panel | " + " | ".join(f"RANS {r['mesh']} Cl / Cd" for r in runs.values()) + " |")
    print("|---|---|---|---|" + "---|" * len(runs))
    for a in alphas:
        row = next((r for r in q["rows"] if abs(r["alpha"] - a) < 1e-6), None)
        if row is None:  # not in the quick sweep: run the estimate's angle set only
            est = pan = "-"
        else:
            est, pan = f"{row['est']['cl']:.3f}", f"{row['panel']['cl']:.3f}"
        e = EXP[case].get(round(a, 2), {}).get("cl")
        cells = []
        for r in runs.values():
            x = next((x for x in r["rows"] if abs(x["alpha"] - a) < 1e-6), None)
            cells.append("-" if x is None else f"{x['cl']:.3f} / {x['cd']:.4f}" + ("" if x["converged"] else " (nc)")
                         + (" sep" if x["separated"] else ""))
        print(f"| {a:g} | {'-' if e is None else f'{e:.3f}'} | {est} | {pan} | " + " | ".join(cells) + " |")


def lift_plot(cases, fname, title):
    fig, ax = plt.subplots(figsize=(6.4, 4.4))
    colours = ["#1f5fa8", "#c2571a", "#2f8a3a"]
    for k, case in enumerate(cases):
        q = quick[case]
        a = [r["alpha"] for r in q["rows"]]
        c = colours[k]
        lab = "" if len(cases) == 1 else f" ({case.replace('NLR 7301 ', '')})"
        ax.plot(a, [r["est"]["cl"] for r in q["rows"]], "-", color=c, label="estimate" + lab)
        ax.plot(a, [r["panel"]["cl"] for r in q["rows"]], ":", color=c, label="panel (inviscid)" + lab)
        ea = sorted(EXP[case])
        ax.plot(ea, [EXP[case][x]["cl"] for x in ea], "o", color=c, ms=7, mfc="none", mew=2, label="experiment" + lab)
        for tag, r in rans.items():
            if r["case"] == case and "from rest" not in tag:
                mk = "s" if r["mesh"] == "quick" else "D"
                for ok in (True, False):
                    pts = [(x["alpha"], x["cl"]) for x in r["rows"] if bool(x["converged"]) == ok]
                    if pts:
                        ax.plot(*zip(*pts), mk, color=c, ms=6, mfc=c if ok else "none",
                                label=f"RANS {r['mesh']} {r['model']}{'' if ok else ' (not converged)'}" + lab)
    ax.set_xlabel("angle of attack, deg")
    ax.set_ylabel("Cl (reference chord)")
    ax.set_title(title, fontsize=10)
    ax.grid(alpha=0.3)
    ax.legend(fontsize=7)
    fig.tight_layout()
    fig.savefig(PLOTS / fname, dpi=130)
    plt.close(fig)


def cp_plot(alpha):
    case = "30P30N"
    q = quick[case]
    els = json.loads((HERE / "data/30p30n/elements.json").read_text())["elements"]
    row = next(r for r in q["rows"] if abs(r["alpha"] - alpha) < 1e-6)
    ex = cp_exp()[alpha]
    fig, ax = plt.subplots(figsize=(7.2, 4.6))
    for i, e in enumerate(els):
        xy = np.asarray(e["coords"])
        ax.plot(xy[:, 0], row["panel"]["cp"][i], ":", color="0.35", lw=1, label="panel (inviscid)" if i == 0 else None)
    for m, mo, x in rans_at(case, alpha):
        if "from rest" in m:
            continue
        for i, s in enumerate(x.get("surface") or []):
            ax.plot(s["x"], s["cp"], "-", color="#1f5fa8" if m == "quick" else "#2f8a3a", lw=1,
                    label=f"RANS {m} {mo}" if i == 0 else None)
    for k, (el, pts) in enumerate(ex.items()):
        ax.plot(pts[:, 0], pts[:, 1], "o", color="#c2571a", ms=4, mfc="none", label="experiment (LTPT)" if k == 0 else None)
    lo = min(p[:, 1].min() for p in ex.values())
    ax.set_ylim(1.5, lo - 3)  # inverted; the panel method's trailing-edge nodes spike far beyond this (see README)
    ax.set_xlabel("x / c (stowed chord)")
    ax.set_ylabel("Cp")
    ax.set_title(f"30P30N, alpha {alpha:g} deg, Re 9e6", fontsize=10)
    ax.grid(alpha=0.3)
    ax.legend(fontsize=7)
    fig.tight_layout()
    fig.savefig(PLOTS / f"30p30n_cp_{str(alpha).replace('.', 'p')}.png", dpi=130)
    plt.close(fig)


if __name__ == "__main__":
    for case in quick:
        table(case)
        sweep_table(case)
    lift_plot(["30P30N"], "30p30n_cl.png", "30P30N, Re 9e6 (stowed chord), M 0.2 in the tunnel")
    lift_plot(["NLR 7301 gap 2.6", "NLR 7301 gap 1.3"], "nlr7301_cl.png", "NLR 7301 + 32% flap at 20 deg, Re 2.51e6")
    for a in (8.1, 21.34):
        cp_plot(a)
    print("\nplots:", sorted(p.name for p in PLOTS.glob("*.png")))
