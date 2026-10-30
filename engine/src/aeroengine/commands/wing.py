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


@command("airfoil-polars")
def airfoil_polars(ctx: JobContext) -> dict:
    """Every library section's maximum lift and best L/D at one Reynolds
    number (NeuralFoil), saved beside the index as polars.json."""
    from ..wing import library_polars
    from ..wing.airfoils import data_dir

    re = float(ctx.params.get("re", 3e5))
    if not 1e4 <= re <= 1e7:
        raise EngineError(f"Reynolds number {re:.3g} is outside 1e4 to 1e7")
    ctx.emit.progress(1, f"polars at Re {re:.3g}")
    return library_polars.build((_root(ctx) or data_dir()) / "airfoils", re, float(ctx.params.get("n_crit", 9.0)),
                                progress=lambda pct, msg: ctx.emit.progress(pct, msg))


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


@command("airfoil-delete")
def airfoil_delete(ctx: JobContext) -> dict:
    """Deletes your own imported sections from My Airfoils."""
    from ..wing.airfoils import delete_mine

    keys = ctx.params.get("keys")
    if not isinstance(keys, list) or not keys:
        raise EngineError("params.keys must list the sections to delete")
    return delete_mine([str(k) for k in keys], _root(ctx))


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


@command("wing-rans")
def wing_rans(ctx: JobContext) -> dict:
    """Meshes a multi-element wing (wall layers on every element, finer
    laminar zones, wake refinement) and runs SU2 incompressible RANS on it."""
    from ..wing import rans

    return rans.solve(ctx.params, ctx.workdir, ctx.mesh_dir / "wing.su2", ctx.params.get("su2") or ctx.options.su2_path,
                      ctx.options.cores, ctx.thread_env(), ctx.emit.progress, ctx.emit.log)


@command("wing-estimate")
def wing_estimate(ctx: JobContext) -> dict:
    """Multi-element lift and drag in about a second: the panel method for
    how the elements load each other, NeuralFoil per element (wing/estimate.py)."""
    ctx.emit.progress(10, "estimating")
    return estimate_from_params(ctx.params)


def estimate_from_params(p: dict) -> dict:
    """wing-estimate's work, shared with aeroengine serve."""
    from ..wing.estimate import estimate

    raw = p.get("elements")
    if not isinstance(raw, list) or not raw:
        raise EngineError("params.elements must list the elements: coords (placed, m), unit, chord, angle, inverted")
    alphas = [float(a) for a in p.get("alphas", [p.get("alpha", 0.0)])]
    return estimate(raw, alphas, float(p.get("speed", 15)), float(p.get("rho", 1.225)), float(p.get("mu", 1.81e-5)),
                    float(p.get("n_crit", 9.0)), p.get("ref_chord"))


@command("wing-sweep")
def wing_sweep(ctx: JobContext) -> dict:
    """The multi-element wing at several angles on one mesh (the quick level
    by default), each angle started from the one before, within a time limit."""
    from ..wing import rans

    p = {"mesh": "quick", **ctx.params}
    if p.get("order") == "rising":
        ctx.emit.log(f"polar through stall on the {p['mesh']} mesh: each angle from the one below, no time limit")
    return rans.sweep(p, ctx.workdir, ctx.mesh_dir / "wing.su2", p.get("su2") or ctx.options.su2_path,
                      ctx.options.cores, ctx.thread_env(), ctx.emit.progress, ctx.emit.log)


