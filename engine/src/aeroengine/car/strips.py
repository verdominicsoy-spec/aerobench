"""Sections across half the car, added up as strips into the whole car's
ClA, CdA and the share of downforce on the rear axle.

Each strip stands for the width around its plane; the car is symmetric,
so half is run and doubled. A wing's share of a strip is its own markers'
force: over the strips its span covers it gives the wing's 2D coefficient,
which is turned into a finite wing as Wing Lab does (its 3D factor, or the
endplate estimate), so full runs and quick sums can be compared.
"""

from __future__ import annotations

import math
from pathlib import Path

from ..wing.finite import car_contribution


def plan(half_width_mm: float, n: int = 7) -> list[tuple[float, float]]:
    """(y, width) in mm: strips narrower towards the outside, where the
    wheels and sidepods change the section quickly."""
    edges = [half_width_mm * math.sin(math.pi / 2 * k / n) for k in range(n + 1)]
    return [((a + b) / 2, b - a) for a, b in zip(edges, edges[1:])]


def _axles(setup: dict) -> tuple[float, float]:
    xs = {w["name"][0]: [] for w in setup["wheels"]}
    for w in setup["wheels"]:
        xs[w["name"][0]].append(w["centre"][0])
    return sum(xs["F"]) / len(xs["F"]), sum(xs["R"]) / len(xs["R"])


def _chord_m(wing: dict) -> float:
    return sum((max(p[0] for p in el) - min(p[0] for p in el)) for el in wing["elements"]) / 1000.0


def combine(strips: list[dict], setup: dict, speed: float, rho: float, wings: list[dict], mesh: str) -> dict:
    q = 0.5 * rho * speed * speed
    x_front, x_rear = _axles(setup)
    lift = sum(s["lift"] * s["width"] / 1000.0 for s in strips)  # one half, N
    drag = sum(s["drag"] * s["width"] / 1000.0 for s in strips)
    rear = sum(s["lift"] * s["width"] / 1000.0 * (x_front - s["x_cp"]) / (x_front - x_rear) for s in strips)
    cla_2d, cda_2d = -2 * lift / q, 2 * drag / q
    out_wings, cla, cda = [], cla_2d, cda_2d
    for w in wings:
        pos = w["position"]
        covered = [s for s in strips if s["y"] <= w["span"] * 500.0 and pos in s.get("wing_lift", {})]
        width = sum(s["width"] for s in covered) / 1000.0
        if not covered or width <= 0:
            continue
        wl = sum(s["wing_lift"][pos] * s["width"] / 1000.0 for s in covered)
        wd = sum(s["wing_drag"].get(pos, 0.0) * s["width"] / 1000.0 for s in covered)
        chord = _chord_m(w)
        cl, cd = wl / (q * chord * width), wd / (q * chord * width)
        w_cla, w_cda = car_contribution(cl, cd, w["span"], chord, w.get("endplate"), w.get("factor3d", 1.0))
        w_cla_2d, w_cda_2d = -2 * wl / q, 2 * wd / q
        cla += w_cla - w_cla_2d
        cda += w_cda - w_cda_2d
        out_wings.append({"position": pos, "cla": w_cla, "cda": w_cda, "cla_2d": w_cla_2d, "cda_2d": w_cda_2d})
    return {"mesh": mesh, "speed": speed, "cla": cla, "cda": cda, "rear_share": rear / lift if lift else None,
            "cla_2d_wings": cla_2d, "strips": strips, "converged": all(s["converged"] for s in strips),
            "wings": out_wings}


def run(setup: dict, wings: list[dict], flow: dict, preset: str, workdir: Path, su2_hint: str | None, cores: int,
        progress, planes: list | None = None, iterations: int = 6000) -> dict:
    """Every strip's section solved in turn; the car result."""
    from ..cad.edit.refs import load_part
    from .case import RHO, solve_section
    from .section import cut

    shape, _, _ = load_part(Path(setup["step"]), None)
    half = max(abs(w["centre"][1]) + w["width"] / 2 for w in setup["wheels"])
    planes = [tuple(p) for p in planes] if planes else plan(half)
    results = []
    for k, (y, width) in enumerate(planes):
        here = [w for w in wings if y <= w["span"] * 500.0]
        report = lambda p, m, k=k: progress(100 * (k + p / 100) / len(planes), f"strip {k + 1} of {len(planes)}: {m}")  # noqa: E731
        r = solve_section(cut(shape, y, setup), here, setup, flow, preset, workdir / f"strip_{k + 1}", su2_hint, cores,
                          report, iterations)
        r["width"] = width
        results.append(r)
    return combine(results, setup, float(flow.get("speed", setup.get("speed", 15.0))), RHO, wings, preset)
