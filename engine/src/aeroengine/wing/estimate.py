"""A multi-element estimate in about a second: the panel method for how the
elements load each other, NeuralFoil for each element's viscous lift and
drag.

For each element the multi-element panel solution gives the lift it
carries in place. The angle at which that element alone (same shape, same
place, panel method) carries the same lift is its effective angle: the
upwash or downwash its neighbours put on it. NeuralFoil at that angle and
the element's own Reynolds number gives its viscous lift, drag and moment.
Lift and drag are summed on the reference chord; the elements' inviscid
x-forces, which cancel between them, are left out, so drag is the sum of
the profile drags.

An element with another behind it is treated differently: the element
behind unloads its trailing edge (the dumping effect), so in place it
carries far more lift than it could alone at its effective angle without
stalling. Its lift is its in-place inviscid lift scaled by the viscous loss
NeuralFoil gives in the linear part of its lift curve, and its drag is NeuralFoil's at the effective
angle or just below the section's stall onset, whichever is lower. The last
element can stall, as on the real wing.

What it misses: the slot's effect on the boundary layers beyond that (a
narrow slot can be worse than either element alone). RANS gets those; this
is for trends and screening."""

from __future__ import annotations

import numpy as np

from ..job import EngineError
from .panel import Solver
from .viscous import polar, reynolds


def estimate(elements: list[dict], alphas: list[float], speed: float, rho: float = 1.225, mu: float = 1.81e-5,
             n_crit: float = 9.0, ref_chord: float | None = None, model_size: str = "large") -> dict:
    """elements: coords (placed, m, Selig order), unit, chord, angle, inverted.
    Returns one row per wing angle with total and per-element coefficients
    on the reference chord (the sum of the element chords by default)."""
    if not elements:
        raise EngineError("no elements to estimate")
    placed = [np.asarray(e["coords"], float) for e in elements]
    chords = [float(e["chord"]) for e in elements]
    ref = float(ref_chord or sum(chords))
    multi = Solver(placed, ref)

    # Each element alone, in place: its inviscid lift is linear in the
    # freestream angle, so two solves give it exactly.
    alone = []
    for xy, c in zip(placed, chords):
        s = Solver([xy], c)
        c0, c5 = s.solve(0.0).cl_total, s.solve(5.0).cl_total
        alone.append((c0, (c5 - c0) / 5.0))

    # Effective angles for every wing angle first, then one NeuralFoil call
    # per element for all of them.
    effective = []  # [row][element] in degrees of freestream
    inviscid = []
    for a in alphas:
        r = multi.solve(float(a))
        row_eff, row_inv = [], []
        for i, (c0, slope) in enumerate(alone):
            own = r.cl[i] * ref / chords[i]  # this element's lift on its own chord, in place
            row_inv.append(own)
            row_eff.append((own - c0) / slope if abs(slope) > 1e-9 else float(a))
        effective.append(row_eff)
        inviscid.append(row_inv)

    viscous = []  # per element: NeuralFoil rows, one per wing angle
    scale = []  # per element and wing angle: viscous over inviscid lift (elements with one behind them)
    for i, e in enumerate(elements):
        sense = -1.0 if e.get("inverted") else 1.0
        unit = np.asarray(e["unit"], float)
        re = reynolds(speed, chords[i], rho, mu)
        own = [float(e.get("angle", 0.0)) + sense * effective[k][i] for k in range(len(alphas))]
        if i == len(elements) - 1:
            viscous.append(polar(unit, own, re, n_crit, bool(e.get("inverted")), model_size)["rows"])
            scale.append([None] * len(alphas))
            continue
        # Stall onset of the section alone: 4 degrees short of its maximum lift.
        sweep = np.arange(-6.0, 26.0, 1.0)
        curve = polar(unit, sweep, re, n_crit, False, model_size)["rows"]
        onset = float(sweep[int(np.argmax([r["cl"] for r in curve]))]) - 4.0
        held = [min(a, onset) for a in own]
        viscous.append(polar(unit, held, re, n_crit, bool(e.get("inverted")), model_size)["rows"])
        # The viscous loss in the linear part of the lift curve (6 degrees
        # short of stall onset, or lower if the element sits lower): NeuralFoil
        # over the panel method, the section alone, upright.
        c0, slope = alone[i]
        ratios = []
        for a in held:
            ar = min(a, onset - 6.0)
            nf = float(np.interp(ar, sweep, [r["cl"] for r in curve]))
            iso = sense * (c0 + slope * sense * (ar - float(e.get("angle", 0.0))))  # upright inviscid lift at ar
            ratios.append(nf / iso if abs(iso) > 0.05 else 1.0)
        scale.append(ratios)

    rows = []
    for k, a in enumerate(alphas):
        els = []
        for i in range(len(elements)):
            v = viscous[i][k]
            share = chords[i] / ref
            cl_own = v["cl"] if scale[i][k] is None else inviscid[k][i] * scale[i][k]
            els.append({"cl": cl_own * share, "cd": v["cd"] * share, "cm": v["cm"] * share * chords[i] / ref,
                        "cl_own": cl_own, "cd_own": v["cd"], "cl_inviscid_own": inviscid[k][i],
                        "effective_angle": float(e_angle(elements[i], effective[k][i])), "upwash": effective[k][i] - float(a),
                        "held_below_stall": scale[i][k] is not None and v["alpha"] < e_angle(elements[i], effective[k][i]) - 1e-9,
                        "transition_suction": v["transition_suction"], "transition_pressure": v["transition_pressure"],
                        "confidence": v["confidence"], "trusted": v["trusted"]})
        rows.append({"alpha": float(a), "cl": sum(x["cl"] for x in els), "cd": sum(x["cd"] for x in els),
                     "trusted": all(x["trusted"] for x in els), "elements": els})
    return {"ref_chord": ref, "rows": rows,
            "re": [reynolds(speed, c, rho, mu) for c in chords]}


def e_angle(e: dict, freestream: float) -> float:
    """An element's own angle of attack for a freestream angle (its loading sense either way up)."""
    return float(e.get("angle", 0.0)) + (-1.0 if e.get("inverted") else 1.0) * freestream
