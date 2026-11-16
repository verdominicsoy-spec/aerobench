"""The finite wing from span, total chord and endplates.

effective_aspect_ratio, lift_factor and car_contribution are the app's
Wing.finite3D formulas, for the estimate: endplates raise the aspect ratio,
AR (1 + 1.9 h / b) (Hoerner, Fluid-Dynamic Drag); lifting-line theory then
scales the 2D lift by AR_eff / (AR_eff + 2) and adds induced drag
CL^2 / (pi AR_eff). A first number for a finite wing, not a 3D solution:
no tip vortex roll-up, no endplate drag, no interaction with the car.

induced_angle, for RANS as on the car, comes from the vortex lattice
(vlm.py), which holds where those formulas do not: short wings, tall
endplates, endplates close to the ground."""

from __future__ import annotations

import math
from functools import lru_cache

import numpy as np


def effective_aspect_ratio(span: float, chord: float, endplate: float) -> float:
    return span / chord * (1 + 1.9 * max(endplate, 0.0) / span)


def ground_factor(ride_height: float | None, span: float) -> float:
    """The share of the free-air induced angle left over a ground: 1 - sigma,
    Wieselsberger's sigma = (1 - 1.32 h/b) / (1.05 + 7.4 h/b), h from the
    wing's lowest point, h/b held to 0.033-0.25 where the formula was made."""
    if ride_height is None:
        return 1.0
    hb = min(max(ride_height / span, 0.033), 0.25)
    return 1.0 - (1 - 1.32 * hb) / (1.05 + 7.4 * hb)


@lru_cache(maxsize=128)
def _lattice(span: float, chord: float, planform: float, endplate: float, ride_height: float | None,
             endplate_bottom: float | None) -> tuple[float, float]:
    from .vlm import Lattice

    def k(height: float | None, bottom: float | None) -> float:  # radians of downwash per unit Cl on chord
        w = Lattice(span=span, chord=planform, height=height, endplate=endplate, endplate_bottom=bottom).solve()
        return w.k_drag * chord / planform

    # shortcut: a flat plate at the wing's lowest point; the 2D RANS section carries the rest of the ground effect.
    rel = None if endplate_bottom is None or ride_height is None else endplate_bottom - ride_height
    free = k(None, rel)
    near = free if ride_height is None else k(ride_height, ride_height if endplate_bottom is None else endplate_bottom)
    return 1 / (math.pi * free), near / free


def lattice_factors(span: float, chord: float, endplate: float, ride_height: float | None,
                    planform: float | None = None, endplate_bottom: float | None = None) -> tuple[float, float]:
    """The induced angle's free-air effective aspect ratio and its share left over a ground, from the
    vortex lattice (vlm.py: wing, endplates and their gap to the ground, the ground's image). The angle
    is the trailing vortices' downwash at the wing, Cdi / Cl from the wake far behind: the one lifting
    line uses, without its slender-wing and small-endplate limits. chord is the one Cl is on (the sum of
    the elements'); planform the wing's length front to back (default chord). endplate_bottom: the
    endplates' lower edge over the ground (default level with the wing's lowest point, as Zerihan's)."""
    r = lambda v: None if v is None else round(float(v), 5)  # noqa: E731
    return _lattice(r(span), r(chord), r(planform or chord), r(max(endplate, 0.0)), r(ride_height), r(endplate_bottom))


def induced_angle(cl: float, span: float, chord: float, endplate: float, ride_height: float | None,
                  planform: float | None = None, endplate_bottom: float | None = None) -> float:
    """Degrees the trailing vortices turn the flow at the wing, the way that unloads it: up for a
    downforce wing (Cl < 0). From the vortex lattice (lattice_factors)."""
    ar, gf = lattice_factors(span, chord, endplate, ride_height, planform, endplate_bottom)
    return -math.degrees(cl / (math.pi * ar)) * gf


