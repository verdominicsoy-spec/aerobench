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
too far past the one in front or past the main: more than max_deflection, 25
degrees chord line to chord line at the Reynolds numbers RANS has checked it
(more at higher ones, see below). Every RANS case so far splits on that. On the overnight
two-element study (main fixed, flap angle and gap free) the flap held to 25.2
degrees and separated from 26.0 whatever the gap; on the NACA 6212 starting
wing it held at 22 and separated at 42 and 46 with the main free to move.
The flap's effective angle does not split them: with the main free, a
heavily loaded main's downwash keeps the flap's effective angle low in the
panel method (9 to 13 degrees on the wings that separated, by the
straight-line fit used then; 16 on one found exactly) while the flap,
recovering pressure in the main's wake, separates; and an effective-angle
line moved by the gap, fitted earlier on the overnight study, marked two of
its attached trials separating. With three to five elements (RANS, NACA
6212, quick mesh, November 2026) a last flap 24 degrees past the main held
however the turn was split, and from 30 degrees past it lost its lift or
separated even with each flap within 25 degrees of the one in front: the
estimate read those wings 27 to 87% high. A single element separates at its
stall angle less STALL_MARGIN. The main or a flap the flow meets from its
pressure side (turned too little for the flow off the element ahead, or set
at a negative angle) separates from that side's leading edge: see
PRESSURE_PEAK_LIMIT. Each row says why in `why`.

What it misses: the slot's effect on lift beyond what the panel method's
interaction gives, a slot so narrow it chokes, how the deflection limit
moves with the gap and the sections (it is fitted on two wings), and a flap
whose nose sits behind the trailing edge in front (no slot at all; the
design search keeps every overlap positive). RANS gets those; this is for
trends and screening.

