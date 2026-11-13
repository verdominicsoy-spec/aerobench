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
    was 42% and 77%, RANS's 30% and 61%: the estimate keeps ground_share of
    it, one curve fitted to these and the lower heights below (so within 5%
    here, not the 3% a fit to these two alone gave)."""
    from aeroengine.wing.design import layout
    from aeroengine.wing.estimate import estimate

    w = layout([naca4("6212")] * 2, 0.44, True)
    els = [{"coords": e.placed().tolist(), "unit": e.unit.tolist(), "chord": e.chord, "angle": e.angle,
            "inverted": e.inverted} for e in w.elements]
    for h, (cl, cd) in {0.30: (-2.8274, 0.04758), 0.15: (-3.4836, 0.07074)}.items():
        r = estimate(els, [0.0], 15.0, ride_height=h)["rows"][0]
        assert r["cl"] == pytest.approx(cl, rel=0.05)
        assert r["cd"] == pytest.approx(cd, rel=0.12)
        assert not r["separating"]
        assert r["cl_free_air"] == pytest.approx(-2.1677, rel=0.03)
        assert sum(e["cl"] for e in r["elements"]) == pytest.approx(r["cl"])
    low = estimate(els, [0.0], 15.0, ride_height=0.06)["rows"][0]
    # RANS never settled at 60 mm (image gain 2.68); the main's own angle in free air (20 deg, stall 15) holds,
    # and whether the ground separates it the estimate cannot tell (Zerihan's wing held to 6.0): it warns.
    assert any("ground" in w for w in low["warnings"])


def _els(w):
    return [{"coords": e.placed().tolist(), "unit": e.unit.tolist(), "chord": e.chord, "angle": e.angle,
             "inverted": e.inverted} for e in w.elements]


# RANS (quick mesh, SA, 15 m/s, converged) over a moving ground, as a gain over
# free air: NACA 6212 main and flap (0.44 m) and a NACA 4412 main alone (0.27 m).
# The gain peaks and falls as the gap under the wing closes.
RANS_GAIN = {
    "6212": (-2.1677, {0.30: 0.30, 0.15: 0.61, 0.10: 0.72, 0.03: 0.09}),
    "4412": (-0.7230, {0.30: 0.09, 0.10: 0.37, 0.05: 0.60, 0.03: 0.47}),
}


@pytest.mark.parametrize("name", list(RANS_GAIN))
def test_the_ground_gain_follows_rans_down_to_30_mm(name):
    from aeroengine.wing.design import layout
    from aeroengine.wing.estimate import estimate

    w = layout([naca4(name)] * 2, 0.44 if name == "6212" else 0.40, True)
    els = _els(w) if name == "6212" else _els(w)[:1]
    free = estimate(els, [0.0], 15.0)["rows"][0]["cl"]
    for h, rans in RANS_GAIN[name][1].items():
        r = estimate(els, [0.0], 15.0, ride_height=h)["rows"][0]
        assert r["cl"] / free - 1 == pytest.approx(rans, abs=0.15), f"{name} at {h * 1000:.0f} mm"


def test_the_ground_never_more_than_doubles_the_lift():
    """The image method's gain grows without limit as the gap closes (12 times
    free air at 30 mm on a 374 mm main); RANS never passed +72%."""
    from aeroengine.wing.design import layout
    from aeroengine.wing.estimate import estimate

    els = _els(layout([naca4("6212")] * 3, 0.50, True))
    free = estimate(els, [0.0], 15.0)["rows"][0]["cl"]
    for h in (0.01, 0.02, 0.03, 0.05, 0.08):
        assert estimate(els, [0.0], 15.0, ride_height=h)["rows"][0]["cl"] / free < 1.8


def test_a_wing_separating_in_free_air_separates_over_the_ground_too():
    """A ground loads the wing more and separates it sooner (the 6212 wing held
    in free air and separated at 60 mm): a stalled study wing at 30 mm must not
    read as attached. Its RANS: Cl -1.81, Cd 0.51 at 30 mm; Cd 0.36 in free air."""
    import json
    from pathlib import Path

    from aeroengine.wing.estimate import estimate

    w = json.loads((Path(__file__).parent / "data" / "stalled_wing.json").read_text())
    args = (w["elements"], [0.0], w["speed"], w["rho"], w["mu"], 5.0)  # n_crit 5, as Wing Lab runs it
    assert estimate(*args, ref_chord=w["ref_chord"])["rows"][0]["separating"]
    low = estimate(*args, ref_chord=w["ref_chord"], ride_height=0.03)["rows"][0]
    assert low["separating"]
    # Separating, so the number means little (-2.75 now; -2.48 by the straight-line lift fit), but not
    # the image's whole gain: it was -24, 12 times free air.
    assert -2 * 1.81 < low["cl"] < 0


def _frontwing():
    import json
    from pathlib import Path

    w = json.loads((Path(__file__).parent / "data" / "frontwing1_study.json").read_text())
    return w["elements"], w["ref_chord"]


def test_a_cascade_near_the_ground_is_judged_on_sane_angles():
    # frontwing#1 (4 elements) over a ground: the image method piles 5.5 times the free-air load on the
    # main at 60 mm, and inverting that on the main alone read 42 deg "in place" at 300 mm and 145 at
    # 50 mm, so every optimiser trial failed. The cascade's loading is judged on the free-air angle;
    # the ground's own separation on the image's whole-wing gain.
    from aeroengine.wing.estimate import estimate

    els, ref = _frontwing()
    free = estimate(els, [0.0], 20.0, 1.184, 1.81e-5, 9.0, ref)["rows"][0]
    high = estimate(els, [0.0], 20.0, 1.184, 1.81e-5, 9.0, ref, ride_height=0.30)["rows"][0]
    low = estimate(els, [0.0], 20.0, 1.184, 1.81e-5, 9.0, ref, ride_height=0.05)["rows"][0]
    assert not free["separating"], free["why"]  # RANS: main attached in free air
    assert not high["separating"] and not any("ground" in w for w in high["warnings"]), high["why"]  # image gain 0.68
    assert not low["separating"] and any("ground" in w for w in low["warnings"])  # image gain 5.1: RANS decides
    assert all("in place" not in w for w in (low["why"] or "").split("; ") if w.startswith("Main"))


def test_the_ground_separates_a_wing_between_the_gains_rans_bracketed():
    # Inviscid whole-wing gains against RANS: NACA 6212 attached at 100 mm (1.45), separated at 60 (2.68);
    # NACA 4412 alone still gaining at 50 mm (1.42), losing by 30 (2.78).
    from aeroengine.wing.design import layout
    from aeroengine.wing.estimate import GROUND_SEPARATION_GAIN, estimate

    # But Zerihan's Tyrrell 026 wing (built for the ground) held, its downforce still rising, at image gains
    # 3.1 (h/c 0.134) to 6.0 (0.067): the gain does not decide it, so the estimate warns and RANS decides.
    assert 1.45 < GROUND_SEPARATION_GAIN < 2.68
    els = _els(layout([naca4("6212")] * 2, 0.44, True))
    assert not estimate(els, [0.0], 15.0, ride_height=0.10)["rows"][0]["warnings"]
    low = estimate(els, [0.0], 15.0, ride_height=0.06)["rows"][0]
    assert not low["separating"] and any("ground" in w for w in low["warnings"])


def test_a_front_element_reports_the_angle_it_is_judged_on():
    # The optimiser's margin reads effective_angle: over a ground it was the inflated reading (59 deg on
    # frontwing#2's main at 35 mm) while the verdict used the free-air one, so every trial's downforce was
    # spent on the margin and no study had a best.
    from aeroengine.wing.estimate import estimate

    els, ref = _frontwing()
    free = estimate(els, [0.0], 20.0, 1.184, 1.81e-5, 9.0, ref)["rows"][0]["elements"][0]["effective_angle"]
    low = estimate(els, [0.0], 20.0, 1.184, 1.81e-5, 9.0, ref, ride_height=0.05)["rows"][0]["elements"][0]["effective_angle"]
    assert low == pytest.approx(free, abs=0.5)