def lift_factor(span: float, chord: float, endplate: float) -> float:
    ar = effective_aspect_ratio(span, chord, endplate)
    return ar / (ar + 2)


def car_contribution(cl: float, cd: float, span: float, chord: float, endplate: float | None,
                     factor: float = 1.0) -> tuple[float, float]:
    """ClA (positive for downforce, from the wing-frame Cl) and CdA. Without
    an endplate height the typed factor is used, on both, as before."""
    area = span * chord
    if endplate is None:
        return -cl * area * factor, cd * area * factor
    ar = effective_aspect_ratio(span, chord, endplate)
    cl3 = cl * ar / (ar + 2)
    return -cl3 * area, (cd + cl3 * cl3 / (math.pi * ar)) * area


def settle(cl_at, alpha: float, span: float, chord: float, endplate: float, ride_height: float | None,
           tolerance: float = 0.05, calls: int = 6) -> tuple[float, float]:
    """The angle the flow meets the wing at on the car, and its Cl there: where
    alpha + induced_angle(cl_at(a)) = a. cl_at(a) is the wing's Cl with the flow
    at a (degrees); the first step is the linear lifting-line guess, then
    secant steps, at most `calls` calls in all."""
    ar = effective_aspect_ratio(span, chord, endplate)
    gap = lambda a, cl: alpha + induced_angle(cl, span, chord, endplate, ride_height) - a  # noqa: E731
    a0, c0 = alpha, cl_at(alpha)
    f0 = gap(a0, c0)
    a1 = alpha + induced_angle(c0 * ar / (ar + 2), span, chord, endplate, ride_height)
    c1 = cl_at(a1)
    f1 = gap(a1, c1)
    for _ in range(calls - 2):
        if abs(f1) < tolerance or f1 == f0:
            break
        a0, f0, a1 = a1, f1, a1 - f1 * (a1 - a0) / (f1 - f0)
        c1 = cl_at(a1)
        f1 = gap(a1, c1)
    return a1, c1


STEEP = 2.0  # a polar segment this many times steeper than the polar's typical slope is a jump: a stall


def couple_strips(polars, k, width, alpha: float) -> dict:
    """Spanwise strips on their own section polars, coupled by the vortex lattice (vlm.Lattice.strips):
    strip i meets the flow at a_i = alpha - degrees(k @ cl)_i, cl_i its polar's Cl at a_i (straight
    lines between the polar's angles). polars: per strip (angles in degrees, Cl). Returns each strip's
    angle and Cl, the wing's Cl (width-weighted), and the strips whose angle is outside their polar
    (out_of_range: the end value is used), past the polar's lift peak (past_stall: Cl falls as the angle
    rises) or on a jump in it (steep: Cl interpolated across a stall between two solves)."""
    import numpy as np
    k, width = np.asarray(k, float), np.asarray(width, float)
    pa = [np.asarray(p[0], float) for p in polars]
    pc = [np.asarray(p[1], float) for p in polars]
    order = [np.argsort(a) for a in pa]
    pa, pc = [a[o] for a, o in zip(pa, order)], [c[o] for c, o in zip(pc, order)]
    if any(len(np.unique(a)) < 2 for a in pa):
        raise ValueError("each strip's polar needs at least two angles")

    def cl(a):
        return np.array([np.interp(x, ax, cx) for x, ax, cx in zip(a, pa, pc)])

    def gap(a):
        return alpha - np.degrees(k @ cl(a)) - a

    # Strip by strip, the others held: each strip's own equation falls as its angle rises wherever its
    # Cl does not fall (a jump in Cl included), so a bracketed root always exists. Newton across the
    # polar's kinks loses the answer on a stall cliff (frontwing#1.02). Sweeps until nothing moves.
    from scipy.optimize import brentq

    a = np.full(len(polars), float(alpha))
    c = cl(a)
    span = max(float(np.ptp(np.concatenate(pa))), 1.0) + 90.0
    for _ in range(500):
        before = a.copy()
        for i in range(len(a)):
            rest = k[i] @ c - k[i, i] * c[i]
            g = lambda x, i=i, rest=rest: alpha - np.degrees(k[i, i] * np.interp(x, pa[i], pc[i]) + rest) - x  # noqa: E731
            a[i] = 0.5 * a[i] + 0.5 * brentq(g, pa[i][0] - span, pa[i][-1] + span, xtol=1e-10)
            c[i] = np.interp(a[i], pa[i], pc[i])
        if np.abs(a - before).max() < 1e-9:
            break
    c = cl(a)
    out, past, steep = [], [], []
    for i, (x, ax, cx) in enumerate(zip(a, pa, pc)):
        if x < ax[0] or x > ax[-1]:
            out.append(i)
            continue
        slopes = np.diff(cx) / np.diff(ax)
        s = slopes[min(int(np.searchsorted(ax, x, side="right")) - 1, len(slopes) - 1)]
        rising = slopes[slopes > 0]
        if s <= 0:  # Cl rises with angle on any attached section, an inverted one's toward zero
            past.append(i)
        elif s > STEEP * np.median(rising):
            steep.append(i)
    return {"alpha": [float(x) for x in a], "cl": [float(x) for x in c],
            "cl_wing": float(np.sum(c * width) / np.sum(width)),
            "converged": bool(np.abs(gap(a)).max() < 1e-6), "out_of_range": out, "past_stall": past, "steep": steep}