A slat is an element ahead of the main, the first element at least half the
longest chord: see SLAT_PEAK_LIMIT."""

from __future__ import annotations

import numpy as np

from ..job import EngineError
from .geometry import label
from .panel import Solver
from .viscous import polar, reynolds


# Bump on any change to what the estimate returns for a wing: a study records
# the version that scored it and will not resume on another (optimise.run).
# Version 1: November 2026, with ground_share and the optimiser's margin and trust guards.
# Version 3: a single section's lift scaled to the tunnel at low Reynolds number.
# Version 2: effective angles found on the solver (not a straight-line fit), trailing edges closed,
# front-element limits refitted on the RANS references, slats, a flap limit that rises with Reynolds number.
# Version 4: flaps held to the element in front (past the main only a warning); front elements judged on
# their free-air angle in place; over a ground, separation on the image's whole-wing gain.
# Version 5: the main and flaps separate on a pressure-side peak (PRESSURE_PEAK_LIMIT).
# Version 6: an element whose section shows no stall in NeuralFoil's sweep is named in the warnings.
VERSION = 6
STALL_MARGIN = 2.0  # degrees: the last element counts as separating this far short of its stall angle
# An element with another behind it: the slot keeps it attached well past its
# own stall angle, but not for ever. Fitted on a NACA 6212 main-and-flap wing
# swept through stall with RANS (0 to -9 degrees): attached at 5.1, 9.4 and
# 13.8 degrees past its stall angle in place, separated at 18.4, and at 16.0
# 60 mm over a ground. Its lift stops growing FRONT_LIFT_LIMIT past stall, it
# counts as separating FRONT_SEPARATION past stall, and its drag grows with
# the square of how far past stall onset it is (held at onset, the drag was
# 30 to 60% low). Together they hold the seven converged RANS references in
# validation.RANS_REFERENCES to 3.4% on lift and 9.1% on drag. (In-place
# angles found on the panel solver exactly; a straight-line fit of lift
# against angle had read them 1 to 3 degrees low, with FRONT_SEPARATION 13
# and DRAG_GROWTH 0.0087 fitted on that.)
FRONT_LIFT_LIMIT = 9.25
FRONT_SEPARATION = 15.0
DRAG_GROWTH = 0.0076  # per degree squared past stall onset
# A flap separates once it is turned more than max_deflection past the one
# in front (degrees, chord line to chord line), whatever its
# effective angle. At the Reynolds numbers RANS checked it (flaps 0.45 to 1.4
# x 10^5 on their own chords, 15 m/s) that is MAX_DEFLECTION: the overnight
# wing held to 25.2 and separated from 26.0, the NACA 6212 wing held at 22 and
# separated at 42 and 46 (see above). Not from the main: on a cascade each slot
# feeds the next flap fresh air, and RANS held frontwing#1's Flap 2 attached 32.5
# degrees past its main (13 Nov 2026), where a main-to-flap limit had failed every
# optimiser trial. A flap holds more at higher Reynolds
# numbers: the 30P30N flap (2.7 x 10^6) stays attached 34.8 degrees past its
# main in the tunnel (NASA TM-112858) and in RANS here, so the limit rises
# linearly in log Re to MAX_DEFLECTION_HIGH_RE there and stays. Nothing in
# between was tested, and 35 is only a lower bound for that flap.
MAX_DEFLECTION = 25.0
DEFLECTION_RE = 1.5e5
MAX_DEFLECTION_HIGH_RE = 35.0
DEFLECTION_HIGH_RE = 2.7e6
# A slat (an element ahead of the main), and the main behind it: their
# effective angle says nothing about their stall. In the tunnel the 30P30N slat
# runs 2 to 60 degrees past its section's stall angle in place and its main 15
# to 28, attached to Cl max: the slat dumps its boundary layer into the main's
# fast leading-edge flow and takes the main's suction peak. So their lift is
# not capped and their drag does not grow, and a slatted wing separates at its
# slat, once the suction peak over the trailing-edge pressure in the panel
# solution (Valarezo and Chin's pressure-difference rule) passes
# SLAT_PEAK_LIMIT. Fitted on the one slatted case, 30P30N at Re 9 x 10^6: 32.1
# at Cl max (21.34 degrees), 38.0 past it (23.28). How it moves with the
# Reynolds and Mach numbers is not known here.
SLAT_PEAK_LIMIT = 35.0
# The main or a flap whose stagnation point sits on its suction side: the flow
# wraps round the nose onto the pressure side, peaks there and separates from
# that side's leading edge once the peak over the trailing-edge pressure in the
# panel solution passes PRESSURE_PEAK_LIMIT (the slat's rule, on the other
# side). No angle rule sees it: on design-12 #455 (RANS fine mesh, SST and
# SST-LM, 161 mm) Flap 1 sat 2.3 degrees past the main at 4.6 degrees in place
# against a 12-degree stall, peaked at 22.9 and separated from 62% of its chord.
# Bracketed by one run each side (RANS, 15 m/s, flaps and single elements at
# 0.4 to 1.5 x 10^5 on their own chords): design-4 #1223's Flap 2 held at 6.5,
# and a single inverted element 8.5 degrees the wrong way separated at 11.4
# (not converged, as was design-12); every main and RANS reference sits at 0,
# the published NLR 7301 and 30P30N (but its slat at 0 degrees) too. On a NACA
# 4412 alone the limit falls at about -11.5 degrees. Not for a slat: at low
# angle its cove corner peaks on the pressure side with the flow attached.
PRESSURE_PEAK_LIMIT = 9.0


def max_deflection(re: float) -> float:
    """Degrees a flap at Reynolds number `re` (its own chord) holds past the element in front or the main."""
    t = np.log(max(re, 1.0) / DEFLECTION_RE) / np.log(DEFLECTION_HIGH_RE / DEFLECTION_RE)
    return float(MAX_DEFLECTION + (MAX_DEFLECTION_HIGH_RE - MAX_DEFLECTION) * np.clip(t, 0.0, 1.0))


def main_index(chords: list[float]) -> int:
    """The main element: the first at least half the longest chord. Any ahead of it are slats."""
    return next(i for i, c in enumerate(chords) if c >= 0.5 * max(chords))


def suction_peak(cp: np.ndarray, xy: np.ndarray, inverted: bool) -> float:
    """Trailing-edge Cp less the lowest Cp on the side that carries the lift
    (the upper half in Selig order upright, the lower inverted): a pressure-side
    peak, as at a slat's cove corner at low angle, does not count."""
    le = int(np.argmax(np.linalg.norm(xy - 0.5 * (xy[0] + xy[-1]), axis=1)))
    side = cp[le:] if inverted else cp[:le + 1]
    return float(0.5 * (cp[0] + cp[-1]) - side.min())


