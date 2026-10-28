"""Wing Lab commands: the airfoil library."""

from __future__ import annotations

from pathlib import Path

from ..job import EngineError, JobContext
from . import command


def _root(ctx: JobContext) -> Path | None:
    raw = ctx.params.get("data_dir")
    return Path(raw).expanduser() if raw else None


@command("airfoil-fetch")
def airfoil_fetch(ctx: JobContext) -> dict:
    """Downloads the UIUC database and rebuilds the index."""
    from ..wing.airfoils import build_index, fetch_uiuc

    ctx.emit.progress(2, "downloading the UIUC airfoil database")
    count = fetch_uiuc(_root(ctx))
    ctx.emit.log(f"{count} UIUC files")
    out = build_index(_root(ctx), progress=lambda pct, msg: ctx.emit.progress(10 + 0.9 * pct, msg))
    return {"downloaded": count, **out}


@command("airfoil-index")
def airfoil_index(ctx: JobContext) -> dict:
    """Rebuilds the index from what is on disk (NACA set, UIUC files, My Airfoils)."""
    from ..wing.airfoils import build_index

    return build_index(_root(ctx), progress=lambda pct, msg: ctx.emit.progress(pct, msg))


@command("airfoil-import")
def airfoil_import(ctx: JobContext) -> dict:
    """Adds .dat files (Selig or Lednicer) to My Airfoils."""
    from ..wing.airfoils import import_files

    files = ctx.params.get("files")
    if not isinstance(files, list) or not files:
        raise EngineError("params.files must be a list of .dat paths")
    paths = [Path(f).expanduser() for f in files]
    missing = [str(p) for p in paths if not p.is_file()]
    if missing:
        raise EngineError(f"not found: {', '.join(missing)}")
    out = import_files(paths, _root(ctx))
    if not out["added"]:
        raise EngineError("none of the files could be read as an airfoil",
                          "; ".join(f"{f['file']}: {f['error']}" for f in out["failed"]))
    return out


@command("airfoil-naca")
def airfoil_naca(ctx: JobContext) -> dict:
    """A NACA 4 or 5-digit section, normalised like the library's."""
    from ..wing.airfoils import naca, section

    code = str(ctx.params.get("code", "")).strip()
    sec = section(f"NACA {code.upper().removeprefix('NACA').strip()}", naca(code))
    return sec.as_dict()


@command("wing-panel")
def wing_panel(ctx: JobContext) -> dict:
    """Inviscid panel solution for a multi-element wing over a list of angles.
    The app runs its own copy of this live; this is the reference."""
    import numpy as np

    from ..wing.panel import Solver

    elements = ctx.params.get("elements")
    if not isinstance(elements, list) or not elements:
        raise EngineError("params.elements must be a list of point lists (Selig order, in the wing's frame)")
    try:
        xy = [np.asarray(e, float) for e in elements]
    except (TypeError, ValueError) as exc:
        raise EngineError("params.elements must hold [x, y] pairs") from exc
    if any(a.ndim != 2 or a.shape[1] != 2 or len(a) < 6 for a in xy):
        raise EngineError("each element needs at least six [x, y] points")
    alphas = ctx.params.get("alphas", [0.0])
    solver = Solver(xy, ctx.params.get("ref_chord"))
    out = []
    for a in alphas:
        r = solver.solve(float(a))
        out.append({"alpha": r.alpha_deg, "cl": r.cl, "cd": r.cd, "cm": r.cm, "cl_total": r.cl_total,
                    "cm_total": r.cm_total, "cp": [c.tolist() for c in r.cp]})
    return {"ref_chord": solver.ref_chord, "ref_point": solver.ref_point.tolist(), "results": out}


@command("wing-polar")
def wing_polar(ctx: JobContext) -> dict:
    """Quick viscous polar of one section (NeuralFoil): Cl, Cd, Cm and the
    laminar-to-turbulent transition points over a range of angles."""
    import numpy as np

    from ..wing.viscous import polar, reynolds

    p = ctx.params
    coords = p.get("coords")
    if not isinstance(coords, list):
        raise EngineError("params.coords must be the section's [x, y] points (unit chord, Selig order)")
    if "re" in p:
        re = float(p["re"])
    else:
        re = reynolds(float(p.get("speed", 0)), float(p.get("chord", 0)), float(p.get("rho", 1.225)),
                      float(p.get("mu", 1.81e-5)))
    if "alphas" in p:
        alphas = [float(a) for a in p["alphas"]]
    else:
        start, stop, step = float(p.get("alpha_start", -4)), float(p.get("alpha_end", 16)), float(p.get("alpha_step", 1))
        if step <= 0 or stop < start:
            raise EngineError("alpha_step must be above zero and alpha_end at least alpha_start")
        alphas = list(np.arange(start, stop + step / 2, step))
    ctx.emit.progress(10, f"NeuralFoil at Re {re:.3g}")
    return polar(np.asarray(coords, float), alphas, re, float(p.get("n_crit", 9.0)), bool(p.get("inverted", False)),
                 str(p.get("model_size", "large")))


