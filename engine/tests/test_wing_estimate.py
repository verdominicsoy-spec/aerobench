"""The quick multi-element estimate against RANS (medium mesh, SA) on the
two-element starter wing: lift within 3%, drag within 20%."""

from __future__ import annotations

import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))
from test_wing_optimise import _starter  # noqa: E402

from aeroengine.wing.estimate import estimate  # noqa: E402


def _elements(w):
    return [{"coords": e.placed().tolist(), "unit": e.unit.tolist(), "chord": e.chord, "angle": e.angle,
             "inverted": e.inverted} for e in w.elements]


def test_matches_rans_on_the_starter_wing():
    r = estimate(_elements(_starter()), [0.0], 15.0)["rows"][0]
    assert r["cl"] == pytest.approx(-1.8834, rel=0.03)  # RANS medium mesh
    assert r["cd"] == pytest.approx(0.03629, rel=0.2)
    main, flap = r["elements"]
    # The main element has the flap behind it, so it is held below its stall onset; the flap is not.
    assert main["held_below_stall"] and not flap["held_below_stall"]
    assert sum(e["cl"] for e in r["elements"]) == pytest.approx(r["cl"])


def test_a_sweep_takes_about_a_second():
    estimate(_elements(_starter()), [0.0], 15.0)  # NeuralFoil's first load
    t = time.time()
    rows = estimate(_elements(_starter()), [float(a) for a in range(-6, 13)], 15.0)["rows"]
    assert time.time() - t < 5 and len(rows) == 19
    # An inverted wing: a bigger wing angle means less downforce.
    assert rows[0]["cl"] < rows[-1]["cl"]


def test_a_flap_turned_too_far_past_the_main_separates():
    """RANS's verdicts: the overnight study (this wing, main at 3 degrees)
    held the flap attached to 28.2 degrees and separated it from 29.0
    whatever the gap; with the main free, a NACA 6212 wing separated with
    the flap 42 degrees past the main though its effective angle stayed low."""
    from aeroengine.wing.airfoils import naca4
    from aeroengine.wing.design import layout
    from aeroengine.wing.estimate import MAX_DEFLECTION
    from aeroengine.wing.geometry import apply

    w = _starter()
    ok = estimate(_elements(w), [0.0], 15.0)["rows"][0]
    assert not ok["separating"] and ok["why"] is None and ok["elements"][1]["deflection"] == pytest.approx(22.0)
    held = estimate(_elements(apply(w, {"angle_1": 27.8, "gap_1": 0.0172})), [0.0], 15.0)["rows"][0]
    assert not held["separating"]  # overnight trial 40: attached in RANS
    steep = estimate(_elements(apply(w, {"angle_1": 3.0 + MAX_DEFLECTION + 1.0})), [0.0], 15.0)["rows"][0]
    assert steep["separating"] and steep["elements"][1]["past_stall"] and "turned" in steep["why"]

    six = layout([naca4("6212")] * 2, 0.44, True)
    far = apply(six, {"angle_0": -0.97, "angle_1": 41.2, "gap_1": 0.0069, "overlap_1": 0.0158})
    r = estimate(_elements(far), [0.0], 15.0)["rows"][0]
    assert r["elements"][1]["effective_angle"] < 15  # low: the main's downwash
    assert r["separating"] and r["why"].startswith("Flap 1 is turned 42.2")


def test_a_single_element_separates_short_of_its_stall_angle():
    from aeroengine.wing.airfoils import naca4
    from aeroengine.wing.geometry import Element

    def row(angle):
        e = Element(naca4("4412"), 0.3, angle, [0.0, 0.0], False)
        return estimate([{"coords": e.placed().tolist(), "unit": e.unit.tolist(), "chord": 0.3, "angle": angle,
                          "inverted": False}], [0.0], 15.0)["rows"][0]

    assert not row(5.0)["separating"]
    late = row(16.0)  # NeuralFoil stalls the 4412 here at 17 degrees: 16 is past it less 2
    assert late["separating"] and "stall angle" in late["why"] and late["elements"][0]["deflection"] is None


def test_a_main_element_past_stall_against_rans():
    """The NACA 6212 main-and-flap starting wing swept through stall with RANS
    (quick mesh, SA): attached to -6 degrees, separated at -9. The estimate's
    front-element lift ceiling, drag growth and separation line are fitted to it."""
    from aeroengine.wing.airfoils import naca4
    from aeroengine.wing.design import layout

    w = layout([naca4("6212")] * 2, 0.44, True)
    rows = {r["alpha"]: r for r in estimate(_elements(w), [0.0, -3.0, -6.0, -9.0], 15.0)["rows"]}
    rans = {0.0: (-2.1677, 0.03468), -3.0: (-2.4104, 0.04433), -6.0: (-2.5037, 0.06419)}
    for a, (cl, cd) in rans.items():
        assert rows[a]["cl"] == pytest.approx(cl, rel=0.03)
        assert rows[a]["cd"] == pytest.approx(cd, rel=0.10)
        assert not rows[a]["separating"]
    assert rows[-9.0]["separating"] and rows[-9.0]["elements"][0]["past_stall"]  # RANS: Cl -1.55, Cd 0.25, never settled


def test_flaps_separate_past_the_main_as_rans_found():
    """RANS (quick mesh, SA, 15 m/s, NACA 6212 starting layouts): a last flap
    24 degrees past the main held; 30 to 38 degrees past it lost its lift or
    separated, with every flap within 25 degrees of the one in front."""
    import aeroengine.wing.design as D
    from aeroengine.wing.airfoils import naca4
    from aeroengine.wing.estimate import estimate

    def separates(n, main, step):
        angles = tuple([float(main)] + [main + step * i for i in range(1, n)])
        old, D.ANGLES[n] = D.ANGLES[n], angles
        try:
            w = D.layout([naca4("6212")] * n, 0.44, True)
        finally:
            D.ANGLES[n] = old
        els = [{"coords": e.placed().tolist(), "unit": e.unit.tolist(), "chord": e.chord, "angle": e.angle,
                "inverted": e.inverted} for e in w.elements]
        return estimate(els, [0.0], 15.0)["rows"][0]["separating"]

    assert not separates(3, -2, 12) and not separates(4, -2, 8)  # 24 degrees: RANS attached
    assert separates(3, -2, 16) and separates(4, -2, 10) and separates(3, 2, 19)  # 32, 30, 38 degrees
