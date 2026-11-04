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
angle or just below the section's stall onset, whichever is lower.

An element behind another separates, as on the real wing, once it is turned
too far past the one in front or past the main: more than MAX_DEFLECTION, 25
degrees chord line to chord line. Every RANS case so far splits on that. On the overnight
two-element study (main fixed, flap angle and gap free) the flap held to 25.2
degrees and separated from 26.0 whatever the gap; on the NACA 6212 starting
wing it held at 22 and separated at 42 and 46 with the main free to move.
The flap's effective angle does not split them: with the main free, a
heavily loaded main's downwash keeps the flap's effective angle low in the
panel method (9 to 13 degrees on the wings that separated) while the flap,
recovering pressure in the main's wake, separates; and an effective-angle
line moved by the gap, fitted earlier on the overnight study, marked two of
its attached trials separating. With three to five elements (RANS, NACA
6212, quick mesh, November 2026) a last flap 24 degrees past the main held
however the turn was split, and from 30 degrees past it lost its lift or
separated even with each flap within 25 degrees of the one in front: the
estimate read those wings 27 to 87% high. A single element separates at its
stall angle less STALL_MARGIN. Each row says why in `why`.

What it misses: the slot's effect on lift beyond what the panel method's
interaction gives, a slot so narrow it chokes, how the deflection limit
moves with the gap and the sections (it is fitted on two wings), and a flap
whose nose sits behind the trailing edge in front (no slot at all; the
design search keeps every overlap positive). RANS gets those; this is for
trends and screening."""

from __future__ import annotations

import numpy as np

from ..job import EngineError
from .geometry import label
from .panel import Solver
from .viscous import polar, reynolds


STALL_MARGIN = 2.0  # degrees: the last element counts as separating this far short of its stall angle
# An element with another behind it: the slot keeps it attached well past its
# own stall angle, but not for ever. Fitted on a NACA 6212 main-and-flap wing
# swept through stall with RANS (0 to -9 degrees): attached and lift right to
# 8 degrees past its stall angle in place, lift 7% over at 12, separated at
# 15.6. Its lift stops growing FRONT_LIFT_LIMIT past stall, it counts as
# separating FRONT_SEPARATION past stall, and its drag grows with the square
# of how far past stall onset it is (DRAG_GROWTH fits the three attached
# angles within 5%; held at onset, the drag was 30 to 60% low).
FRONT_LIFT_LIMIT = 9.0
FRONT_SEPARATION = 13.0
DRAG_GROWTH = 0.0087  # per degree squared past stall onset
# An element behind another separates once it is turned more than this past
# the one in front (degrees, chord line to chord line), whatever its
# effective angle: the overnight wing held to 25.2 and separated from 26.0,
# the NACA 6212 wing held at 22 and separated at 42 and 46 (see above). The
# same limit holds from the main to any flap on three to five elements.
MAX_DEFLECTION = 25.0
# Over a ground the panel method's image overstates the lift the ground adds,
# and more so the closer the ground: its gain grows without limit as the gap
# under the wing closes, while the real one peaks and falls as the flow under
# the wing separates. RANS (quick mesh, SA, 15 m/s, moving ground), gain over
# free air: NACA 6212 main and flap +30% at 300 mm, +61% at 150, +72% at 100,
# +9% at 30; a NACA 4412 main alone +9% at 300, +37% at 100, +60% at 50, +47%
# at 30. The share of the image's gain RANS keeps falls with that gain, on
# both wings alike: GROUND_SHARE / (1 + (gain / GROUND_GAIN_KNEE)^3) fits
# every converged point within 0.15 of gain, and caps the ground's whole gain
# near +68%. A heavily separated wing (Cd 0.36 in free air) kept less (+41% at
# 150 mm for +67% here) and nothing at 30 mm.
GROUND_SHARE = 0.8
GROUND_GAIN_KNEE = 1.6


def ground_share(gain: float) -> float:
    """The share of the image method's lift gain over free air that holds (RANS)."""
    return GROUND_SHARE / (1 + (max(gain, 0.0) / GROUND_GAIN_KNEE) ** 3)


def in_ground_effect(placed: list[np.ndarray], alpha: float, ride_height: float) -> tuple[list[np.ndarray], float]:
    """The wing turned so the flow at `alpha` runs along x, and the height of
    a ground `ride_height` below its lowest point."""
    a = np.radians(alpha)
    rot = np.array([[np.cos(a), -np.sin(a)], [np.sin(a), np.cos(a)]])  # points times this turn them by -alpha
    turned = [p @ rot for p in placed]
    return turned, min(float(p[:, 1].min()) for p in turned) - ride_height


