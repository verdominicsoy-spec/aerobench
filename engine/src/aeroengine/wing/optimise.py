"""Gap, overlap and angle optimisation of a multi-element wing with Optuna.

Each trial builds the wing from the design values (geometry.apply), checks
it (intersections, minimum gap, rules box), then runs it through RANS.
A wing that breaks a constraint is not run: the sampler is told it scored
far worse than anything real (so it learns to stay away, which it would not
from a failed trial), it is marked invalid, and it does not count towards
the trial total. Trials whose mesh fails, or whose run diverges or does not
converge, are recorded as failed with the reason; the study carries on. The study lives in an Optuna SQLite file, so it resumes where it
stopped; after every trial a JSON export of all trials is written beside it
for the app to read."""

from __future__ import annotations

import json
import shutil
import threading
import time
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import numpy as np
import optuna

from ..job import EngineError
from .geometry import Variable, Wing, apply

OBJECTIVES = {
    "max_cla": "Most downforce (ClA)",
    "max_efficiency": "Best efficiency (ClA/CdA)",
    "max_cla_cda_cap": "Most downforce under a drag limit",
    "balance": "Hit an aero balance",
    "max_cl": "Most downforce (lift, upright)",
    "max_ld": "Best L/D",
    "max_cl_cd_cap": "Most downforce under a drag cap",
    "min_cd_cl_target": "Least drag for a downforce target",
    "min_lap_time": "Fastest lap",
}
# Constraint penalty: 10 % past a cap or short of a target costs 1 in Cl
# (or 10 % in Cd). The sampler steers away; feasible says which trials hold.
PENALTY = 10.0
INVALID = 1e6  # what a wing that breaks a constraint scores (negated when maximising)
DISTINCT = 0.05  # of a variable's range: how far apart two checked designs must be in at least one


@dataclass
class LapScore:
    """For the fastest-lap objective: the Lap Sim's car with this wing in
    place of the one it replaces, around one track. A lap takes about 10 ms,
    so every trial gets its own lap rather than a linearised guess."""
    car: object  # lapsim.Car, the car as it is (with the wing being replaced)
    track: object  # lapsim.Track
    span: float  # m
    chord: float  # m, the wing's total chord (its reference)
    endplate: float | None  # m; None: use the typed 3D factor
    factor: float = 1.0
    replaced_cla: float = 0.0
    replaced_cda: float = 0.0
    start_speed: float = 0.0

    def lap_time(self, load: float, cd: float, chord: float | None = None) -> float:
        """chord: the trial's total chord (coefficients stay on self.chord, the reference)."""
        from dataclasses import replace as _replace

        from ..lapsim import simulate
        from .finite import car_contribution

        c = chord or self.chord
        cla, cda = car_contribution(-load * self.chord / c, cd * self.chord / c, self.span, c, self.endplate, self.factor)
        car = _replace(self.car, cla=max(self.car.cla - self.replaced_cla + cla, 0.0),
                       cda=max(self.car.cda - self.replaced_cda + cda, 0.0))
        return simulate(car, self.track, self.start_speed).lap_time


@dataclass
class CarScore:
    """The wing in car terms for the goals in ClA: span and 3D settings, and,
    with a base car, the base car with the other end's wing (ClA, CdA and the
    ClA on the rear axle) and the axles in the design frame (m downstream)."""
    span: float
    endplate: float | None
    factor: float
    ref_chord: float | None  # what the coefficients are on; None: the wing's own total chord
    base: tuple[float, float, float] | None
    axles: tuple[float, float] | None
    cda_cap: float | None = None
    rear_target: float | None = None

    def wing(self, load: float, cd: float, wing: Wing) -> tuple[float, float, float]:
        """ClA and CdA of this wing on its own total chord, and its centre of pressure
        (the quarter chord behind its most upstream point, m in the design frame)."""
        from .finite import car_contribution

        c = sum(e.chord for e in wing.elements)
        ref = self.ref_chord or c
        cla, cda = car_contribution(-load * ref / c, cd * ref / c, self.span, c, self.endplate, self.factor)
        front = min(float(e.placed()[:, 0].min()) for e in wing.elements)
        return cla, cda, front + c / 4

    def numbers(self, load: float, cd: float, wing: Wing) -> dict:
        """What a trial shows: the wing's, and the car's with a base."""
        cla, cda, xcp = self.wing(load, cd, wing)
        out = {"cla": cla, "cda": cda, "cla_cda": cla / cda if cda > 0 else None}
        if self.base is not None:
            total, drag = self.base[0] + cla, self.base[1] + cda
            out.update(car_cla=total, car_cda=drag)
            if self.axles is not None and abs(total) > 1e-9:
                xf, xr = self.axles
                out["rear_share"] = (self.base[2] + cla * (xcp - xf) / (xr - xf)) / total
        return out


