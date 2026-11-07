"""Wing Lab commands: the airfoil library."""

from __future__ import annotations

from pathlib import Path

from ..job import EngineError, JobContext, check_air
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
        check_air(float(p.get("rho", 1.225)), float(p.get("mu", 1.81e-5)))
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


@command("wing-mesh")
def wing_mesh(ctx: JobContext) -> dict:
    """The mesh wing-rans would run on, written to the job folder as wing.su2
    for the app to draw. Same parameters as wing-rans; SU2 is not needed."""
    from ..wing import rans

    return rans.solve({**ctx.params, "mesh_only": True}, ctx.workdir, ctx.workdir / "wing.su2", None,
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
    check_air(float(p.get("rho", 1.225)), float(p.get("mu", 1.81e-5)))
    alphas = [float(a) for a in p.get("alphas", [p.get("alpha", 0.0)])]
    height = p.get("ride_height")
    return estimate(raw, alphas, float(p.get("speed", 15)), float(p.get("rho", 1.225)), float(p.get("mu", 1.81e-5)),
                    float(p.get("n_crit", 9.0)), p.get("ref_chord"), ride_height=None if height is None else float(height))


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


@command("wing-starter")
def wing_starter(ctx: JobContext) -> dict:
    """A starting wing for designing one from scratch: the library's sections
    ranked by maximum lift at the main element's Reynolds number, the best few
    laid out as a 2 to 5-element wing (in the rules box if given) and the one
    the quick estimate likes best returned, with design variables to search."""
    from ..wing.airfoils import data_dir
    from ..wing.design import starter

    p = ctx.params
    box = p.get("rules_box")
    check_air(float(p.get("rho", 1.225)), float(p.get("mu", 1.81e-5)))
    return starter((_root(ctx) or data_dir()) / "airfoils", elements=int(p.get("elements", 2)),
                   chord_total=float(p.get("chord_total", 0.44)), inverted=bool(p.get("inverted", True)),
                   rules_box=tuple(float(v) for v in box) if box else None, speed=float(p.get("speed", 15)),
                   rho=float(p.get("rho", 1.225)), mu=float(p.get("mu", 1.81e-5)), n_crit=float(p.get("n_crit", 9.0)),
                   min_thickness=float(p.get("min_thickness", 0.08)), min_gap=float(p.get("min_gap", 0.005)),
                   ride_height=None if p.get("ride_height") is None else float(p["ride_height"]),
                   progress=lambda pct, msg: ctx.emit.progress(pct, msg))


@command("wing-shortlist")
def wing_shortlist(ctx: JobContext) -> dict:
    """Each element's sections for a design search to choose between: its own
    first, then the library's best by maximum lift at its Reynolds number."""
    from ..wing.airfoils import data_dir
    from ..wing.design import shortlist

    p = ctx.params
    chords = [float(c) for c in p.get("chords") or []]
    if not chords:
        raise EngineError("params.chords must give each element's chord")
    check_air(float(p.get("rho", 1.225)), float(p.get("mu", 1.81e-5)))
    lists = shortlist((_root(ctx) or data_dir()) / "airfoils", chords, [k or None for k in p.get("current") or []],
                      float(p.get("speed", 15)), float(p.get("rho", 1.225)), float(p.get("mu", 1.81e-5)),
                      float(p.get("n_crit", 9.0)), float(p.get("min_thickness", 0.08)), int(p.get("size", 0)),
                      progress=lambda pct, msg: ctx.emit.progress(pct, msg))
    return {"shortlists": lists}


def _lap_score(raw, base):
    """The fastest-lap objective's car and track: params.lap holds the Lap
    Sim's car (as in a lapsim job), its track, the wing's span and endplate
    height (or typed 3D factor), and the ClA and CdA of the wing replaced."""
    from ..lapsim import Car
    from ..lapsim.track import DEFAULT_DS, resolve
    from ..wing.optimise import LapScore

    if not isinstance(raw, dict):
        raise EngineError("the fastest-lap objective needs params.lap: car, track, span")
    endplate = raw.get("endplate")
    # A 1 m step at least: plenty to rank wings by, and each lap runs in a few tens of ms.
    ds = max(float(raw.get("ds", DEFAULT_DS)), 1.0)
    return LapScore(car=Car.from_dict(raw.get("car"), "lap.car"), track=resolve(raw.get("track"), ds),
                    span=float(raw.get("span", 1.0)), chord=sum(e.chord for e in base.elements),
                    endplate=None if endplate is None else float(endplate), factor=float(raw.get("factor", 1.0)),
                    replaced_cla=float(raw.get("replaced_cla", 0.0)), replaced_cda=float(raw.get("replaced_cda", 0.0)),
                    start_speed=float(raw.get("start_speed", 0.0)))


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
                    rules_box=tuple(float(v) for v in box) if box else None, alpha=float(p.get("alpha", 0.0)),
                    ride_height=None if p.get("ride_height") is None else float(p["ride_height"]))
        variables = [Variable(int(v["element"]), str(v["kind"]), float(v.get("low", 0.0)), float(v.get("high", 0.0)),
                              tuple(str(k) for k in v.get("choices") or ()))
                     for v in p.get("variables", [])]
    except (KeyError, TypeError, ValueError) as exc:
        raise EngineError(f"bad wing or design variables: {exc}") from None
    # With chords searched, every trial's coefficients go on the starting
    # wing's total chord: comparable between trials (a bigger wing shows as
    # more lift), and the chord the fastest-lap objective turns them into ClA with.
    if any(v.kind == "chord" for v in variables) and p.get("ref_chord") is None:
        p = {**p, "ref_chord": sum(e.chord for e in base.elements)}
    # The sections a section variable can choose, from the library.
    wanted = sorted({k for v in variables if v.kind == "airfoil" for k in v.choices})
    sections = None
    if wanted:
        from ..wing.airfoils import data_dir
        from ..wing.design import units

        sections = units((_root(ctx) or data_dir()) / "airfoils", wanted)
    for v in variables:
        if v.kind == "height" and base.ride_height is None:
            raise EngineError("the ride height is a variable only over a ground", "set a ride height first")
        if not 0 <= v.element < len(base.elements) or (v.kind in ("gap", "overlap") and v.element == 0):
            raise EngineError(f"{v.name}: no such element (gap and overlap belong to flaps)")
    return _study(ctx, p, base, variables, sections)[0]


