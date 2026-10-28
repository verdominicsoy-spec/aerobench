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