@dataclass
class Spec:
    variables: list[Variable]
    objective: str = "max_cl"
    cd_cap: float | None = None
    cl_target: float | None = None
    sampler: str = "tpe"  # or "cmaes"
    trials: int = 40  # in total, counting trials from earlier sessions of the study
    parallel: int = 1
    seed: int | None = None
    solver: str = "rans"  # what each trial is: "rans" (SU2) or "estimate" (panel method and NeuralFoil)
    lap: LapScore | None = None  # for min_lap_time
    # Unit coordinates of every section a section variable can choose, by key.
    sections: dict[str, np.ndarray] | None = None
    car: CarScore | None = None  # for the goals in car terms

    def __post_init__(self) -> None:
        if self.objective not in OBJECTIVES:
            raise EngineError(f"unknown objective '{self.objective}'", f"one of {', '.join(OBJECTIVES)}")
        if self.objective == "max_cl_cd_cap" and not (self.cd_cap and self.cd_cap > 0):
            raise EngineError("the drag cap objective needs a Cd cap above zero")
        if self.objective == "min_cd_cl_target" and not (self.cl_target and self.cl_target > 0):
            raise EngineError("the downforce target objective needs a target Cl above zero")
        if self.objective in ("max_cla", "max_efficiency", "max_cla_cda_cap", "balance") and self.car is None:
            raise EngineError(f"the {self.objective} goal needs the wing's span and 3D settings")
        if self.objective == "max_cla_cda_cap" and not (self.car and self.car.cda_cap and self.car.cda_cap > 0):
            raise EngineError("the drag limit goal needs a CdA limit above zero")
        if self.objective == "balance" and not (self.car and self.car.base and self.car.axles
                                                and self.car.rear_target is not None):
            raise EngineError("the balance goal needs a base car (with its axles) and a rear share to aim for")
        if self.objective == "min_lap_time" and self.lap is None:
            raise EngineError("the fastest-lap objective needs a car and a track")
        if self.solver not in ("rans", "estimate"):
            raise EngineError("solver must be rans or estimate")
        if self.sampler not in ("tpe", "cmaes"):
            raise EngineError("sampler must be tpe or cmaes")
        if not self.variables:
            raise EngineError("tick at least one design variable")
        for v in self.variables:
            if v.kind not in ("angle", "gap", "overlap", "chord", "airfoil", "camber", "thickness", "height", "x"):
                raise EngineError(f"unknown design variable '{v.kind}'")
            if v.kind == "airfoil":
                if len(v.choices) < 2:
                    raise EngineError(f"{v.name}: a section variable needs two or more sections to choose from")
                missing = [k for k in v.choices if not self.sections or k not in self.sections]
                if missing:
                    raise EngineError(f"{v.name}: no coordinates for {', '.join(missing[:3])}")
                v.low, v.high = 0.0, float(len(v.choices) - 1)
            if v.kind == "chord" and v.low <= 0:
                raise EngineError(f"{v.name}: a chord must stay above zero")
            if v.kind == "thickness" and v.low <= 0:
                raise EngineError(f"{v.name}: the thickness scale must stay above zero")
            if v.kind == "height" and v.low <= 0:
                raise EngineError(f"{v.name}: the ride height must stay above the ground")
            if not v.high > v.low:
                raise EngineError(f"{v.name}: the upper bound must be above the lower")
            if v.kind == "gap" and v.low < 0:
                raise EngineError(f"{v.name}: a gap cannot be negative")

    @property
    def direction(self) -> str:
        return "minimize" if self.objective in ("min_cd_cl_target", "min_lap_time") else "maximize"


