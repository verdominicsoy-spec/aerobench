"""The finite wing from span, total chord and endplates: the same formulas
as the app's Wing.finite3D. Endplates raise the effective aspect ratio,
AR (1 + 1.9 h / b) (Hoerner, Fluid-Dynamic Drag); lifting-line theory then
scales the 2D lift by AR_eff / (AR_eff + 2) and adds induced drag
CL^2 / (pi AR_eff). A first number for a finite wing, not a 3D solution:
no tip vortex roll-up, no endplate drag, no interaction with the car."""

from __future__ import annotations

import math


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


def induced_angle(cl: float, span: float, chord: float, endplate: float, ride_height: float | None) -> float:
    """Degrees the trailing vortices turn the flow at the wing (lifting line,
    Cl / (pi AR_eff)), the way that unloads it: up for a downforce wing (Cl < 0)."""
    ar = effective_aspect_ratio(span, chord, endplate)
    return -math.degrees(cl / (math.pi * ar)) * ground_factor(ride_height, span)


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
