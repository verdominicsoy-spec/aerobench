"""One RANS run of a multi-element wing: laminar zones, mesh, SU2, surface Cp.
Used by the wing-rans command and by every optimiser trial."""

from __future__ import annotations

import csv
from pathlib import Path
from typing import Callable

import numpy as np

from ..job import EngineError
from . import su2
from .mesh import Settings, build
from .viscous import polar, reynolds

MESH_LEVELS = {  # surface and wake spacing scale, wall layer growth
    "quick": (1.6, 1.2),
    "coarse": (1.6, 1.2),
    "medium": (1.0, 1.15),
    "fine": (0.6, 1.1),
}


# The quick level answers to three figures: lift and drag still for 0.1%
# over 100 iterations and the residual down 3 orders, rather than 0.01% over
# 200 and 4 orders.
CONVERGENCE = {"quick": {"tolerance": 1e-3, "window": 100, "residual_drop": 3.0}}


def solve(p: dict, workdir: Path, mesh_file: Path, su2_hint: str | None, cores: int, env: dict | None,
          progress: Callable[[float, str], None], log: Callable[..., None], field: bool = True,
          mesh_ready: dict | None = None, restart: Path | None = None) -> dict:
    """p holds elements (coords placed in m, unit, angle, inverted, chord),
    speed, rho, mu, alpha, model, mesh level, transition and the rest of the
    wing-rans parameters. The mesh goes to mesh_file, SU2's files to workdir.
    mesh_ready: mesh_file already holds this wing's mesh (its statistics and
    transition zones, from an earlier solve), so it is not built again.
    restart: start SU2 from this solution (same mesh) rather than from rest."""
    raw = p.get("elements")
    if not isinstance(raw, list) or not raw:
        raise EngineError("params.elements must list the elements: coords (placed, m), unit, angle, inverted, chord")
    placed = [np.asarray(e["coords"], float) for e in raw]
    inverted = [bool(e.get("inverted", False)) for e in raw]
    chords = [float(e["chord"]) for e in raw]
    speed, rho, mu = float(p.get("speed", 15)), float(p.get("rho", 1.225)), float(p.get("mu", 1.81e-5))
    alpha = float(p.get("alpha", 0.0))
    ref_chord = float(p.get("ref_chord", sum(chords)))
    model = str(p.get("model", "sa"))
    if model not in su2.MODELS:
        raise EngineError(f"unknown model '{model}'", f"one of {', '.join(su2.MODELS)}")
    level = str(p.get("mesh", "medium"))
    if level not in MESH_LEVELS:
        raise EngineError(f"mesh must be one of {', '.join(MESH_LEVELS)}")
    re_ref = reynolds(speed, ref_chord, rho, mu)

    # Laminar zones: typed per element, or predicted by the quick viscous
    # solver at each element's own angle, in isolation.
    transition = p.get("transition", "auto")
    zones = []
    if mesh_ready is not None:
        zones = [tuple(z) for z in mesh_ready["transition"]]
    elif transition == "auto":
        progress(2, "predicting where each element's flow turns turbulent")
        for e, c in zip(raw, chords):
            sense = -1 if e.get("inverted") else 1
            a = float(e.get("angle", 0)) + sense * alpha
            row = polar(np.asarray(e["unit"], float), [a], reynolds(speed, c, rho, mu),
                        float(p.get("n_crit", 9.0)), bool(e.get("inverted", False)))["rows"][0]
            zones.append((row["transition_suction"], row["transition_pressure"]))
    elif isinstance(transition, list) and len(transition) == len(raw):
        zones = [(float(t[0]), float(t[1])) for t in transition]
    else:
        raise EngineError("params.transition must be \"auto\" or one [suction, pressure] pair per element")
    if model in ("sa", "sst") and transition == "auto" and mesh_ready is None:
        log("fully turbulent model: the laminar zones only refine the mesh there")

    scale, growth = MESH_LEVELS[level]
    settings = Settings(re=re_ref, ref_chord=ref_chord, surface_fine=0.0025 * scale, surface_coarse=0.008 * scale,
                        edge=0.0015 * scale, wake_size=0.01 * scale, growth=growth, alpha_deg=alpha, transition=zones)
    if mesh_ready is not None:
        mesh = mesh_ready["mesh"]
    else:
        progress(5, "meshing")
        settings.alpha_deg = float(p.get("wake_alpha", alpha))  # a sweep aligns the wakes with its middle angle
        mesh = build(placed, settings, mesh_file, inverted)
        log(f"mesh: {mesh['cells']} cells ({mesh['quads']} quads, {mesh['triangles']} triangles), "
            f"{mesh['layers']} wall layers")
    ref_point = p.get("ref_point")
    if ref_point is None:
        main = placed[0]
        half = (len(main) - 1) // 2
        le, te = main[half], 0.5 * (main[0] + main[-1])
        ref_point = (le + 0.25 * (te - le)).tolist()
    case = su2.Case(speed=speed, rho=rho, mu=mu, alpha_deg=alpha, ref_chord=ref_chord,
                    ref_point=(float(ref_point[0]), float(ref_point[1])), walls=[f"wall_{i}" for i in range(len(raw))],
                    model=model, turbulence_intensity=float(p.get("turbulence_intensity", 0.01)),
                    iterations=int(p.get("iterations", 4000)), restart=str(restart) if restart else None,
                    **CONVERGENCE.get(level, {}))
    result = su2.run(case, mesh_file, workdir, su2.find_su2(su2_hint), cores=cores,
                     progress=lambda pct, msg: progress(10 + 0.88 * pct, msg), env=env)
    result.pop("history_columns", None)
    surface = surface_cp(workdir / "surface.csv", placed)
    if not result["converged"]:
        log(f"not converged: {result['reason']}", level="warning")
    view = None
    if field and (workdir / "flow.vtu").exists():
        from .field import extract

        progress(98, "sampling the flow field")
        try:
            extract(workdir / "flow.vtu", placed, workdir)
            view = "field.json"
        except Exception as exc:  # noqa: BLE001 - the run's numbers stand without the picture
            log(f"no field view: {exc}", level="warning")
    return {"alpha": alpha, "re": re_ref, "mesh": mesh, "mesh_level": level, "transition": zones, "model": model,
            "model_name": su2.MODELS[model], **result, "surface": surface,
            "field": "flow.vtu" if (workdir / "flow.vtu").exists() else None, "field_view": view}