def score(spec: Spec, load: float, cd: float, wing: Wing | None = None) -> tuple[float, bool]:
    """The value the sampler sees and whether the trial meets the constraint.
    load is Cl in the working direction: downforce for an inverted wing. The
    goals in car terms need the trial's wing (its chord and place)."""
    if spec.objective in ("max_cla", "max_efficiency", "max_cla_cda_cap", "balance"):
        if wing is None:
            raise EngineError(f"the {spec.objective} goal scores a wing, not bare coefficients")
        car = spec.car
        n = car.numbers(load, cd, wing)  # type: ignore[union-attr]
        cla = n["cla"]
        if spec.objective == "max_cla":
            return cla, True
        if spec.objective == "max_efficiency":
            total, drag = n.get("car_cla", cla), n.get("car_cda", n["cda"])
            return total / max(drag, 1e-9), True
        if spec.objective == "max_cla_cda_cap":
            over = max(0.0, n.get("car_cda", n["cda"]) / car.cda_cap - 1)  # type: ignore[union-attr,operator]
            return cla - PENALTY * over, over == 0
        share = n.get("rear_share")
        off = 1.0 if share is None else max(0.0, abs(share - car.rear_target) - 0.01)  # type: ignore[union-attr,operator]
        return cla - PENALTY * off, off == 0
    if spec.objective == "max_cl":
        return load, True
    if spec.objective == "max_ld":
        return load / max(cd, 1e-9), True
    if spec.objective == "min_lap_time":
        chord = sum(e.chord for e in wing.elements) if wing is not None else None
        return spec.lap.lap_time(load, cd, chord), True  # type: ignore[union-attr]
    if spec.objective == "max_cl_cd_cap":
        over = max(0.0, cd / spec.cd_cap - 1)  # type: ignore[operator]
        return load - PENALTY * over, over == 0
    short = max(0.0, 1 - load / spec.cl_target)  # type: ignore[operator]
    return cd * (1 + PENALTY * short), short == 0


def resolve(spec: Spec, values: dict) -> tuple[dict[str, float], dict[int, np.ndarray], dict[int, str]]:
    """A trial's values split into the numbers apply() takes, the sections
    its section variables chose (unit coordinates by element) and their keys."""
    numbers, units, keys = {}, {}, {}
    for v in spec.variables:
        if v.name not in values:
            continue
        if v.kind == "airfoil":
            key = v.choices[int(round(values[v.name]))]
            units[v.element], keys[v.element] = spec.sections[key], key  # type: ignore[index]
        else:
            numbers[v.name] = float(values[v.name])
    return numbers, units, keys


def _sampler(spec: Spec, done: int = 0) -> optuna.samplers.BaseSampler:
    # A resumed study must not replay the proposals of the session before:
    # with a fixed seed it would, so the seed moves on by the trials so far.
    seed = None if spec.seed is None else spec.seed + done
    if spec.sampler == "cmaes":
        # CMA-ES needs two or more variables; with one it samples at random.
        return optuna.samplers.CmaEsSampler(seed=seed, warn_independent_sampling=False)
    return optuna.samplers.TPESampler(seed=seed, constant_liar=spec.parallel > 1, n_startup_trials=8)


Evaluate = Callable[[Wing, Path], dict]


