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
    "max_cl": "Most downforce (lift, upright)",
    "max_ld": "Best L/D",
    "max_cl_cd_cap": "Most downforce under a drag cap",
    "min_cd_cl_target": "Least drag for a downforce target",
}
# Constraint penalty: 10 % past a cap or short of a target costs 1 in Cl
# (or 10 % in Cd). The sampler steers away; feasible says which trials hold.
PENALTY = 10.0
INVALID = 1e6  # what a wing that breaks a constraint scores (negated when maximising)


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

    def __post_init__(self) -> None:
        if self.objective not in OBJECTIVES:
            raise EngineError(f"unknown objective '{self.objective}'", f"one of {', '.join(OBJECTIVES)}")
        if self.objective == "max_cl_cd_cap" and not (self.cd_cap and self.cd_cap > 0):
            raise EngineError("the drag cap objective needs a Cd cap above zero")
        if self.objective == "min_cd_cl_target" and not (self.cl_target and self.cl_target > 0):
            raise EngineError("the downforce target objective needs a target Cl above zero")
        if self.sampler not in ("tpe", "cmaes"):
            raise EngineError("sampler must be tpe or cmaes")
        if not self.variables:
            raise EngineError("tick at least one design variable")
        for v in self.variables:
            if v.kind not in ("angle", "gap", "overlap"):
                raise EngineError(f"unknown design variable '{v.kind}'")
            if not v.high > v.low:
                raise EngineError(f"{v.name}: the upper bound must be above the lower")
            if v.kind == "gap" and v.low < 0:
                raise EngineError(f"{v.name}: a gap cannot be negative")

    @property
    def direction(self) -> str:
        return "minimize" if self.objective == "min_cd_cl_target" else "maximize"


def score(spec: Spec, load: float, cd: float) -> tuple[float, bool]:
    """The value the sampler sees and whether the trial meets the constraint.
    load is Cl in the working direction: downforce for an inverted wing."""
    if spec.objective == "max_cl":
        return load, True
    if spec.objective == "max_ld":
        return load / max(cd, 1e-9), True
    if spec.objective == "max_cl_cd_cap":
        over = max(0.0, cd / spec.cd_cap - 1)  # type: ignore[operator]
        return load - PENALTY * over, over == 0
    short = max(0.0, 1 - load / spec.cl_target)  # type: ignore[operator]
    return cd * (1 + PENALTY * short), short == 0


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
    if old and (old["variables"] != now["variables"] or old["objective"] != now["objective"]):
        raise EngineError(f"study '{name}' was started with other design variables or another objective",
                          "start a new study for a different set-up")
    study.set_user_attr("spec", now)
    if info:
        study.set_user_attr("info", info)
    inverted = base.elements[0].inverted
    dists = {v.name: optuna.distributions.FloatDistribution(v.low, v.high) for v in spec.variables}

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
            wing = apply(base, values)
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
                    value, feasible = score(spec, load, res["cd"])
                    attrs["feasible"] = feasible
                    state = optuna.trial.TrialState.COMPLETE
                else:
                    attrs["reason"] = f"not converged: {res.get('reason')}"
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
            for k, v in attrs.items():
                trial.set_user_attr(k, v)
            study.tell(trial, value, state=state)
            done = finished()
            _export(study, spec, export)
        if attrs.get("invalid"):
            return  # no log line or progress for a wing that was never run
        what = f"{value:.4g}" if value is not None else f"failed ({attrs.get('reason', '')})"
        log(f"trial {trial.number}: {what}", level="info" if value is not None else "warning")
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
        else:
            out[v.name] = base.overlap(v.element)
    return out


def _spec_dict(spec: Spec) -> dict:
    return {"variables": [{"element": v.element, "kind": v.kind, "low": v.low, "high": v.high} for v in spec.variables],
            "objective": spec.objective, "cd_cap": spec.cd_cap, "cl_target": spec.cl_target, "sampler": spec.sampler}


def summary(study: optuna.Study, spec: Spec) -> dict:
    trials = []
    for t in study.get_trials(deepcopy=False):
        a = t.user_attrs
        state = "invalid" if a.get("invalid") else t.state.name.lower()
        trials.append({"number": t.number, "state": state, "value": None if state == "invalid" else t.value,
                       "params": t.params,
                       **{k: a.get(k) for k in ("cl", "cd", "cm", "load", "element_cl", "feasible", "converged",
                                                "reason", "placement", "gaps", "overlaps", "seconds", "iterations",
                                                "cells")}})
    good = [t for t in trials if t["state"] == "complete" and t["feasible"]]
    best = None
    if good:
        pick = min if spec.direction == "minimize" else max
        best = pick(good, key=lambda t: t["value"])["number"]
    return {"study": study.study_name, "objective": spec.objective, "objective_name": OBJECTIVES[spec.objective],
            "direction": spec.direction, "spec": _spec_dict(spec), "info": study.user_attrs.get("info"),
            "trials": trials, "best": best, "complete": sum(t["state"] == "complete" for t in trials),
            "failed": sum(t["state"] == "fail" for t in trials),
            "invalid": sum(t["state"] == "invalid" for t in trials), "target": spec.trials}


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