def pressure_peak(cp: np.ndarray, gamma: np.ndarray, xy: np.ndarray, inverted: bool) -> float:
    """Trailing-edge Cp less the lowest Cp on the pressure side, when the
    stagnation point (where the surface speed changes sign, nearest the
    leading edge) sits on the suction side so the flow wraps round the nose
    onto the pressure side; 0 when it does not."""
    le = int(np.argmax(np.linalg.norm(xy - 0.5 * (xy[0] + xy[-1]), axis=1)))
    flips = np.nonzero(np.sign(gamma[:-1]) != np.sign(gamma[1:]))[0]
    stag = int(flips[np.argmin(np.abs(flips - le))]) if len(flips) else le
    if not (stag > le if inverted else stag < le):
        return 0.0
    side = cp[:le + 1] if inverted else cp[le:]
    return float(0.5 * (cp[0] + cp[-1]) - side.min())
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
# Past this image-method whole-wing gain over free air the estimate cannot tell
# whether the flow under the wing holds, and warns (RANS decides): RANS held the
# NACA 6212 main and flap at 100 mm (gain 1.45) and separated it at 60 (2.68); the
# NACA 4412 main alone gained lift at 50 mm (1.42) and lost some by 30 (2.78);
# but Zerihan's Tyrrell 026 front wing, built for the ground, held with its
# downforce still rising at 3.1 to 6.0 (h/c 0.134 to 0.067, docs/validation/
# ground-3d), where the estimate's lift reads up to 47% low. (Judging a front
# element over a ground by its angle in place against itself alone over the
# ground read 42 degrees at 300 mm and 145 at 50 on frontwing#1 and failed every
# optimiser trial: front elements are judged on their free-air angle.)
GROUND_SEPARATION_GAIN = 2.0


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
    main = main_index(chords)
    led = [i < main or (i == main and main > 0) for i in range(len(elements))]  # slats, and the main behind them
    res = [reynolds(speed, c, rho, mu) for c in chords]

    # Each element alone, in place. Its panel lift is close to sinusoidal in
    # the freestream angle, not linear, and an element behind or ahead of
    # another sits tens of degrees from the angles a straight-line fit is
    # made at (the 30P30N slat at 78), so every angle below is found on the
    # solver itself; two solves at 0 and 5 degrees only give the first step.
    alone_solvers = [Solver([xy], c) for xy, c in zip(placed, chords)]
    alone = []
    for s in alone_solvers:
        c0, c5 = s.solve(0.0).cl_total, s.solve(5.0).cl_total
        alone.append((c0, (c5 - c0) / 5.0))

    def free_lift(i: int):
        return lambda fa: alone_solvers[i].solve(float(fa)).cl_total

    # Effective angles for every wing angle first, then one NeuralFoil call
    # per element for all of them. `lifts` is each element's lift alone in
    # its surroundings against freestream angle at that wing angle: free
    # air, the solver above; over a ground, a straight line through the
    # element alone over the same ground (_over_ground).
    effective = []  # [row][element] in degrees of freestream
    inviscid = []
    lifts = []  # [row][element] lift alone here against freestream angle
    amplify = []  # [row][element] lift alone over the ground / alone in free air (1 in free air)
    peaks = []  # [row][element] suction peak over trailing-edge pressure, in place
    pressure_peaks = []  # [row][element] the same on the pressure side, where the flow wraps onto it
    # Over a ground, the free-air cascade too: front elements are judged on the angle
    # their neighbours give them there, and the ground on the image's whole-wing gain.
    free_multi = Solver(placed, ref) if multi is None else None
    effective_free = []  # [row][element]: as effective in free air
    image_gain = []  # [row]: the image method's whole-wing lift over free air, less 1 (0 in free air)
    for a in alphas:
        if multi is not None:
            r = multi.solve(float(a))
            here = [free_lift(i) for i in range(len(placed))]
        else:
            turned, ground = in_ground_effect(placed, float(a), ride_height)
            r = Solver(turned, ref, ground=ground).solve(0.0)
            here = [_over_ground(xy, c, ground, float(a)) for xy, c in zip(turned, chords)]
        row_eff, row_inv, row_amp = [], [], []
        for i, ((c0, slope), lift) in enumerate(zip(alone, here)):
            own = r.cl[i] * ref / chords[i]  # this element's lift on its own chord, in place
            row_inv.append(own)
            base = lift(float(a))
            row_eff.append(_angle_for(lift, own, float(a), base, slope))
            free = base if multi is not None else alone_solvers[i].solve(float(a)).cl_total
            row_amp.append(base / free if multi is None and abs(free) > 0.05 else 1.0)
        effective.append(row_eff)
        if free_multi is None:
            effective_free.append(row_eff)
            image_gain.append(0.0)
        else:
            rf = free_multi.solve(float(a))
            effective_free.append([_angle_for(free_lift(i), rf.cl[i] * ref / chords[i], float(a), free_lift(i)(float(a)),
                                              alone[i][1]) for i in range(len(placed))])
            image_gain.append(r.cl_total / rf.cl_total - 1 if abs(rf.cl_total) > 0.05 else 0.0)
        peaks.append([suction_peak(cp, xy, bool(e.get("inverted"))) for cp, xy, e in zip(r.cp, placed, elements)])
        pressure_peaks.append([pressure_peak(cp, g, xy, bool(e.get("inverted")))
                               for cp, g, xy, e in zip(r.cp, r.gamma, placed, elements)])
        inviscid.append(row_inv)
        lifts.append(here)
        amplify.append(row_amp)

    alone = len(elements) == 1  # a single section is NeuralFoil against the tunnel; more are fitted to RANS on its own lift
    viscous = []  # per element: NeuralFoil rows, one per wing angle
    scale = []  # per element and wing angle: viscous over inviscid lift (elements with one behind them)
    stall = []  # per element: the angle of its maximum lift alone
    # Per element: whether that maximum is a stall, not the end of the sweep. A thick, cambered
    # section at a low Reynolds number can lose NeuralFoil's confidence near its peak and climb
    # again to the end (design-4 #1223's Flap 2): its stall is unknown, and said so in the warnings.
    stall_found = []
    sweep = np.arange(-6.0, 26.0, 1.0)
    for i, e in enumerate(elements):
        sense = -1.0 if e.get("inverted") else 1.0
        unit = np.asarray(e["unit"], float)
        re = res[i]
        own = [float(e.get("angle", 0.0)) + sense * effective[k][i] for k in range(len(alphas))]
        curve = polar(unit, sweep, re, n_crit, False, model_size, tunnel=alone)["rows"]
        top = int(np.argmax([r["cl"] for r in curve]))
        stall.append(float(sweep[top]))
        stall_found.append(top < len(sweep) - 1)
        if i == len(elements) - 1 and not led[i]:
            viscous.append(polar(unit, own, re, n_crit, bool(e.get("inverted")), model_size, tunnel=alone)["rows"])
            scale.append([None] * len(alphas))
            continue
        # Stall onset of the section alone: 4 degrees short of its maximum lift.
        onset = stall[i] - 4.0
        held = [min(a, onset) for a in own]
        viscous.append(polar(unit, held, re, n_crit, bool(e.get("inverted")), model_size, tunnel=alone)["rows"])
        # The lift in place stops growing FRONT_LIFT_LIMIT past the section's
        # stall angle: cap the in-place inviscid lift there (not on a slat or the main behind it).
        cap = (stall[i] + FRONT_LIFT_LIMIT - float(e.get("angle", 0.0))) * sense  # freestream-equivalent angle
        for k in range(len(alphas)):
            if own[k] > stall[i] + FRONT_LIFT_LIMIT and not led[i]:
                inviscid[k][i] = lifts[k][i](cap)
        # The viscous loss in the linear part of the lift curve (6 degrees
        # short of stall onset, or lower if the element sits lower): NeuralFoil
        # over the panel method, the section alone, upright.
        ratios = []
        for a in held:
            ar = min(a, onset - 6.0)
            nf = float(np.interp(ar, sweep, [r["cl"] for r in curve]))
            iso = sense * free_lift(i)(sense * (ar - float(e.get("angle", 0.0))))  # upright inviscid lift at ar
            ratios.append(nf / iso if abs(iso) > 0.05 else 1.0)
        scale.append(ratios)

    angle = [float(e.get("angle", 0.0)) for e in elements]
    deflection = [angle[i] - angle[i - 1] if i > main else None for i in range(len(elements))]  # flaps only
    past_main = [angle[i] - angle[main] if i > main else None for i in range(len(elements))]
    limit = [max_deflection(re) for re in res]

    def separation(i: int, in_place: float, front: bool, peak: float, pressure: float) -> str | None:
        """Why element i separates here, or None."""
        name = label(i, main)
        if deflection[i] is not None and deflection[i] > limit[i]:
            return (f"{name} is turned {deflection[i]:.1f}° past {label(i - 1, main).lower()}, more than the "
                    f"{limit[i]:.0f}° a flap holds at its Reynolds number: it separates")
        if i < main and peak > SLAT_PEAK_LIMIT:
            return (f"{name}'s suction peak is {peak:.0f} below its trailing-edge pressure (Cp) in place, more than "
                    f"the {SLAT_PEAK_LIMIT:.0f} the 30P30N slat held: it separates")
        if i >= main and pressure > PRESSURE_PEAK_LIMIT:
            return (f"{name} meets the flow from its pressure side: the peak there is {pressure:.0f} below its "
                    f"trailing-edge pressure (Cp) in place, more than {PRESSURE_PEAK_LIMIT:.0f}: it separates from "
                    f"that side's leading edge")
        if led[i]:
            return None
        if front and in_place > stall[i] + FRONT_SEPARATION:
            return (f"{name} is {in_place:.1f}° in place, more than {FRONT_SEPARATION:.0f}° past its stall angle "
                    f"({stall[i]:.0f}°): it separates")
        if not front and deflection[i] is None and in_place > stall[i] - stall_margin:
            return (f"{name} is {in_place:.1f}° in place, past its stall angle ({stall[i]:.0f}°) less "
                    f"{stall_margin:g}°: it separates")
        return None

    rows = []
    for k, a in enumerate(alphas):
        els, why, warnings = [], [], []
        for i in range(len(elements)):
            v = viscous[i][k]
            share = chords[i] / ref
            front = scale[i][k] is not None
            in_place = e_angle(elements[i], effective[k][i])
            in_place_free = e_angle(elements[i], effective_free[k][i])
            cl_own = v["cl"] * amplify[k][i] if not front else inviscid[k][i] * scale[i][k]
            # Held at the separation line: past it the element counts as separating and the number means little.
            past_onset = min(max(0.0, in_place - (stall[i] - 4.0)), FRONT_SEPARATION + 4.0) if front else 0.0
            cd_own = v["cd"] * (1 + DRAG_GROWTH * (0.0 if led[i] else past_onset**2))
            reason = separation(i, in_place_free if front else in_place, front, peaks[k][i], pressure_peaks[k][i])
            if past_main[i] is not None and past_main[i] > limit[i]:
                warnings.append(f"{label(i, main)} is turned {past_main[i]:.1f}° past the main: RANS separated NACA 6212 "
                                f"cascades from {limit[i]:.0f}° past, and held frontwing#1's Flap 2 at 32.5°; check it with RANS")
            if not stall_found[i] and not led[i]:
                warnings.append(f"NeuralFoil finds no stall angle for {label(i, main).lower()}'s section below "
                                f"{sweep[-1]:.0f}° at its Reynolds number ({res[i]:.2g}), so whether it stalls is not "
                                f"judged; check it with RANS")
            if reason:
                why.append(reason)
            els.append({"cl": cl_own * share, "cd": cd_own * share, "cm": v["cm"] * share * chords[i] / ref,
                        "cl_own": cl_own, "cd_own": cd_own, "cl_inviscid_own": inviscid[k][i],
                        # Front elements: the free-air angle their verdict and the optimiser's margin go by.
                        "effective_angle": float(in_place_free if front else in_place), "upwash": effective[k][i] - float(a),
                        "held_below_stall": front and v["alpha"] < in_place - 1e-9,
                        "transition_suction": v["transition_suction"], "transition_pressure": v["transition_pressure"],
                        "confidence": v["confidence"], "trusted": v["trusted"], "stall_angle": stall[i],
                        "past_stall": reason is not None, "deflection": deflection[i], "past_main": past_main[i],
                        "max_deflection": limit[i], "led": led[i], "suction_peak": peaks[k][i],
                        "pressure_peak": pressure_peaks[k][i], "stall_found": stall_found[i],
                        "role": "slat" if i < main else ("main" if i == main else "flap")})
        if image_gain[k] > GROUND_SEPARATION_GAIN:
            warnings.append(f"Near the ground the estimate cannot tell whether the flow under the wing holds: the image "
                            f"method's lift is {image_gain[k] + 1:.1f} times free air; RANS separated two test wings past "
                            f"{GROUND_SEPARATION_GAIN + 1:.1f}, Zerihan's front wing held to 7. Check it with RANS")
        rows.append({"alpha": float(a), "cl": sum(x["cl"] for x in els), "cd": sum(x["cd"] for x in els),
                     "trusted": all(x["trusted"] for x in els), "separating": bool(why),
                     "why": "; ".join(why) or None, "warnings": warnings, "elements": els})
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
    return {"ref_chord": ref, "rows": rows, "ride_height": ride_height, "re": res}


