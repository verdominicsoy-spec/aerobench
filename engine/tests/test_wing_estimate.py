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


def test_a_flap_past_its_stall_angle_is_separating():
    from aeroengine.wing.geometry import apply

    w = _starter()
    ok = estimate(_elements(w), [0.0], 15.0)["rows"][0]
    assert not ok["separating"] and ok["elements"][1]["stall_angle"] == pytest.approx(15.0, abs=1.0)
    # Every overnight RANS trial with the flap past 29 degrees failed to settle.
    steep = estimate(_elements(apply(w, {"angle_1": 31.0})), [0.0], 15.0)["rows"][0]
    assert steep["separating"] and steep["elements"][1]["past_stall"]


def test_a_narrow_slot_keeps_the_flap_attached_further():
    """The overnight study: at 26.9 degrees the flap stayed attached in RANS
    with a 9.1 mm gap, and separated at 27.8 degrees with 17.2 mm."""
    from aeroengine.wing.estimate import SLOT_FITTED, separation_angle
    from aeroengine.wing.geometry import apply

    assert separation_angle(15.0, None) == 13.0
    assert separation_angle(15.0, 0.0475) == pytest.approx(13.0)
    assert separation_angle(15.0, 0.03) > separation_angle(15.0, 0.06)
    # Held at the ends of the gaps it was fitted on.
    assert separation_angle(15.0, 0.001) == separation_angle(15.0, SLOT_FITTED[0] / 100)
    assert separation_angle(15.0, 0.2) == separation_angle(15.0, SLOT_FITTED[1] / 100)

    w = _starter()
    narrow = estimate(_elements(apply(w, {"angle_1": 26.9, "gap_1": 0.0091})), [0.0], 15.0)["rows"][0]
    wide = estimate(_elements(apply(w, {"angle_1": 27.8, "gap_1": 0.0172})), [0.0], 15.0)["rows"][0]
    assert narrow["elements"][1]["gap_ratio"] == pytest.approx(0.0091 / 0.3, rel=0.02)
    assert not narrow["separating"] and wide["separating"]


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