def run(base: Wing, spec: Spec, evaluate: Evaluate, storage: Path, name: str, workroot: Path,
        progress: Callable[[float, str], None] = lambda p, m: None, log: Callable[..., None] = lambda *a, **k: None,
        keep_runs: bool = False, info: dict | None = None) -> dict:
    """Runs (or resumes) the study until it holds spec.trials finished trials.
    evaluate(wing, folder) returns at least cl, cd, converged and reason, or
    raises EngineError; one call per trial, up to spec.parallel at once."""
    optuna.logging.set_verbosity(optuna.logging.WARNING)
    storage.parent.mkdir(parents=True, exist_ok=True)
    rdb = optuna.storages.RDBStorage(f"sqlite:///{storage}", engine_kwargs={"connect_args": {"timeout": 60}})
    study = optuna.create_study(study_name=name, storage=rdb, direction=spec.direction, sampler=_sampler(spec),
                                load_if_exists=True)
    if study.trials:
        study.sampler = _sampler(spec, len(study.trials))
    old = study.user_attrs.get("spec")
    now = _spec_dict(spec)
    if old and (old["variables"] != now["variables"] or old["objective"] != now["objective"]
                or old.get("solver", "rans") != now["solver"]):
        raise EngineError(f"study '{name}' was started with other design variables, another objective or another solver",
                          "start a new study for a different set-up")
    study.set_user_attr("spec", now)
    if info:
        study.set_user_attr("info", info)
    # Shape trials store only camber and thickness relative to the sections the
    # study started from, so those go with the study (once: a resume keeps them).
    if any(v.kind in ("camber", "thickness") for v in spec.variables) and "base_sections" not in study.user_attrs:
        study.set_user_attr("base_sections", [np.round(e.unit, 6).tolist() for e in base.elements])
    inverted = base.elements[0].inverted
    # A section is a choice, not a number on a scale: categorical, by index.
    dists = {v.name: optuna.distributions.CategoricalDistribution(list(range(len(v.choices)))) if v.kind == "airfoil"
             else optuna.distributions.FloatDistribution(v.low, v.high) for v in spec.variables}

    # Trials an earlier session left running were cut off: mark them, and
    # queue the same values again. They do not count towards the total.
    for t in study.get_trials(deepcopy=False, states=(optuna.trial.TrialState.RUNNING,)):
        rdb.set_trial_user_attr(t._trial_id, "reason", "interrupted")
        rdb.set_trial_state_values(t._trial_id, optuna.trial.TrialState.FAIL)
        if set(t.params) == set(dists):
            study.enqueue_trial(t.params)
    if not study.trials:
        # Start from the wing as drawn, when it lies inside the bounds.
        start = _current(base, spec.variables)
        if all(v.low <= start[v.name] <= v.high for v in spec.variables):
            study.enqueue_trial(start)

    lock = threading.Lock()
    stop = threading.Event()
    export = storage.with_suffix(".json")

    def counts() -> tuple[int, int]:
        """Trials that count towards the total (run, or failed trying), and invalid wings."""
        run_, invalid = 0, 0
        for t in study.get_trials(deepcopy=False):
            if t.user_attrs.get("invalid"):
                invalid += 1
            elif t.state.is_finished() and t.user_attrs.get("reason") != "interrupted":
                run_ += 1
        return run_, invalid

    def finished() -> int:
        return counts()[0]

    give_up = max(50, 5 * spec.trials)  # invalid wings in one session before deciding the bounds hold none

    def one() -> None:
        with lock:
            if stop.is_set() or finished() + len(study.get_trials(deepcopy=False, states=(optuna.trial.TrialState.RUNNING,))) >= spec.trials:
                return
            trial = study.ask(dists)
            values = dict(trial.params)
        folder = workroot / f"trial_{trial.number:04d}"
        t0 = time.time()
        attrs: dict = {}
        state, value = optuna.trial.TrialState.FAIL, None
        try:
            numbers, units, keys = resolve(spec, values)
            wing = apply(base, numbers, units)
            if keys:
                attrs["airfoils"] = {str(i): k for i, k in keys.items()}
            attrs["chords"] = [e.chord for e in wing.elements]
            attrs["placement"] = [{"angle": e.angle, "leading_edge": e.leading_edge.tolist()} for e in wing.elements]
            attrs["gaps"] = [wing.gap(i) for i in range(1, len(wing.elements))]
            attrs["overlaps"] = [wing.overlap(i) for i in range(1, len(wing.elements))]
            problems = wing.issues()
            if problems:
                attrs.update(reason="; ".join(problems), invalid=True, feasible=False)
                state, value = optuna.trial.TrialState.COMPLETE, -INVALID if spec.direction == "maximize" else INVALID
            else:
                folder.mkdir(parents=True, exist_ok=True)
                res = evaluate(wing, folder)
                load = -res["cl"] if inverted else res["cl"]
                attrs.update(cl=res["cl"], cd=res["cd"], cm=res.get("cm"), load=load,
                             element_cl=[e.get("cl") for e in res.get("elements", [])],
                             converged=bool(res["converged"]), iterations=res.get("iterations"),
                             cells=(res.get("mesh") or {}).get("cells"))
                if res.get("scheme", "jst") != "jst":
                    # Its drag is on another scheme's footing: not comparable with the rest.
                    attrs["reason"] = "ran only on the upwind fallback scheme, whose drag is not comparable"
                elif res["converged"]:
                    value, feasible = score(spec, load, res["cd"], wing)
                    attrs["feasible"] = feasible
                    if spec.car is not None:
                        attrs.update(spec.car.numbers(load, res["cd"], wing))
                    state = optuna.trial.TrialState.COMPLETE
                else:
                    attrs.update(reason=f"not converged: {res.get('reason')}", unsettled=True)
        except EngineError as exc:
            attrs["reason"] = exc.msg + (f": {exc.detail.splitlines()[-1]}" if exc.detail else "")
        except Exception as exc:  # noqa: BLE001 - one bad trial must not end an overnight study
            attrs["reason"] = f"{type(exc).__name__}: {exc}"
        finally:
            if not keep_runs:
                shutil.rmtree(folder, ignore_errors=True)
        attrs["seconds"] = round(time.time() - t0, 1)
        if stop.is_set() and state is optuna.trial.TrialState.FAIL and not attrs.get("invalid"):
            return  # cut off by a cancel: left running, re-queued when the study resumes
        with lock:
            if attrs.get("unsettled"):
                # A run that never settles is nearly always separated flow: a
                # poor wing. Once there are two real results to measure by, it
                # is told to the sampler as half their spread below the worst
                # (a failed trial would teach it nothing); shown as failed,
                # never as a result.
                real = [t.value for t in study.get_trials(deepcopy=False, states=(optuna.trial.TrialState.COMPLETE,))
                        if not t.user_attrs.get("invalid") and not t.user_attrs.get("unsettled")]
                if len(real) >= 2:
                    worst, best = (min(real), max(real)) if spec.direction == "maximize" else (max(real), min(real))
                    state = optuna.trial.TrialState.COMPLETE
                    value = worst - 0.5 * (best - worst)
            for k, v in attrs.items():
                trial.set_user_attr(k, v)
            study.tell(trial, value, state=state)
            done = finished()
            _export(study, spec, export)
        if attrs.get("invalid"):
            return  # no log line or progress for a wing that was never run
        ok = value is not None and not attrs.get("unsettled")
        what = f"{value:.4g}" if ok else f"failed ({attrs.get('reason', '')})"
        log(f"trial {trial.number}: {what}", level="info" if ok else "warning")
        progress(100 * done / spec.trials, f"{done} of {spec.trials} trials")

    invalid_before = counts()[1]
    _export(study, spec, export)
    progress(100 * finished() / spec.trials, f"{finished()} of {spec.trials} trials")
    pool = ThreadPoolExecutor(max_workers=spec.parallel)
    running: set = set()
    try:
        while True:
            while len(running) < spec.parallel and finished() + len(running) < spec.trials:
                running.add(pool.submit(one))
            if not running:
                break
            done, running = wait(running, timeout=1.0, return_when=FIRST_COMPLETED)
            for f in done:
                f.result()
            if counts()[1] - invalid_before >= give_up:
                raise EngineError(f"{give_up} wings broke a constraint before {spec.trials} could be run",
                                  "the bounds hold almost no valid wing: check the minimum gap, the rules box "
                                  "and the gap and overlap ranges")
    except BaseException:
        # Cancelled (or a storage error): stop the solvers still running so
        # their threads return now (their trials are re-run on resume).
        stop.set()
        if running:
            _stop_children()
        raise
    finally:
        stop.set()
        pool.shutdown(wait=True, cancel_futures=True)
    _export(study, spec, export)
    return summary(study, spec)