def _study(ctx: JobContext, p: dict, base, variables, sections, car=None, span=(0.0, 100.0)):
    """The estimate or RANS study of `base` over `variables`, then the RANS
    checks of its best: wing-optimise's work, shared with wing-design (which
    scores in car terms through `car`). `span` maps the study's progress, 0 to
    100, onto the job's. Returns the summary and the spec."""
    from ..wing import optimise, rans, su2
    from ..wing.estimate import estimate
    from ..wing.geometry import Wing

    def emit(pct: float, msg: str) -> None:
        ctx.emit.progress(span[0] + (span[1] - span[0]) * pct / 100, msg)

    spec = optimise.Spec(variables, objective=str(p.get("objective", "max_cl")), cd_cap=p.get("cd_cap"),
                         cl_target=p.get("cl_target"), sampler=str(p.get("sampler", "tpe")),
                         trials=int(p.get("trials", 40)), parallel=max(1, int(p.get("parallel", 1))),
                         seed=p.get("seed"), solver=str(p.get("solver", "rans")), sections=sections,
                         lap=_lap_score(p.get("lap"), base) if p.get("objective") == "min_lap_time" else None,
                         car=car)
    checks = int(p.get("check", 0)) if spec.solver == "estimate" else 0
    if spec.solver == "estimate":
        spec.parallel = 1  # a trial takes a fraction of a second
    storage = p.get("storage")
    if not storage:
        raise EngineError("params.storage must be the study file (.db) in the project")
    su2_hint = p.get("su2") or ctx.options.su2_path
    if spec.solver == "rans" or checks:
        rans.su2.find_su2(su2_hint)  # fail now, not in every trial
    check_air(float(p.get("rho", 1.225)), float(p.get("mu", 1.81e-5)))
    flow = {k: p[k] for k in ("speed", "rho", "mu", "alpha", "model", "mesh", "transition", "n_crit",
                              "turbulence_intensity", "iterations", "ref_chord") if k in p}

    def elements_of(wing: Wing) -> list[dict]:
        return [{"coords": e.placed().tolist(), "unit": e.unit.tolist(), "angle": e.angle, "inverted": e.inverted,
                 "chord": e.chord} for e in wing.elements]

    def evaluate_rans(wing: Wing, folder: Path) -> dict:
        return rans.solve({**flow, "elements": elements_of(wing), "ride_height": wing.ride_height}, folder,
                          folder / "wing.su2", su2_hint, ctx.options.cores,
                          ctx.thread_env(), lambda pct, msg: None, lambda *a, **k: None, field=False)

    def evaluate_estimate(wing: Wing, folder: Path) -> dict:
        r = estimate(elements_of(wing), [float(p.get("alpha", 0.0))], float(p.get("speed", 15)), float(p.get("rho", 1.225)),
                     float(p.get("mu", 1.81e-5)), float(p.get("n_crit", 9.0)), p.get("ref_chord"),
                     stall_margin=float(p.get("stall_margin", 2.0)), ride_height=wing.ride_height)["rows"][0]
        # A separating wing is treated like a RANS run that never settles: failed, and the sampler steers away.
        return {"cl": r["cl"], "cd": r["cd"], "cm": sum(e["cm"] for e in r["elements"]), "converged": not r["separating"],
                "reason": r["why"], "elements": [{"cl": e["cl"]} for e in r["elements"]]}

    evaluate = evaluate_estimate if spec.solver == "estimate" else evaluate_rans
    where = "quick estimates" if spec.solver == "estimate" else (
        f"RANS runs, {spec.parallel} at a time on {ctx.options.cores} cores each")
    ctx.emit.log(f"{spec.trials} trials, {where}, {spec.sampler.upper()}: {optimise.OBJECTIVES[spec.objective]}")
    path, name = Path(storage).expanduser(), str(p.get("name", "study"))
    # Calibration: while the estimate study runs, one RANS run of the starting
    # wing on the other cores. Its lift and drag over the estimate's correct the
    # ranking before the RANS checks: the estimate's offset is mostly a matter
    # of the sections (drag 10% high on a NACA 4412 wing, 30% low on a 6212).
    anchor: dict = {}
    calibrate = None
    if checks and spec.solver == "estimate" and p.get("anchor"):
        import threading

        def run_anchor() -> None:
            folder = ctx.scratch_dir / "anchor"
            folder.mkdir(parents=True, exist_ok=True)
            try:
                est = evaluate_estimate(base, folder)
                ran = evaluate_rans(base, folder)
                anchor.update(cl_estimate=est["cl"], cd_estimate=est["cd"], cl_rans=ran["cl"], cd_rans=ran["cd"],
                              converged=bool(ran["converged"]))
            except EngineError as exc:
                anchor.update(converged=False, reason=exc.msg)

        calibrate = threading.Thread(target=run_anchor, daemon=True)
        calibrate.start()
        ctx.emit.log("calibrating: one RANS run of the starting wing alongside the estimate study")
    out = optimise.run(base, spec, evaluate, path, name, ctx.scratch_dir,
                       (lambda pct, msg: emit(pct * (0.5 if checks else 1.0), msg)), ctx.emit.log, keep_runs=False,
                       info={"solver": spec.solver, "mesh": flow.get("mesh", "medium"), "model": flow.get("model", su2.DEFAULT_MODEL),
                             "speed": flow.get("speed"), "alpha": flow.get("alpha", 0.0)})
    scale = (1.0, 1.0)
    if calibrate is not None:
        emit(50, "waiting for the calibration run")
        calibrate.join()
        if anchor.get("converged") and abs(anchor["cl_estimate"]) > 1e-6 and anchor["cd_estimate"] > 0:
            scale = (anchor["cl_rans"] / anchor["cl_estimate"], anchor["cd_rans"] / anchor["cd_estimate"])
            ctx.emit.log(f"calibration: RANS lift x{scale[0]:.3f}, drag x{scale[1]:.3f} of the estimate's on the starting wing")
        else:
            ctx.emit.log(f"calibration run did not settle ({anchor.get('reason', 'not converged')}): ranking uncorrected",
                         level="warning")
        anchor.update(cl_scale=scale[0], cd_scale=scale[1])
        optimise.record_anchor(path, name, spec, anchor)
    if checks:
        out = optimise.check(base, spec, path, name, evaluate_rans, checks, ctx.scratch_dir,
                             lambda pct, msg: emit(50 + 0.5 * pct, msg), ctx.emit.log, scale=scale,
                             until_pass=bool(p.get("until_pass", False)))
    return out, spec


