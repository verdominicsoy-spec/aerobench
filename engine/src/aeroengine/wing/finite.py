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
    (out_of_range: the end value is used), past the polar's lift peak (past_stall: the slope's sign
    flips) or on a jump in it (steep: Cl interpolated across a stall between two solves)."""
    import numpy as np
    from scipy.optimize import root

    k, width = np.asarray(k, float), np.asarray(width, float)
    pa = [np.asarray(p[0], float) for p in polars]
    pc = [np.asarray(p[1], float) for p in polars]
    order = [np.argsort(a) for a in pa]
    pa, pc = [a[o] for a, o in zip(pa, order)], [c[o] for c, o in zip(pc, order)]

    def cl(a):
        return np.array([np.interp(x, ax, cx) for x, ax, cx in zip(a, pa, pc)])

    def gap(a):
        return alpha - np.degrees(k @ cl(a)) - a

    start = np.full(len(polars), float(alpha))
    sol = root(gap, start, method="hybr")
    if not sol.success or np.abs(gap(sol.x)).max() > 1e-6:
        # Continuation: from the polars' least loaded angle up to alpha, each step from the last.
        a = np.array([ax[np.argmin(np.abs(cx))] for ax, cx in zip(pa, pc)])
        a0 = float(np.mean(a))
        for t in np.linspace(0.1, 1.0, 10):
            step = a0 + t * (alpha - a0)
            sol = root(lambda x, s=step: s - np.degrees(k @ cl(x)) - x, a, method="hybr")
            a = sol.x
    a = sol.x
    c = cl(a)
    out, past, steep = [], [], []
    for i, (x, ax, cx) in enumerate(zip(a, pa, pc)):
        if x < ax[0] or x > ax[-1]:
            out.append(i)
            continue
        slopes = np.diff(cx) / np.diff(ax)
        s = slopes[min(int(np.searchsorted(ax, x, side="right")) - 1, len(slopes) - 1)]
        typical = np.median(slopes)
        if np.sign(s) != np.sign(typical):
            past.append(i)
        elif abs(s) > STEEP * np.median(np.abs(slopes)):
            steep.append(i)
    return {"alpha": [float(x) for x in a], "cl": [float(x) for x in c],
            "cl_wing": float(np.sum(c * width) / np.sum(width)),
            "converged": bool(np.abs(gap(a)).max() < 1e-6), "out_of_range": out, "past_stall": past, "steep": steep}