def _stop_children() -> None:
    """Ends the solvers this engine started (they share its process group).
    The engine itself ignores SIGTERM by now: the cancel handler set that."""
    import os
    import signal

    if signal.getsignal(signal.SIGTERM) is not signal.SIG_IGN:
        return  # not the engine's cancel path (a test, a storage error): leave the group alone
    try:
        os.killpg(os.getpgid(0), signal.SIGTERM)
    except OSError:
        pass


def _current(base: Wing, variables: list[Variable]) -> dict[str, float]:
    out = {}
    for v in variables:
        if v.kind == "angle":
            out[v.name] = base.elements[v.element].angle
        elif v.kind == "gap":
            out[v.name] = base.gap(v.element)
        elif v.kind == "overlap":
            out[v.name] = base.overlap(v.element)
        elif v.kind == "height":
            out[v.name] = base.ride_height if base.ride_height is not None else v.low
        elif v.kind == "chord":
            out[v.name] = base.elements[v.element].chord
        elif v.kind == "airfoil":
            out[v.name] = 0  # the element's own section is the first choice
        else:  # the drawn shape: no camber added, thickness as it is
            out[v.name] = 0.0 if v.kind == "camber" else 1.0
    return out


def _spec_dict(spec: Spec) -> dict:
    return {"variables": [{"element": v.element, "kind": v.kind, "low": v.low, "high": v.high,
                           **({"choices": list(v.choices)} if v.choices else {})} for v in spec.variables],
            "objective": spec.objective, "cd_cap": spec.cd_cap, "cl_target": spec.cl_target, "sampler": spec.sampler,
            "solver": spec.solver}