FINALISTS = 5  # without RANS checks: the best distinct designs by the estimate


def rank_finalists(checks: list[dict], direction: str) -> list[dict]:
    """RANS checks in the order the card shows them: those that held (a value and
    the goal's limit or target met), best first; then those that missed their limit
    or target, by value; then those that separated or did not converge."""
    sense = -1 if direction == "maximize" else 1

    def key(c: dict):
        v = c.get("value")
        tier = 2 if v is None else (0 if c.get("feasible", True) else 1)
        return tier, sense * (v or 0.0)

    return sorted(checks, key=key)


@command("wing-design")
def wing_design(ctx: JobContext) -> dict:
    """One run from the rules box to finalists: a wing laid out to fill the box
    (or the one given, moved inside it), the estimate study over its angles,
    slots, chords, sections and place in the box, scored in car terms, then
    RANS on the best few, ranked by RANS. The design frame: m, x downstream
    from the box's front, y up from the ground. Resumes a study of the same name."""
    import json as _json

    import numpy as np

    from ..wing import optimise
    from ..wing.airfoils import data_dir
    from ..wing.design import starter, units, variables as default_variables
    from ..wing.geometry import Element, Variable, Wing, apply

    p = ctx.params
    try:
        box = tuple(float(v) for v in p["box"])
        storage, name = Path(str(p["storage"])).expanduser(), str(p["name"])
    except (KeyError, TypeError, ValueError):
        raise EngineError("params.box ([x0, y0, x1, y1], m, the design frame), storage and name are needed") from None
    if len(box) != 4 or not (box[2] > box[0] and box[3] > box[1] and (box[1] >= 0 or p.get("free_air"))):
        raise EngineError("params.box must be [x0, y0, x1, y1] with x1 > x0 and y1 > y0 >= 0 (y up from the ground)")
    goal = str(p.get("goal", "max_cla"))
    car_raw = p.get("car")
    if goal == "balance" and not car_raw:
        raise EngineError("the balance goal needs a base car", "set up the base car in Wing Lab's Car section")
    inverted = bool(p.get("inverted", True))
    flow = {k: float(p.get(k, d)) for k, d in (("speed", 15.0), ("rho", 1.225), ("mu", 1.81e-5), ("n_crit", 9.0))}
    check_air(flow["rho"], flow["mu"])
    root = (_root(ctx) or data_dir()) / "airfoils"
    saved = storage.with_suffix(".design.json")
    ctx.emit.progress(1, "laying out the wing")
    # What the starting wing was laid out for: a resumed design must ask for the same.
    signature = {"box": list(box), "elements": None if p.get("start") else int(p.get("elements", 2)),
                 "start": bool(p.get("start")), "inverted": inverted, "free_air": bool(p.get("free_air", False))}
    if saved.exists():  # a resumed design: the same starting wing and search
        first = _json.loads(saved.read_text())
        if first.get("signature", signature) != signature:
            raise EngineError(f"a different design is saved under the name {name}",
                              "start a new design (another name) for other settings")
    elif p.get("start"):
        try:
            els = [Element.from_dict(e) for e in p["start"]]
        except (KeyError, TypeError, ValueError) as exc:
            raise EngineError(f"bad starting wing: {exc}") from None
        w = Wing(els, min_gap=float(p.get("min_gap", 0.005)), rules_box=box)
        for _ in range(40):  # where it is if it fits; else at the box's front and bottom, smaller until it does
            if not w.issues():
                break
            pts = np.vstack([e.placed() for e in w.elements])
            shift = np.array([box[0], box[1]]) + 1e-7 - pts.min(axis=0)
            for e in w.elements:
                e.leading_edge = e.leading_edge + shift
            if not w.issues():
                break
            origin = w.elements[0].leading_edge.copy()
            for e in w.elements:
                e.chord *= 0.95
                e.leading_edge = origin + 0.95 * (e.leading_edge - origin)
        else:
            raise EngineError("the wing on the canvas does not fit the rules box even at a fraction of its size",
                              "start from scratch, or check the box")
        keys = [e.get("key") for e in p["start"]]
        # Its sections are still searched: each element's own first, then the library's best at its Reynolds number.
        lists = None
        if any(keys):
            from ..wing.design import shortlist

            lists = [[x["key"] for x in sl] for sl in shortlist(
                root, [e.chord for e in w.elements], keys, flow["speed"], flow["rho"], flow["mu"], flow["n_crit"],
                float(p.get("min_thickness", 0.08)), progress=lambda pct, msg: ctx.emit.progress(1 + 0.09 * pct, msg))]
        first = {"elements": [{"key": k, "name": None, "unit": e.unit.tolist(), "chord": e.chord, "angle": e.angle,
                               "leading_edge": e.leading_edge.tolist(), "inverted": e.inverted}
                              for k, e in zip(keys, w.elements)],
                 "shortlists": lists, "from_canvas": True}
    else:
        # The sections are judged over the ground at about where the wing will start (halfway up the box).
        start_height = None if p.get("free_air") else box[1] + 0.25 * (box[3] - box[1])
        r = starter(root, elements=int(p.get("elements", 2)), inverted=inverted, rules_box=box,
                    min_thickness=float(p.get("min_thickness", 0.08)), min_gap=float(p.get("min_gap", 0.005)),
                    progress=lambda pct, msg: ctx.emit.progress(1 + 0.09 * pct, msg), fill=True,
                    ride_height=start_height, **flow)
        first = {"elements": r["elements"], "shortlists": [[k["key"] for k in keys] for keys in r["shortlists"]]}
    base = Wing([Element.from_dict(e) for e in first["elements"]], min_gap=float(p.get("min_gap", 0.005)),
                rules_box=box, ground_frame=True, free_air=bool(p.get("free_air", False)))
    # Its ride height is where it sits. A wing laid out from scratch starts halfway up the room the box
    # leaves it, not on the floor: a big main 30 mm off the ground separates, and the search starts lost.
    base = apply(base, {} if first.get("from_canvas") else {"yfrac_0": 0.5})
    if not saved.exists():
        storage.parent.mkdir(parents=True, exist_ok=True)
        saved.write_text(_json.dumps({**first, "signature": signature}))
    if p.get("variables"):
        var = [Variable(int(v["element"]), str(v["kind"]), float(v["low"]), float(v["high"]),
                       tuple(str(k) for k in v.get("choices") or ())) for v in p["variables"]]
    else:
        var = default_variables(base, first["shortlists"], box=box)
    wanted = sorted({k for v in var if v.kind == "airfoil" for k in v.choices})
    sections = units(root, wanted) if wanted else None
    ref = sum(e.chord for e in base.elements)
    car = optimise.CarScore(
        span=float(p.get("span", 1.0)), endplate=None if p.get("endplate") is None else float(p["endplate"]),
        factor=float(p.get("factor", 1.0)), ref_chord=ref,
        base=(float(car_raw["base_cla"]), float(car_raw["base_cda"]), float(car_raw["base_rear_cla"])) if car_raw else None,
        axles=(float(car_raw["axle_front"]), float(car_raw["axle_rear"])) if car_raw else None,
        cda_cap=None if p.get("cda_cap") is None else float(p["cda_cap"]),
        rear_target=None if p.get("rear_target") is None else float(p["rear_target"]))
    checks = int(p.get("checks", 3))
    study_p = {**{k: v for k, v in p.items() if k not in ("variables", "start", "box", "car")}, **flow,
               "objective": goal, "solver": "estimate", "check": checks, "until_pass": False,
               # No calibration run: it meshes in a thread beside the study, and gmsh started again on the
               # main thread for the checks then crashes (in its OpenMP start-up); the app's Study runs none either.
               "anchor": False, "ref_chord": ref, "ride_height": base.ride_height,
               "storage": str(storage), "name": name}
    out, spec = _study(ctx, study_p, base, var, sections, car=car, span=(10.0, 100.0))

    def where(params: dict) -> dict:
        w = apply(base, *optimise.resolve(spec, params)[:2])
        return {"ride_height": w.ride_height, "x": float(min(e.placed()[:, 0].min() for e in w.elements))}

    trials = {t["number"]: t for t in out["trials"]}
    keep = ("cla", "cda", "cla_cda", "car_cla", "car_cda", "rear_share")
    finalists = []
    if checks:
        for c in out["checks"]:
            t = trials.get(c["number"])
            if t is None:
                continue
            held = c.get("value") is not None and c.get("feasible", True)
            src = c if held else t
            finalists.append({"number": c["number"], "params": t["params"], "estimate_value": t["value"],
                              **{k: src.get(k) for k in keep}, "from": "RANS" if held else "estimate",
                              **where(t["params"]),
                              "rans": {k: c.get(k) for k in ("cl", "cd", "converged", "separated", "reason", "value",
                                                             "feasible")}})
        order = {c["number"]: i for i, c in enumerate(rank_finalists(out["checks"], spec.direction))}
        finalists.sort(key=lambda f: order.get(f["number"], len(order)))
    else:
        good = sorted((t for t in out["trials"] if t["state"] == "complete" and t["feasible"]),
                      key=lambda t: t["value"], reverse=spec.direction == "maximize")
        for t in good[:FINALISTS]:
            finalists.append({"number": t["number"], "params": t["params"], "estimate_value": t["value"],
                              **{k: t.get(k) for k in keep}, "from": "estimate", **where(t["params"]), "rans": None})
    shown = [{**e, "coords": Element.from_dict(e).placed().tolist()} for e in first["elements"]]
    for e, b in zip(shown, base.elements):  # where the base wing sits now (moved to its ride height)
        e["leading_edge"], e["coords"] = b.leading_edge.tolist(), b.placed().tolist()
    return {"base": {"elements": shown, "ride_height": base.ride_height}, "study": out, "finalists": finalists,
            "goal": goal, "box": list(box)}


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
