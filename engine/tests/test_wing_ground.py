"""Ground effect: the image method, and what it does to an inverted wing."""

from __future__ import annotations

import numpy as np
import pytest

from aeroengine.wing.airfoils import naca4
from aeroengine.wing.panel import Solver


def _inverted(code: str, angle_deg: float, chord: float = 0.3) -> np.ndarray:
    """An inverted section at an angle (more downforce for a bigger angle), Selig order."""
    unit = naca4(code)[::-1] * (1, -1)
    a = np.radians(angle_deg)
    rot = np.array([[np.cos(a), np.sin(a)], [-np.sin(a), np.cos(a)]])
    return chord * unit @ rot


def test_images_are_the_mirrored_wing():
    wing = _inverted("4412", 4.0)
    g = wing[:, 1].min() - 0.06
    mirror = np.column_stack([wing[:, 0], 2 * g - wing[:, 1]])[::-1]  # mirrored and back in Selig order
    pair = Solver([wing, mirror], ref_chord=0.3).solve(0.0)
    image = Solver([wing], ref_chord=0.3, ground=g).solve(0.0)
    assert image.cl[0] == pytest.approx(pair.cl[0], rel=1e-6)
    assert image.cl[0] == pytest.approx(-pair.cl[1], rel=1e-6)  # the mirror carries the opposite lift


def test_an_inverted_wing_makes_more_downforce_near_the_ground():
    wing = _inverted("4412", 4.0)
    free = Solver([wing], ref_chord=0.3).solve(0.0).cl_total
    lows = [Solver([wing], ref_chord=0.3, ground=wing[:, 1].min() - h * 0.3).solve(0.0).cl_total for h in (1.0, 0.5, 0.2)]
    assert free < 0 and free > lows[0] > lows[1] > lows[2]  # more negative: more downforce, the closer
    assert abs(lows[0] / free - 1) < 0.15  # a chord away it has mostly faded
    with pytest.raises(ValueError, match="turn the wing"):
        Solver([wing], ground=-1.0).solve(2.0)


def test_the_estimate_in_ground_effect():
    import sys
    from pathlib import Path

    sys.path.insert(0, str(Path(__file__).parent))
    from test_wing_estimate import _elements
    from test_wing_optimise import _starter

    from aeroengine.wing.estimate import estimate

    els = _elements(_starter())
    free = estimate(els, [0.0, 2.0], 15.0)["rows"]
    near = estimate(els, [0.0, 2.0], 15.0, ride_height=0.06)["rows"]
    far = estimate(els, [0.0], 15.0, ride_height=10.0)["rows"]
    assert near[0]["cl"] < free[0]["cl"] < 0  # more downforce near the ground
    assert far[0]["cl"] == pytest.approx(free[0]["cl"], rel=0.01)  # twenty chords up it is free air (at 3 m it still adds 2%)
    assert near[1]["cl"] > near[0]["cl"]  # turning the inverted wing nose-up still unloads it