def summary(study: optuna.Study, spec: Spec) -> dict:
    trials = []
    for t in study.get_trials(deepcopy=False):
        a = t.user_attrs
        state = "invalid" if a.get("invalid") else "fail" if a.get("unsettled") else t.state.name.lower()
        trials.append({"number": t.number, "state": state, "value": t.value if state == "complete" else None,
                       "params": t.params,
                       **{k: a.get(k) for k in ("cl", "cd", "cm", "load", "element_cl", "feasible", "converged",
                                                "reason", "placement", "gaps", "overlaps", "chords", "airfoils",
                                                "seconds", "iterations", "cells", "cla", "cda", "cla_cda",
                                                "car_cla", "car_cda", "rear_share", "ride_height", "x")}})
    good = [t for t in trials if t["state"] == "complete" and t["feasible"]]
    best = None
    if good:
        pick = min if spec.direction == "minimize" else max
        best = pick(good, key=lambda t: t["value"])["number"]
    return {"study": study.study_name, "objective": spec.objective, "objective_name": OBJECTIVES[spec.objective],
            "direction": spec.direction, "spec": _spec_dict(spec), "info": study.user_attrs.get("info"),
            "trials": trials, "best": best, "complete": sum(t["state"] == "complete" for t in trials),
            "failed": sum(t["state"] == "fail" for t in trials),
            "invalid": sum(t["state"] == "invalid" for t in trials), "target": spec.trials,
            "solver": spec.solver, "checks": study.user_attrs.get("checks", []),
            "anchor": study.user_attrs.get("anchor"),
            "base_sections": study.user_attrs.get("base_sections")}


