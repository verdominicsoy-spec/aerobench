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


def test_the_ground_estimate_against_rans():
    """The NACA 6212 main-and-flap starting wing over a moving ground, RANS on
    the quick mesh (SA): Cl -2.8274 at 300 mm and -3.4836 at 150 mm (-2.1677
    in free air); at 60 mm it never settled. The image method's gain alone
    was 42% and 77%, RANS's 30% and 61%: the estimate keeps GROUND_LIFT of it."""
    from aeroengine.wing.design import layout
    from aeroengine.wing.estimate import estimate

    w = layout([naca4("6212")] * 2, 0.44, True)
    els = [{"coords": e.placed().tolist(), "unit": e.unit.tolist(), "chord": e.chord, "angle": e.angle,
            "inverted": e.inverted} for e in w.elements]
    for h, (cl, cd) in {0.30: (-2.8274, 0.04758), 0.15: (-3.4836, 0.07074)}.items():
        r = estimate(els, [0.0], 15.0, ride_height=h)["rows"][0]
        assert r["cl"] == pytest.approx(cl, rel=0.04)
        assert r["cd"] == pytest.approx(cd, rel=0.12)
        assert not r["separating"]
        assert r["cl_free_air"] == pytest.approx(-2.1677, rel=0.03)
        assert sum(e["cl"] for e in r["elements"]) == pytest.approx(r["cl"])
    low = estimate(els, [0.0], 15.0, ride_height=0.06)["rows"][0]
    assert low["separating"] and low["why"].startswith("Main")