def _over_ground(xy: np.ndarray, chord: float, ground: float, alpha: float):
    """Lift of one element alone over a ground against freestream angle, the
    flow along x at `alpha`: the straight line through it as placed and turned
    a degree nose down about its centroid. Not the exact curve: turned toward
    the ground an element's lift alone rises faster than that line, so the
    line puts a loaded main further past stall (about 2.5 degrees at 300 mm,
    6 at 150 mm on the NACA 6212 starting wing), and the drag and separation
    near the ground are fitted to RANS on that reading (test_wing_ground)."""
    def turned(deg: float) -> float:
        mid = xy.mean(axis=0)
        d = np.radians(deg)  # more freestream is the element turned nose down
        rot = np.array([[np.cos(d), np.sin(d)], [-np.sin(d), np.cos(d)]])
        return Solver([(xy - mid) @ rot.T + mid], chord, ground=ground).solve(0.0).cl_total
    base = turned(0.0)
    slope = turned(1.0) - base
    return lambda fa: base + slope * (float(fa) - alpha)


def _angle_for(lift, target: float, start: float, at_start: float, slope: float) -> float:
    """The freestream angle at which lift(angle) is target: secant steps from
    start, the first along slope (per degree), none over 30 degrees."""
    if abs(slope) < 1e-9:
        return start
    x0, f0 = start, at_start
    x1 = start + float(np.clip((target - at_start) / slope, -30, 30))
    for _ in range(12):
        f1 = lift(x1)
        if abs(f1 - target) < 1e-8 or x1 == x0:
            break
        d = (f1 - f0) / (x1 - x0)
        if abs(d) < 1e-9:
            break
        x0, f0, x1 = x1, f1, x1 + float(np.clip((target - f1) / d, -30, 30))
    return x1


def e_angle(e: dict, freestream: float) -> float:
    """An element's own angle of attack for a freestream angle (its loading sense either way up)."""
    return float(e.get("angle", 0.0)) + (-1.0 if e.get("inverted") else 1.0) * freestream