@lru_cache(maxsize=128)
def _chordwise(span: float, planform: float, endplate: float, ride_height: float | None,
               endplate_bottom: float | None, stations: tuple[float, ...],
               loading: tuple[float, ...] | None = None) -> tuple[float, ...]:
    from .vlm import Lattice

    bottom = None if ride_height is None else ride_height if endplate_bottom is None else endplate_bottom
    lat = Lattice(span=span, chord=planform, height=ride_height, endplate=endplate, endplate_bottom=bottom,
                  nx=len(loading) if loading else 8)
    return tuple(float(a) for a in lat.chordwise(list(stations), loading))


LOADING_PANELS = 24  # chordwise lattice panels when the loading follows the elements


def thin_airfoil_loading(extents: list[tuple[float, float]], shares: list[float], panels: int = LOADING_PANELS) -> np.ndarray:
    """Each chordwise panel's share of the circulation: each element's share spread over its own extent
    (nose and trailing edge as fractions of the planform) as a thin airfoil carries it, density
    sqrt((1 - xi) / xi), whose integral from 0 to t is sqrt(t (1 - t)) + asin(sqrt(t))."""
    edges = np.linspace(0.0, 1.0, panels + 1)
    run = lambda t: np.sqrt(t * (1 - t)) + np.arcsin(np.sqrt(t))  # noqa: E731
    load = np.zeros(panels)
    for (lo, hi), share in zip(extents, shares):
        if hi <= lo:
            continue
        t0, t1 = np.clip((edges[:-1] - lo) / (hi - lo), 0, 1), np.clip((edges[1:] - lo) / (hi - lo), 0, 1)
        load += share * (run(t1) - run(t0)) / (math.pi / 2)
    return load


SECTION_PANELS = 32  # chordwise lattice panels over all the elements, when the lattice is the section as drawn


