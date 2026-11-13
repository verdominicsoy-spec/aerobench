"""A STAR-CCM+ run of a wing against AeroBench's RANS of the same wing.

From STAR-CCM+, per wing element, a table of the wall points on the mid-span
section (Tools > Tables > XYZ Internal Table on a section of the element's
boundary, exported as CSV) with the columns: X and Z position (m, Z up),
Pressure Coefficient, and Wall Shear Stress[i] (Pa, the component along the
car, x). Columns are found by name, so their order and units text do not
matter. Then:

    engine/.venv/bin/python docs/validation/starccm/compare.py \\
        --aerobench <job folder>/result.json --rho 1.184 --speed 20 \\
        --star main.csv flap1.csv flap2.csv flap3.csv [--cl -2.1 --cd 0.09] [--plot out.png]

It prints, per element and surface, where each says the flow is reversed
(in % of the element's chord, nose to tail along x), and the forces if
STAR's are given; --plot overlays Cp and Cf. Both are read in their own
frame and normalised per element (x/c from its nose to its tail), so the
section need not be placed the same way in both.

    engine/.venv/bin/python docs/validation/starccm/compare.py --self-test
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

import numpy as np


def _column(header: list[str], *words: str) -> int:
    for i, h in enumerate(header):
        low = h.lower()
        if all(w in low for w in words):
            return i
    raise SystemExit(f"no column with {' and '.join(words)} in {header}")


def read_star(path: Path, rho: float, speed: float) -> dict:
    """x, z, Cp and Cf (wall shear along x over the dynamic pressure) of one element's section."""
    rows = list(csv.reader(path.open()))
    head, body = rows[0], [r for r in rows[1:] if r]
    ix = next((i for i, h in enumerate(head) if "position" in h.lower() and "x" in h.lower().split("position")[-1][:4]),
              None)
    ix = _column(head, "x") if ix is None else ix
    iz = next((i for i, h in enumerate(head) if "position" in h.lower() and "z" in h.lower().split("position")[-1][:4]),
              None)
    iz = _column(head, "z") if iz is None else iz
    icp, itau = _column(head, "pressure coefficient"), _column(head, "wall shear")
    a = np.array([[float(r[i]) for i in (ix, iz, icp, itau)] for r in body])
    return {"x": a[:, 0], "y": a[:, 1], "cp": a[:, 2], "cf": a[:, 3] / (0.5 * rho * speed**2)}


