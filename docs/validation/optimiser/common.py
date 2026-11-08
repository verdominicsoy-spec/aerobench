"""Shared helpers for the optimiser audit: saved jobs and studies, the
estimate exactly as a study trial calls it, and rank statistics.

Run the scripts from engine/ so the engine's environment is used:
    cd engine && uv run python ../docs/validation/optimiser/<script>.py
Nothing here runs RANS."""

from __future__ import annotations

import json
import os
from pathlib import Path

import numpy as np
from scipy.stats import spearmanr

from aeroengine.wing.airfoils import data_dir
from aeroengine.wing.estimate import MAX_DEFLECTION, estimate
from aeroengine.wing.geometry import Element, Wing, apply

SCRATCH = Path(os.path.expanduser("~/Library/Application Support/AeroBench/Scratch"))
JOBS = SCRATCH / "jobs"
STUDIES = SCRATCH / "wing" / "studies"
HERE = Path(__file__).resolve().parent


def jobs(command: str | None = None) -> list[tuple[str, dict, dict | None]]:
    """(id, params, result data or None) of every saved job, oldest first."""
    out = []
    for d in sorted(JOBS.iterdir()):
        try:
            j = json.loads((d / "job.json").read_text())
        except (OSError, ValueError):
            continue
        if command and j.get("command") != command:
            continue
        data = None
        if (d / "result.json").exists():
            try:
                data = json.loads((d / "result.json").read_text()).get("data")
            except ValueError:
                pass
        out.append((d.name, j.get("params", {}), data if isinstance(data, dict) else None))
    return out


def elements_of(wing: Wing) -> list[dict]:
    """As commands/wing.py _study.elements_of."""
    return [{"coords": e.placed().tolist(), "unit": e.unit.tolist(), "angle": e.angle, "inverted": e.inverted,
             "chord": e.chord} for e in wing.elements]


def trial_row(wing: Wing, p: dict) -> dict:
    """The estimate row a study trial sees: the call in commands/wing.py
    _study.evaluate_estimate (same arguments)."""
    return estimate(elements_of(wing), [float(p.get("alpha", 0.0))], float(p.get("speed", 15)),
                    float(p.get("rho", 1.225)), float(p.get("mu", 1.81e-5)), float(p.get("n_crit", 9.0)),
                    p.get("ref_chord"), stall_margin=float(p.get("stall_margin", 2.0)),
                    ride_height=wing.ride_height)["rows"][0]


def flags(row: dict, angles: list[float]) -> dict:
    """What the estimate itself says about how far to trust a row (angles: the elements', in order)."""
    els = row["elements"]
    past_main = max((a - angles[0] for a in angles[1:]), default=None)
    step = max((angles[i] - angles[i - 1] for i in range(1, len(angles))), default=None)
    worst = max(([past_main] if past_main is not None else []) + ([step] if step is not None else []), default=None)
    front = els[:-1]
    return {
        "separating": row["separating"],
        "trusted": row["trusted"],
        "min_confidence": min(e["confidence"] for e in els),
        "deflection_margin": None if worst is None else MAX_DEFLECTION - worst,  # degrees left before the cliff
        # How far each front element sits past its own (NeuralFoil) stall angle in place.
        "front_past_stall": max((e["effective_angle"] - e["stall_angle"] for e in front), default=None),
        "front_held": any(e["held_below_stall"] for e in front),
    }


def spearman(a, b) -> float | None:
    a, b = np.asarray(a, float), np.asarray(b, float)
    if len(a) < 3:
        return None
    return float(spearmanr(a, b).statistic)


def study_base(storage_name: str, spec: dict) -> tuple[Wing, dict, str] | None:
    """The base wing a saved study's trials were applied to, its job params
    and the job id: rebuilt as commands/wing.py builds it (wing_optimise, or
    wing_design for design studies). The latest job on that study file whose
    objective matches and that finished is used."""
    best = None
    for jid, p, data in jobs():
        if data is None or not str(p.get("storage", "")).endswith("/" + storage_name + ".db"):
            continue
        objective = p.get("objective") or p.get("goal")
        if objective != spec["objective"]:
            continue
        best = (jid, p)
    if best is None:
        return None
    jid, p = best
    if "box" in p:  # wing-design
        first = json.loads((STUDIES / f"{storage_name}.design.json").read_text())
        base = Wing([Element.from_dict(e) for e in first["elements"]], min_gap=float(p.get("min_gap", 0.005)),
                    rules_box=tuple(float(v) for v in p["box"]), ground_frame=True, free_air=bool(p.get("free_air", False)))
        base = apply(base, {} if first.get("from_canvas") else {"yfrac_0": 0.5})
        flow = {k: float(p.get(k, d)) for k, d in (("speed", 15.0), ("rho", 1.225), ("mu", 1.81e-5), ("n_crit", 9.0))}
        p = {**p, **flow, "alpha": 0.0, "ref_chord": sum(e.chord for e in base.elements)}
    else:
        box = p.get("rules_box")
        base = Wing([Element.from_dict(e) for e in p["elements"]], min_gap=float(p.get("min_gap", 0.005)),
                    rules_box=tuple(float(v) for v in box) if box else None, alpha=float(p.get("alpha", 0.0)),
                    ride_height=None if p.get("ride_height") is None else float(p["ride_height"]))
        if any(v["kind"] == "chord" for v in spec["variables"]) and p.get("ref_chord") is None:
            p = {**p, "ref_chord": sum(e.chord for e in base.elements)}  # as wing_optimise does
    return base, p, jid


def library_units(keys) -> dict[str, np.ndarray]:
    from aeroengine.wing.design import units

    return units(data_dir() / "airfoils", sorted(set(keys)))