@command("wing-optimise")
def wing_optimise(ctx: JobContext) -> dict:
    """Optimises angles, gaps and overlaps of a multi-element wing (Optuna),
    each trial a quick estimate (seconds) or a RANS run (minutes); after a
    quick-estimate study, optionally checks the best few with RANS. Resumes
    the study if its file already holds it."""
    from ..wing import optimise, rans
    from ..wing.estimate import estimate
    from ..wing.geometry import Element, Variable, Wing

    p = ctx.params
    raw = p.get("elements")
    if not isinstance(raw, list) or len(raw) < 1:
        raise EngineError("params.elements must list the elements: unit, chord, angle, leading_edge, inverted")
    try:
        box = p.get("rules_box")
        base = Wing([Element.from_dict(e) for e in raw], min_gap=float(p.get("min_gap", 0.005)),
                    rules_box=tuple(float(v) for v in box) if box else None, alpha=float(p.get("alpha", 0.0)))
        variables = [Variable(int(v["element"]), str(v["kind"]), float(v["low"]), float(v["high"]))
                     for v in p.get("variables", [])]
    except (KeyError, TypeError, ValueError) as exc:
        raise EngineError(f"bad wing or design variables: {exc}") from None
    for v in variables:
        if not 0 <= v.element < len(base.elements) or (v.kind != "angle" and v.element == 0):
            raise EngineError(f"{v.name}: no such element (gap and overlap belong to flaps)")
    spec = optimise.Spec(variables, objective=str(p.get("objective", "max_cl")), cd_cap=p.get("cd_cap"),
                         cl_target=p.get("cl_target"), sampler=str(p.get("sampler", "tpe")),
                         trials=int(p.get("trials", 40)), parallel=max(1, int(p.get("parallel", 1))),
                         seed=p.get("seed"), solver=str(p.get("solver", "rans")))
    checks = int(p.get("check", 0)) if spec.solver == "estimate" else 0
    if spec.solver == "estimate":
        spec.parallel = 1  # a trial takes a fraction of a second
    storage = p.get("storage")
    if not storage:
        raise EngineError("params.storage must be the study file (.db) in the project")
    su2_hint = p.get("su2") or ctx.options.su2_path
    if spec.solver == "rans" or checks:
        rans.su2.find_su2(su2_hint)  # fail now, not in every trial
    flow = {k: p[k] for k in ("speed", "rho", "mu", "alpha", "model", "mesh", "transition", "n_crit",
                              "turbulence_intensity", "iterations", "ref_chord") if k in p}

    def elements_of(wing: Wing) -> list[dict]:
        return [{"coords": e.placed().tolist(), "unit": e.unit.tolist(), "angle": e.angle, "inverted": e.inverted,
                 "chord": e.chord} for e in wing.elements]

    def evaluate_rans(wing: Wing, folder: Path) -> dict:
        return rans.solve({**flow, "elements": elements_of(wing)}, folder, folder / "wing.su2", su2_hint, ctx.options.cores,
                          ctx.thread_env(), lambda pct, msg: None, lambda *a, **k: None, field=False)

    def evaluate_estimate(wing: Wing, folder: Path) -> dict:
        r = estimate(elements_of(wing), [float(p.get("alpha", 0.0))], float(p.get("speed", 15)), float(p.get("rho", 1.225)),
                     float(p.get("mu", 1.81e-5)), float(p.get("n_crit", 9.0)), p.get("ref_chord"),
                     stall_margin=float(p.get("stall_margin", 2.0)))["rows"][0]
        last = r["elements"][-1]
        reason = None
        if r["separating"]:
            # Treated like a RANS run that never settles: failed, and the sampler steers away.
            reason = (f"the last element is {last['effective_angle']:.1f} degrees in place, past its stall angle "
                      f"({last['stall_angle']:.0f}): it would separate")
        return {"cl": r["cl"], "cd": r["cd"], "cm": sum(e["cm"] for e in r["elements"]), "converged": not r["separating"],
                "reason": reason, "elements": [{"cl": e["cl"]} for e in r["elements"]]}

    evaluate = evaluate_estimate if spec.solver == "estimate" else evaluate_rans
    where = "quick estimates" if spec.solver == "estimate" else (
        f"RANS runs, {spec.parallel} at a time on {ctx.options.cores} cores each")
    ctx.emit.log(f"{spec.trials} trials, {where}, {spec.sampler.upper()}: {optimise.OBJECTIVES[spec.objective]}")
    path, name = Path(storage).expanduser(), str(p.get("name", "study"))
    out = optimise.run(base, spec, evaluate, path, name, ctx.scratch_dir,
                       (lambda pct, msg: ctx.emit.progress(pct * (0.5 if checks else 1.0), msg)), ctx.emit.log, keep_runs=False,
                       info={"solver": spec.solver, "mesh": flow.get("mesh", "medium"), "model": flow.get("model", "sa"),
                             "speed": flow.get("speed"), "alpha": flow.get("alpha", 0.0)})
    if checks:
        out = optimise.check(base, spec, path, name, evaluate_rans, checks, ctx.scratch_dir,
                             lambda pct, msg: ctx.emit.progress(50 + 0.5 * pct, msg), ctx.emit.log)
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
    steps = {"Getting SU2": 5, "Getting Open MPI": 6, "Getting MEL and Eigen": 8, "Getting the build tools": 10, "Configuring": 15, "Building": 25, "Done": 100}
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