def surfaces(x: np.ndarray, y: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """x/c along the element's nose-to-tail line, and +1 for points above that line, -1 below."""
    nose, tail = np.array([x[np.argmin(x)], y[np.argmin(x)]]), np.array([x[np.argmax(x)], y[np.argmax(x)]])
    chord = max(float(np.linalg.norm(tail - nose)), 1e-12)
    along = (tail - nose) / chord
    rel = np.column_stack([x, y]) - nose
    xc = rel @ along / chord
    side = np.where(along[0] * rel[:, 1] - along[1] * rel[:, 0] >= 0, 1.0, -1.0)
    return xc, side


def reversed_runs(xc: np.ndarray, cf: np.ndarray, shortest: float = 0.005) -> list[tuple[float, float]]:
    """Runs of x/c where Cf < 0 (flow against x: reversed on both surfaces of a wing at a modest angle).
    Reversed points closer than three point spacings (at least 1% of chord) are one run."""
    o = np.argsort(xc)
    xs, neg = xc[o], cf[o] < 0
    gap = max(0.01, 3 * float(np.median(np.diff(xs)))) if len(xs) > 2 else 0.01
    runs: list[list[float]] = []
    for x, n in zip(xs, neg):
        if not n:
            continue
        if runs and x - runs[-1][1] <= gap:
            runs[-1][1] = x
        else:
            runs.append([x, x])
    return [(a, b) for a, b in runs if b - a >= shortest]


def describe(runs: list[tuple[float, float]]) -> str:
    return ", ".join(f"{a * 100:.0f}-{b * 100:.0f}%" for a, b in runs) or "attached"


def aerobench_elements(result: dict) -> list[dict]:
    """AeroBench's surfaces in the wing's frame, skin friction as its x component sign (as STAR's table)."""
    out = []
    for s in result["surface"]:
        out.append({"x": np.asarray(s["x"]), "y": np.asarray(s["y"]), "cp": np.asarray(s["cp"]),
                    "cf": np.asarray(s.get("cf") or [np.nan] * len(s["x"]))})
    return out


def compare(star: list[dict], ab: list[dict]) -> list[str]:
    lines = []
    for i, (s, a) in enumerate(zip(star, ab)):
        name = "Main" if i == 0 else f"Flap {i}"
        for side, label in ((1.0, "upper"), (-1.0, "lower")):
            xs, ss = surfaces(s["x"], s["y"])
            xa, sa = surfaces(a["x"], a["y"])
            rs = reversed_runs(xs[ss == side], s["cf"][ss == side])
            ra = reversed_runs(xa[sa == side], a["cf"][sa == side]) if np.isfinite(a["cf"]).all() else None
            lines.append(f"{name:7} {label}: STAR {describe(rs):24} AeroBench {describe(ra) if ra is not None else 'no Cf'}")
    return lines


def plot(star: list[dict], ab: list[dict], path: Path) -> None:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, axes = plt.subplots(2, len(star), figsize=(4 * len(star), 6), squeeze=False)
    for i, (s, a) in enumerate(zip(star, ab)):
        for d, style, who in ((s, "o", "STAR"), (a, "-", "AeroBench")):
            xc, _ = surfaces(d["x"], d["y"])
            o = np.argsort(xc)
            axes[0, i].plot(xc[o], -d["cp"][o], style, ms=2, label=who)
            axes[1, i].plot(xc[o], d["cf"][o], style, ms=2, label=who)
        axes[0, i].set_title("Main" if i == 0 else f"Flap {i}")
        axes[1, i].axhline(0, color="grey", lw=0.5)
    axes[0, 0].set_ylabel("-Cp")
    axes[1, 0].set_ylabel("Cf (x)")
    axes[0, 0].legend()
    fig.tight_layout()
    fig.savefig(path, dpi=130)


def self_test() -> None:
    import tempfile

    s = np.linspace(0, 1, 101)
    x = np.concatenate([s, s[::-1]])
    y = np.concatenate([0.05 * np.sin(np.pi * s), -0.03 * np.sin(np.pi * s[::-1])])
    tau = np.where((np.concatenate([s, s[::-1]]) > 0.8) & (y > 0), -1.0, 2.0)  # upper reversed from 80%
    q = 0.5 * 1.2 * 20**2
    with tempfile.TemporaryDirectory() as d:
        f = Path(d) / "main.csv"
        with f.open("w", newline="") as h:
            w = csv.writer(h)
            w.writerow(["Pressure Coefficient", "Wall Shear Stress[i] (Pa)", "Position[X] (m)", "Position[Z] (m)"])
            for row in zip(np.zeros_like(x), tau, x, y):
                w.writerow(row)
        star = read_star(f, 1.2, 20.0)
    assert np.allclose(star["cf"][tau < 0], -1.0 / q)
    xc, side = surfaces(star["x"], star["y"])
    runs = reversed_runs(xc[side == 1], star["cf"][side == 1])
    assert len(runs) == 1 and abs(runs[0][0] - 0.81) < 0.02 and runs[0][1] > 0.99, runs
    assert reversed_runs(xc[side == -1], star["cf"][side == -1]) == []
    print("self-test passed")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--aerobench", type=Path)
    ap.add_argument("--star", type=Path, nargs="+")
    ap.add_argument("--rho", type=float, default=1.184)
    ap.add_argument("--speed", type=float, default=20.0)
    ap.add_argument("--cl", type=float, help="STAR's Cl on the same reference chord, wing frame (negative: downforce)")
    ap.add_argument("--cd", type=float)
    ap.add_argument("--plot", type=Path)
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    if not a.aerobench or not a.star:
        ap.error("--aerobench and --star are needed")
    result = json.loads(a.aerobench.read_text())["data"]
    star = [read_star(p, a.rho, a.speed) for p in a.star]
    ab = aerobench_elements(result)
    print("\n".join(compare(star, ab)))
    print(f"AeroBench: Cl {result['cl']:.3f}, Cd {result['cd']:.4f}" +
          (f"  STAR: Cl {a.cl:.3f}, Cd {a.cd:.4f}" if a.cl is not None and a.cd is not None else ""))
    if result.get("finite"):
        f = result["finite"]
        print(f"AeroBench ran as on the car: flow turned {f['induced_angle']:+.1f} deg (AR_eff {f['aspect_ratio_effective']:.2f})")
    if a.plot:
        plot(star, ab, a.plot)
        print(f"plot: {a.plot}")


if __name__ == "__main__":
    sys.exit(main())