def check(base: Wing, spec: Spec, storage: Path, name: str, evaluate: Evaluate, count: int, workroot: Path,
          progress: Callable[[float, str], None] = lambda p, m: None, log: Callable[..., None] = lambda *a, **k: None,
          scale: tuple[float, float] = (1.0, 1.0), until_pass: bool = False) -> dict:
    """Runs the best `count` designs of a study again with `evaluate` (RANS
    after a quick-estimate study) and records what it says beside them, so
    the ranking can be checked where the estimate is least sure. `scale`
    multiplies each trial's lift and drag before ranking: the estimate's
    calibration against a RANS run of the same wing family. until_pass:
    stop at the first design RANS confirms (the next is only a fallback)."""
    optuna.logging.set_verbosity(optuna.logging.WARNING)
    rdb = optuna.storages.RDBStorage(f"sqlite:///{storage}", engine_kwargs={"connect_args": {"timeout": 60}})
    study = optuna.load_study(study_name=name, storage=rdb)
    inverted = base.elements[0].inverted
    s = summary(study, spec)
    good = [t for t in s["trials"] if t["state"] == "complete" and t["feasible"]]

    def ranked(t: dict) -> float:
        if scale == (1.0, 1.0) or t.get("load") is None or t.get("cd") is None:
            return t["value"]
        wing = apply(base, *resolve(spec, t["params"])[:2]) if spec.car is not None else None
        return score(spec, t["load"] * scale[0], t["cd"] * scale[1], wing)[0]

    good.sort(key=ranked, reverse=spec.direction == "maximize")
    # Distinct designs only: each pick differs from every earlier one by at
    # least DISTINCT of some variable's range. The top of a converged study is
    # one design many times over (two picks a hundredth of a degree apart
    # cost two RANS runs and say the same thing).
    spans = {v.name: v.high - v.low for v in spec.variables}

    def apart(a: dict, b: dict) -> bool:
        return any(abs(a["params"][k] - b["params"].get(k, a["params"][k])) >= DISTINCT * spans.get(k, 0.0)
                   for k in a["params"] if spans.get(k))

    picked: list[dict] = []
    for t in good:
        if all(apart(t, p) for p in picked):
            picked.append(t)
        if len(picked) == count:
            break
    done = {c["number"]: c for c in study.user_attrs.get("checks", [])}
    for k, t in enumerate(picked):
        if until_pass and any(done.get(p["number"], {}).get("value") is not None for p in picked[:k]):
            break  # one design held in RANS: that is the answer
        progress(100 * k / max(len(picked), 1), f"checking trial {t['number']} ({k + 1} of {len(picked)})")
        if t["number"] in done:
            continue
        folder = workroot / f"check_{t['number']:04d}"
        folder.mkdir(parents=True, exist_ok=True)
        rec: dict = {"number": t["number"], "estimate_value": t["value"]}
        try:
            wing = apply(base, *resolve(spec, t["params"])[:2])
            res = evaluate(wing, folder)
            load = -res["cl"] if inverted else res["cl"]
            rec.update(cl=res["cl"], cd=res["cd"], load=load, converged=bool(res["converged"]), reason=res.get("reason"))
            if res["converged"] and res.get("scheme", "jst") == "jst":
                rec["value"], rec["feasible"] = score(spec, load, res["cd"], wing)
                if spec.car is not None:
                    rec.update(spec.car.numbers(load, res["cd"], wing))
        except EngineError as exc:
            rec.update(converged=False, reason=exc.msg)
        finally:
            shutil.rmtree(folder, ignore_errors=True)
        done[t["number"]] = rec
        study.set_user_attr("checks", list(done.values()))
        _export(study, spec, storage.with_suffix(".json"))
        what = f"{rec['value']:.4g}" if rec.get("value") is not None else f"failed ({rec.get('reason')})"
        log(f"check of trial {t['number']}: estimate {t['value']:.4g}, RANS {what}")
    _export(study, spec, storage.with_suffix(".json"))
    return summary(study, spec)


def record_anchor(storage: Path, name: str, spec: Spec, anchor: dict) -> None:
    """Keeps the calibration run with the study, for the export."""
    rdb = optuna.storages.RDBStorage(f"sqlite:///{storage}", engine_kwargs={"connect_args": {"timeout": 60}})
    study = optuna.load_study(study_name=name, storage=rdb)
    study.set_user_attr("anchor", anchor)
    _export(study, spec, storage.with_suffix(".json"))


def _export(study: optuna.Study, spec: Spec, path: Path) -> None:
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(summary(study, spec), default=_plain))
    tmp.replace(path)


def _plain(o):
    if isinstance(o, np.generic):
        return o.item()
    if isinstance(o, np.ndarray):
        return o.tolist()
    return str(o)