@lru_cache(maxsize=32)
def _section_angles(span: float, endplate: float, ride_height: float | None, endplate_bottom: float | None,
                    sections: tuple, alpha: float, shares: tuple[float, ...]) -> tuple:
    """The section on the car (sections as drawn, turned by alpha as in_ground_effect turns them, over the
    ground from its lowest point) as a lattice of each element's mean line, every element loaded as a thin
    airfoil with its share. Per element: its mean line's control points' x as drawn, and the induced angle
    there (rad per unit section Cl on the lattice's chord); and that chord, front to back on the car."""
    from .estimate import in_ground_effect
    from .vlm import Lattice, camber_line

    drawn = [np.asarray(e, float) for e in sections]
    chords = [float(np.max(np.linalg.norm(e - 0.5 * (e[0] + e[-1]), axis=1))) for e in drawn]
    counts = [max(6, round(SECTION_PANELS * c / sum(chords))) for c in chords]
    turned, ground = in_ground_effect(drawn, alpha, ride_height or 0.0)
    a = math.radians(alpha)
    rot = np.array([[math.cos(a), -math.sin(a)], [math.sin(a), math.cos(a)]])  # as in_ground_effect
    x0 = min(float(t[:, 0].min()) for t in turned)
    plan = max(float(t[:, 0].max()) for t in turned) - x0
    run = lambda t: np.sqrt(t * (1 - t)) + np.arcsin(np.sqrt(t))  # noqa: E731
    panels, loading, controls = [], [], []
    for e, n, share in zip(drawn, counts, shares):
        line = camber_line(e, n)
        car = line @ rot - np.array([x0, ground])
        f = 0.5 * (1 - np.cos(np.linspace(0.0, math.pi, n + 1)))
        panels += [(tuple(car[i]), tuple(car[i + 1])) for i in range(n)]
        loading += list(share * (run(f[1:]) - run(f[:-1])) / (math.pi / 2))
        controls.append(line[:-1, 0] + 0.75 * np.diff(line[:, 0]))
    bottom = None if ride_height is None else ride_height if endplate_bottom is None else endplate_bottom
    lat = Lattice(span=span, chord=plan, height=None if ride_height is None else 0.0, endplate=endplate,
                  endplate_bottom=bottom if ride_height is not None else endplate_bottom, profile=panels, nx=16, nz=12)
    angles = lat.panel_angles(loading)
    out, k = [], 0
    for xc, n in zip(controls, counts):
        out.append((tuple(xc), tuple(angles[k:k + n])))
        k += n
    return tuple(out), plan


def element_curve(drawn: list[np.ndarray], values: list[float], x: np.ndarray) -> np.ndarray:
    """Each element's value along the drawn x: the mean of the elements over each point, else the nearest's."""
    ranges = [(float(e[:, 0].min()), float(e[:, 0].max())) for e in drawn]
    out = []
    for px in x:
        over = [i for i, (a, b) in enumerate(ranges) if a <= px <= b] or \
            [min(range(len(ranges)), key=lambda i: min(abs(px - ranges[i][0]), abs(px - ranges[i][1])))]
        out.append(sum(values[i] for i in over) / len(over))
    return np.array(out)


def section_loads(sections, alpha: float, ride_height: float | None, onset: list[float] | None = None,
                  turns: list[float] | None = None) -> list[float]:
    """Each element's circulation (m^2/s per m/s) in the 2D vortex lattice of its mean line: the section as drawn
    (m), turned on the car by alpha (degrees) and set over the ground from its lowest point, with each element's
    flow turned by onset (degrees, alpha's sense) or each element turned by turns (bend_section: the section
    bent, points at one x together)."""
    from .estimate import in_ground_effect
    from .rans import bend_section
    from .vlm import Lattice, camber_line

    drawn = [np.asarray(e, float) for e in sections]
    if turns is not None:
        lo, hi = min(float(e[:, 0].min()) for e in drawn), max(float(e[:, 0].max()) for e in drawn)
        x = np.linspace(lo, hi, 241)
        drawn = bend_section(drawn, list(x), list(element_curve(drawn, list(turns), x)))
    chords = [float(np.max(np.linalg.norm(e - 0.5 * (e[0] + e[-1]), axis=1))) for e in drawn]
    counts = [max(6, round(SECTION_PANELS * c / sum(chords))) for c in chords]
    turned, ground = in_ground_effect(drawn, alpha, ride_height or 0.0)
    a = math.radians(alpha)
    rot = np.array([[math.cos(a), -math.sin(a)], [math.sin(a), math.cos(a)]])
    x0 = min(float(t[:, 0].min()) for t in turned)
    panels, flow = [], []
    for k, (e, n) in enumerate(zip(drawn, counts)):
        car = camber_line(e, n) @ rot - np.array([x0, ground])
        panels += [(tuple(car[i]), tuple(car[i + 1])) for i in range(n)]
        flow += [math.radians(onset[k]) if onset is not None else 0.0] * n
    plan = max(float(t[:, 0].max()) for t in turned) - x0
    lat = Lattice(span=1e4 * plan, chord=plan, height=None if ride_height is None else 0.0, profile=panels,
                  onset=flow, ny=2)
    g = lat.panel_loads()
    out, k = [], 0
    for n in counts:
        out.append(float(g[k:k + n].sum()))
        k += n
    return out