MESH_LEVELS = {  # surface and wake spacing scale, wall layer growth
    "coarse": (1.6, 1.2),
    "medium": (1.0, 1.15),
    "fine": (0.6, 1.1),
}


@command("wing-rans")
def wing_rans(ctx: JobContext) -> dict:
    """Meshes a multi-element wing (wall layers on every element, finer
    laminar zones, wake refinement) and runs SU2 incompressible RANS on it."""
    import numpy as np

    from ..wing import su2
    from ..wing.mesh import Settings, build
    from ..wing.viscous import polar, reynolds

    p = ctx.params
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
    if transition == "auto":
        ctx.emit.progress(2, "predicting where each element's flow turns turbulent")
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
    if model in ("sa", "sst") and transition == "auto":
        ctx.emit.log("fully turbulent model: the laminar zones only refine the mesh there")

    scale, growth = MESH_LEVELS[level]
    settings = Settings(re=re_ref, ref_chord=ref_chord, surface_fine=0.0025 * scale, surface_coarse=0.008 * scale,
                        edge=0.0015 * scale, wake_size=0.01 * scale, growth=growth, alpha_deg=alpha, transition=zones)
    ctx.emit.progress(5, "meshing")
    mesh_file = ctx.mesh_dir / "wing.su2"  # removed after the run unless keep mesh is ticked
    mesh = build(placed, settings, mesh_file, inverted)
    ctx.emit.log(f"mesh: {mesh['cells']} cells ({mesh['quads']} quads, {mesh['triangles']} triangles), "
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
                    iterations=int(p.get("iterations", 4000)))
    result = su2.run(case, mesh_file, ctx.workdir, su2.find_su2(p.get("su2") or ctx.options.su2_path), cores=ctx.options.cores,
                     progress=lambda pct, msg: ctx.emit.progress(10 + 0.88 * pct, msg), env=ctx.thread_env())
    result.pop("history_columns", None)
    surface = _surface_cp(ctx.workdir / "surface.csv", placed)
    if not result["converged"]:
        ctx.emit.log(f"not converged: {result['reason']}", level="warning")
    return {"re": re_ref, "mesh": mesh, "mesh_level": level, "transition": zones, "model": model,
            "model_name": su2.MODELS[model], **result, "surface": surface,
            "field": "flow.vtu" if (ctx.workdir / "flow.vtu").exists() else None}


def _surface_cp(path, placed) -> list[dict]:
    """Cp along each element from SU2's surface file (all walls in one file:
    each point goes to the nearest element)."""
    import csv

    import numpy as np

    if not path.exists():
        return []
    with open(path, newline="") as f:
        rows = list(csv.reader(f))
    names = [h.strip().strip('"') for h in rows[0]]
    try:
        ix, iy, icp = names.index("x"), names.index("y"), names.index("Pressure_Coefficient")
    except ValueError:
        return []
    pts = np.array([[float(r[ix]), float(r[iy]), float(r[icp])] for r in rows[1:] if len(r) == len(names)])
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


@command("su2-install")
def su2_install(ctx: JobContext) -> dict:
    """Builds SU2 from source into <repo>/build/su2 (engine/scripts/install_su2.sh)."""
    import subprocess

    script = Path(__file__).resolve().parents[3] / "scripts" / "install_su2.sh"
    if not script.is_file():
        raise EngineError(f"missing {script}")
    proc = subprocess.Popen(["bash", str(script)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            errors="replace", env=ctx.thread_env())
    tail: list[str] = []
    steps = {"Getting SU2": 5, "Configuring": 15, "Building": 25, "Done": 100}
    for line in proc.stdout:  # type: ignore[union-attr]
        line = line.rstrip()
        tail = (tail + [line])[-30:]
        for key, pct in steps.items():
            if key in line:
                ctx.emit.progress(pct, line.strip())
        if line.startswith("[") and "/" in line.split("]")[0]:  # ninja: [n/total]
            try:
                done, total = line[1:].split("]")[0].split("/")
                ctx.emit.progress(25 + 70 * int(done) / int(total), f"compiling {done} of {total}")
            except ValueError:
                pass
    if proc.wait() != 0:
        raise EngineError("SU2 did not build", "\n".join(tail[-15:]))
    from ..wing.su2 import find_su2

    return {"su2": str(find_su2())}