def surface_cp(path: Path, placed: list[np.ndarray]) -> list[dict]:
    """Cp along each element from SU2's surface file (all walls in one file:
    each point goes to the nearest element)."""
    if not path.exists():
        return []
    with open(path, newline="") as f:
        rows = list(csv.reader(f))
    names = [h.strip().strip('"') for h in rows[0]]
    if "x" not in names or "y" not in names:
        return []
    ix, iy = names.index("x"), names.index("y")
    if "Pressure_Coefficient" in names:
        icp, factor = names.index("Pressure_Coefficient"), 1.0
    elif "Pressure" in names:
        # SU2 8.5's CSV surface file holds only the solution variables. Its
        # incompressible pressure is non-dimensional by rho V^2 (INC_NONDIM=
        # INITIAL_VALUES) and zero in the free stream, so Cp is twice it
        # (checked against the Pressure_Coefficient in flow.vtu).
        icp, factor = names.index("Pressure"), 2.0
    else:
        return []
    pts = np.array([[float(r[ix]), float(r[iy]), factor * float(r[icp])] for r in rows[1:] if len(r) == len(names)])
    owner = np.argmin([np.min(np.linalg.norm(pts[:, None, :2] - e[None, :, :], axis=2), axis=1) for e in placed], axis=0)
    out = []
    for i, e in enumerate(placed):
        sel = pts[owner == i]
        # In order around the element (Selig: trailing edge, upper, leading
        # edge, lower), by the nearest point of its outline.
        near = np.argmin(np.linalg.norm(sel[:, None, :2] - e[None, :, :], axis=2), axis=1)
        order = np.argsort(near, kind="stable")
        sel, near = sel[order], near[order]
        half = (len(e) - 1) // 2
        out.append({"x": np.round(sel[:, 0], 6).tolist(), "y": np.round(sel[:, 1], 6).tolist(),
                    "cp": np.round(sel[:, 2], 5).tolist(),
                    "side": ["upper" if k <= half else "lower" for k in near]})
    return out


def sweep(p: dict, workdir: Path, mesh_file: Path, su2_hint: str | None, cores: int, env: dict | None,
          progress: Callable[[float, str], None], log: Callable[..., None]) -> dict:
    """The wing at several angles on one mesh, each angle started from the
    previous one's solution, in rising order. Stops starting new angles once
    the next would run past time_limit seconds (from the time the last one
    took). Each angle's files go to workdir/a<angle>."""
    import time

    alphas = sorted({float(a) for a in p.get("alphas", [])})
    if not alphas:
        raise EngineError("params.alphas must list the wing angles")
    limit = float(p.get("time_limit", 300))
    start = time.time()
    rows, skipped, ready, previous = [], [], None, None
    base = {**p, "wake_alpha": 0.5 * (alphas[0] + alphas[-1])}
    for k, a in enumerate(alphas):
        elapsed = time.time() - start
        if rows and elapsed + rows[-1]["seconds"] > limit:
            skipped = alphas[k:]
            log(f"time limit: {len(skipped)} angle(s) not run", level="warning")
            break
        folder = workdir / f"a{a:g}"
        folder.mkdir(parents=True, exist_ok=True)
        t0 = time.time()
        lo, hi = 100 * k / len(alphas), 100 * (k + 1) / len(alphas)
        try:
            r = solve({**base, "alpha": a}, folder, mesh_file, su2_hint, cores, env,
                      lambda pct, msg: progress(lo + (hi - lo) * pct / 100, f"{a:g}°: {msg}"), log,
                      mesh_ready=ready, restart=previous)
        except EngineError as exc:
            if previous is None:
                raise
            # A restart that will not settle: try that angle once from rest.
            log(f"{a:g}° from the previous solution failed ({exc.msg}); from rest", level="warning")
            r = solve({**base, "alpha": a}, folder, mesh_file, su2_hint, cores, env,
                      lambda pct, msg: progress(lo + (hi - lo) * pct / 100, f"{a:g}°: {msg}"), log,
                      mesh_ready=ready)
        r.pop("history_columns", None)
        r.update(seconds=round(time.time() - t0, 1), folder=folder.name)
        rows.append(r)
        ready = {"mesh": r["mesh"], "transition": r["transition"]}
        previous = (folder / "restart.dat").resolve() if (folder / "restart.dat").exists() else None
        log(f"{a:g}°: Cl {r['cl']:.4f}, Cd {r['cd']:.5f}{'' if r['converged'] else ' (not converged)'}, {r['seconds']:.0f} s")
    return {"rows": rows, "skipped": skipped, "seconds": round(time.time() - start, 1), "time_limit": limit}