@lru_cache(maxsize=64)
def _consistent(sections: tuple, alpha: float, ride_height: float, onset: tuple[float, ...]) -> tuple[float, ...]:
    from scipy.optimize import least_squares

    target = np.array(section_loads(sections, alpha, ride_height, onset=list(onset)))
    scale = float(np.abs(target).max()) or 1.0
    fit = least_squares(lambda t: (np.array(section_loads(sections, alpha, ride_height, turns=list(t))) - target) / scale,
                        np.array(onset, float), diff_step=1e-4, xtol=1e-10, ftol=1e-12)
    return tuple(float(t) for t in fit.x)


def consistent_turns(sections, alpha: float, ride_height: float | None, onset: list[float]) -> list[float]:
    """Degrees to turn each element by (alpha's sense, bend_section) so that the section, over the ground, carries
    what it carries in a flow turned by onset at each element as it sits (2D vortex lattice of the mean lines).
    The on-car RANS must turn the section, not the flow (the flow runs along the ground), and turning it lifts
    one end off the ground and lowers the other: frontwing#1.02 turned 17 deg nose up takes its main 43 mm
    further from the ground at the quarter chord, and its flaps up to 100 mm closer. In free air turning the
    section is turning the flow: onset is returned. Zerihan's single element: 0.96 of the onset."""
    if ride_height is None:
        return [float(x) for x in onset]
    key = tuple(tuple(map(tuple, np.round(np.asarray(e, float), 6))) for e in sections)
    return list(_consistent(key, round(float(alpha), 4), round(float(ride_height), 6), tuple(round(float(x), 4) for x in onset)))


def section_induced_angle(cl: float, shares: list[float], span: float, chord: float, endplate: float,
                          ride_height: float | None, endplate_bottom: float | None, sections, alpha: float) -> float:
    """Degrees the flow is turned at the section as it sits on the car (the vortex lattice of its mean lines,
    loaded as shares say), the way that unloads it: the load-weighted mean of each element's own induced angle at
    its three-quarter chord, the lattice's downwash beyond what the same loading makes on an endless span. The
    angle the section feels, where induced_angle is lifting line's (Trefftz): on a slender wing they agree, on
    frontwing#1.02 (aspect ratio 0.77) this one is 20% larger, on Zerihan's wing by the ground smaller."""
    return _section_turns(cl, shares, span, chord, endplate, ride_height, endplate_bottom, sections, alpha, None,
                          mean_only=True)[0]