def estimate(elements: list[dict], alphas: list[float], speed: float, rho: float = 1.225, mu: float = 1.81e-5,
             n_crit: float = 9.0, ref_chord: float | None = None, model_size: str = "large",
             stall_margin: float = STALL_MARGIN, ride_height: float | None = None) -> dict:
    """elements: coords (placed, m, Selig order), unit, chord, angle, inverted.
    Returns one row per wing angle with total and per-element coefficients
    on the reference chord (the sum of the element chords by default).
    With a ride height (m, from the wing's lowest point to a ground moving
    with the flow) the panel method includes the ground, and each element's
    effective angle is measured against itself alone over the same ground:
    so it holds only what its neighbours do, and the ground's own lift
    (the image's induced speed, more than any turning of the flow) is
    applied on top, as the ratio of the element's lift alone over the
    ground to alone in free air. Each element then keeps ground_share of the
    lift the ground adds over the same wing in free air (the image method
    overstates it against RANS, more the closer the ground); each row also
    gives cl_free_air."""
    if not elements:
        raise EngineError("no elements to estimate")
    if ride_height is not None and not ride_height > 0:
        raise EngineError("the ride height must be above zero")
    placed = [np.asarray(e["coords"], float) for e in elements]
    chords = [float(e["chord"]) for e in elements]
    ref = float(ref_chord or sum(chords))
    multi = Solver(placed, ref) if ride_height is None else None

    # Each element alone, in place: its inviscid lift is linear in the
    # freestream angle, so two solves give it exactly.
    alone = []
    for xy, c in zip(placed, chords):
        s = Solver([xy], c)
        c0, c5 = s.solve(0.0).cl_total, s.solve(5.0).cl_total
        alone.append((c0, (c5 - c0) / 5.0))

    # Effective angles for every wing angle first, then one NeuralFoil call
    # per element for all of them. `local` is each element's lift alone in
    # its surroundings at that wing angle and its slope per degree of
    # freestream: free air, the linear fit above; over a ground, two solves
    # of the element alone over the same ground, as placed and turned a
    # degree about its centroid.
    effective = []  # [row][element] in degrees of freestream
    inviscid = []
    local = []  # [row][element] (lift alone here, slope)
    amplify = []  # [row][element] lift alone over the ground / alone in free air (1 in free air)
    for a in alphas:
        if multi is not None:
            r = multi.solve(float(a))
            here = [(c0 + slope * float(a), slope) for c0, slope in alone]
        else:
            turned, ground = in_ground_effect(placed, float(a), ride_height)
            r = Solver(turned, ref, ground=ground).solve(0.0)
            here = []
            for xy, c in zip(turned, chords):
                base = Solver([xy], c, ground=ground).solve(0.0).cl_total
                mid = xy.mean(axis=0)
                d = np.radians(1.0)  # one degree more freestream is the element turned one degree nose down
                rot = np.array([[np.cos(d), np.sin(d)], [-np.sin(d), np.cos(d)]])
                tilted = Solver([(xy - mid) @ rot.T + mid], c, ground=ground).solve(0.0).cl_total
                here.append((base, tilted - base))
        row_eff, row_inv, row_amp = [], [], []
        for i, ((c0, slope), (base, slope_here)) in enumerate(zip(alone, here)):
            own = r.cl[i] * ref / chords[i]  # this element's lift on its own chord, in place
            row_inv.append(own)
            row_eff.append(float(a) + (own - base) / slope_here if abs(slope_here) > 1e-9 else float(a))
            free = c0 + slope * float(a)
            row_amp.append(base / free if multi is None and abs(free) > 0.05 else 1.0)
        effective.append(row_eff)
        inviscid.append(row_inv)
        local.append(here)
        amplify.append(row_amp)

    viscous = []  # per element: NeuralFoil rows, one per wing angle
    scale = []  # per element and wing angle: viscous over inviscid lift (elements with one behind them)
    stall = []  # per element: the angle of its maximum lift alone
    for i, e in enumerate(elements):
        sense = -1.0 if e.get("inverted") else 1.0
        unit = np.asarray(e["unit"], float)
        re = reynolds(speed, chords[i], rho, mu)
        own = [float(e.get("angle", 0.0)) + sense * effective[k][i] for k in range(len(alphas))]
        sweep = np.arange(-6.0, 26.0, 1.0)
        curve = polar(unit, sweep, re, n_crit, False, model_size)["rows"]
        stall.append(float(sweep[int(np.argmax([r["cl"] for r in curve]))]))
        if i == len(elements) - 1:
            viscous.append(polar(unit, own, re, n_crit, bool(e.get("inverted")), model_size)["rows"])
            scale.append([None] * len(alphas))
            continue
        # Stall onset of the section alone: 4 degrees short of its maximum lift.
        onset = stall[i] - 4.0
        held = [min(a, onset) for a in own]
        viscous.append(polar(unit, held, re, n_crit, bool(e.get("inverted")), model_size)["rows"])
        # The lift in place stops growing FRONT_LIFT_LIMIT past the section's
        # stall angle: cap the in-place inviscid lift there.
        c0, slope = alone[i]
        cap = (stall[i] + FRONT_LIFT_LIMIT - float(e.get("angle", 0.0))) * sense  # freestream-equivalent angle
        for k in range(len(alphas)):
            base, slope_here = local[k][i]
            if own[k] > stall[i] + FRONT_LIFT_LIMIT and abs(slope_here) > 1e-9:
                inviscid[k][i] = base + slope_here * (cap - float(alphas[k]))
        # The viscous loss in the linear part of the lift curve (6 degrees
        # short of stall onset, or lower if the element sits lower): NeuralFoil
        # over the panel method, the section alone, upright.
        ratios = []
        for a in held:
            ar = min(a, onset - 6.0)
            nf = float(np.interp(ar, sweep, [r["cl"] for r in curve]))
            iso = sense * (c0 + slope * sense * (ar - float(e.get("angle", 0.0))))  # upright inviscid lift at ar
            ratios.append(nf / iso if abs(iso) > 0.05 else 1.0)
        scale.append(ratios)

    deflection = [None] + [float(elements[i].get("angle", 0.0)) - float(elements[i - 1].get("angle", 0.0))
                           for i in range(1, len(elements))]
    past_main = [None] + [float(elements[i].get("angle", 0.0)) - float(elements[0].get("angle", 0.0))
                          for i in range(1, len(elements))]

    def separation(i: int, in_place: float, front: bool) -> str | None:
        """Why element i separates here, or None."""
        name = label(i)
        if deflection[i] is not None and deflection[i] > MAX_DEFLECTION:
            return (f"{name} is turned {deflection[i]:.1f}° past {label(i - 1).lower()}, more than the "
                    f"{MAX_DEFLECTION:.0f}° RANS has held: it separates")
        if past_main[i] is not None and past_main[i] > MAX_DEFLECTION:
            return (f"{name} is turned {past_main[i]:.1f}° past the main, more than the "
                    f"{MAX_DEFLECTION:.0f}° RANS has held: it separates")
        if front and in_place > stall[i] + FRONT_SEPARATION:
            return (f"{name} is {in_place:.1f}° in place, more than {FRONT_SEPARATION:.0f}° past its stall angle "
                    f"({stall[i]:.0f}°): it separates")
        if not front and deflection[i] is None and in_place > stall[i] - stall_margin:
            return (f"{name} is {in_place:.1f}° in place, past its stall angle ({stall[i]:.0f}°) less "
                    f"{stall_margin:g}°: it separates")
        return None

    rows = []
    for k, a in enumerate(alphas):
        els, why = [], []
        for i in range(len(elements)):
            v = viscous[i][k]
            share = chords[i] / ref
            front = scale[i][k] is not None
            in_place = e_angle(elements[i], effective[k][i])
            cl_own = v["cl"] * amplify[k][i] if not front else inviscid[k][i] * scale[i][k]
            # Held at the separation line: past it the element counts as separating and the number means little.
            past_onset = min(max(0.0, in_place - (stall[i] - 4.0)), FRONT_SEPARATION + 4.0) if front else 0.0
            cd_own = v["cd"] * (1 + DRAG_GROWTH * past_onset**2)
            reason = separation(i, in_place, front)
            if reason:
                why.append(reason)
            els.append({"cl": cl_own * share, "cd": cd_own * share, "cm": v["cm"] * share * chords[i] / ref,
                        "cl_own": cl_own, "cd_own": cd_own, "cl_inviscid_own": inviscid[k][i],
                        "effective_angle": float(in_place), "upwash": effective[k][i] - float(a),
                        "held_below_stall": front and v["alpha"] < in_place - 1e-9,
                        "transition_suction": v["transition_suction"], "transition_pressure": v["transition_pressure"],
                        "confidence": v["confidence"], "trusted": v["trusted"], "stall_angle": stall[i],
                        "past_stall": reason is not None, "deflection": deflection[i]})
        rows.append({"alpha": float(a), "cl": sum(x["cl"] for x in els), "cd": sum(x["cd"] for x in els),
                     "trusted": all(x["trusted"] for x in els), "separating": bool(why),
                     "why": "; ".join(why) or None, "elements": els})
    if ride_height is not None:
        free = estimate(elements, alphas, speed, rho, mu, n_crit, ref_chord, model_size, stall_margin)["rows"]
        for row, base in zip(rows, free):
            # One share for the whole wing, from the image's gain on the whole wing.
            share = ground_share(row["cl"] / base["cl"] - 1) if abs(base["cl"]) > 0.05 else GROUND_SHARE
            for el, b in zip(row["elements"], base["elements"]):
                el["cl"] = b["cl"] + share * (el["cl"] - b["cl"])
                el["cl_own"] = b["cl_own"] + share * (el["cl_own"] - b["cl_own"])
            row["cl"] = sum(el["cl"] for el in row["elements"])
            row["cl_free_air"] = base["cl"]
            # A ground loads the wing more and separates it sooner: separating in free air, it separates here too.
            if base["separating"] and not row["separating"]:
                row["separating"] = True
                row["why"] = base["why"] + " (in free air; nearer the ground it only gets worse)"
    return {"ref_chord": ref, "rows": rows, "ride_height": ride_height,
            "re": [reynolds(speed, c, rho, mu) for c in chords]}


def e_angle(e: dict, freestream: float) -> float:
    """An element's own angle of attack for a freestream angle (its loading sense either way up)."""
    return float(e.get("angle", 0.0)) + (-1.0 if e.get("inverted") else 1.0) * freestream