def _section_turns(cl: float, shares: list[float], span: float, chord: float, endplate: float,
                   ride_height: float | None, endplate_bottom: float | None, sections, alpha: float,
                   at: list[float] | None, mean_only: bool = False) -> list[float]:
    r = lambda v: None if v is None else round(float(v), 5)  # noqa: E731
    key = tuple(tuple(map(tuple, np.round(np.asarray(e, float), 6))) for e in sections)
    per, plan = _section_angles(r(span), r(max(endplate, 0.0)), r(ride_height), r(endplate_bottom), key,
                                round(float(alpha), 4), tuple(round(float(x), 4) for x in shares))
    drawn = [np.asarray(e, float) for e in sections]

    def angle_at(x: float, e: int) -> float:
        xc, a = np.asarray(per[e][0]), np.asarray(per[e][1])
        o = np.argsort(xc)
        return float(np.interp(x, xc[o], a[o]))

    def three_quarter(e: np.ndarray) -> float:
        te = 0.5 * (e[0] + e[-1])
        nose = e[int(np.argmax(np.linalg.norm(e - te, axis=1)))]
        return float(nose[0] + 0.75 * (te[0] - nose[0]))

    own = [angle_at(three_quarter(e), i) for i, e in enumerate(drawn)]
    mean = sum(w * x for w, x in zip(shares, own)) / sum(shares)
    if mean_only:
        return [-math.degrees(mean) * cl * chord / plan]
    if at is None:
        values = own
    else:  # along the drawn x: the elements over each point (their mean where they overlap), else the nearest
        lo = min(float(e[:, 0].min()) for e in drawn)
        span_x = max(float(e[:, 0].max()) for e in drawn) - lo
        ranges = [(float(e[:, 0].min()), float(e[:, 0].max())) for e in drawn]
        values = []
        for f in at:
            x = lo + f * span_x
            over = [i for i, (a, b) in enumerate(ranges) if a <= x <= b]
            if not over:
                over = [min(range(len(ranges)), key=lambda i: min(abs(x - ranges[i][0]), abs(x - ranges[i][1])))]
            values.append(sum(angle_at(x, i) for i in over) / len(over))
    return [-math.degrees(x - mean) * cl * chord / plan for x in values]


def element_turns(cl: float, stations: list[float], shares: list[float], span: float, chord: float,
                  endplate: float, ride_height: float | None, planform: float | None = None,
                  endplate_bottom: float | None = None, at: list[float] | None = None,
                  extents: list[tuple[float, float]] | None = None, sections: list | None = None,
                  alpha: float = 0.0) -> list[float]:
    """Degrees each element turns on top of the wing's mean induced angle, alpha's sense (positive unloads
    a downforce wing at Cl < 0): the vortex lattice's induced angle at the element's station (fraction of
    the planform from the leading edge) less its load-weighted mean over the elements (shares, summing
    to 1). On a wing shorter than its chord the flow behind meets a steeper angle (Lattice.chordwise), so
    the flaps unload against the main; one element turns by nothing, keeping lattice_factors' angle.
    at: the turn at these stations instead (on the same mean), to bend the section along its chord.
    extents: each element's nose and trailing edge (planform fractions): the lattice then carries the
    elements' own loads (shares) along the chord, not a flat plate's (thin_airfoil_loading).
    sections: each element's coords as drawn (m), turned on the car by alpha (the wing's angle, degrees): the
    lattice is then the section as it sits, each element's mean line at its own height and slope (frontwing#1.02
    climbs 0.24 m from the main to flap 3, toward the endplates' top), and each element's angle is at its own
    three-quarter chord; stations, planform and extents are not used (at is still a fraction of the planform
    as drawn)."""
    if len(stations) < 2:
        return [0.0] * len(stations if at is None else at)
    if sections is not None:
        return _section_turns(cl, shares, span, chord, endplate, ride_height, endplate_bottom, sections, alpha, at)
    planform = planform or chord
    r = lambda v: None if v is None else round(float(v), 5)  # noqa: E731
    points = list(stations) + list(at or [])
    loading = None if extents is None else tuple(round(float(x), 4) for x in thin_airfoil_loading(extents, shares))
    a = _chordwise(r(span), r(planform), r(max(endplate, 0.0)), r(ride_height), r(endplate_bottom),
                   tuple(round(float(s), 4) for s in points), loading)
    mean = sum(w * x for w, x in zip(shares, a[:len(stations)]))
    return [-math.degrees(x - mean) * cl * chord / planform for x in (a[:len(stations)] if at is None else a[len(stations):])]
