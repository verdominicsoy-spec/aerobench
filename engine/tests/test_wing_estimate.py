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
    assert r["elements"][1]["effective_angle"] < 17  # low against its 42-degree turn: the main's downwash
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

    # Again with the default RANS (SST-LM, fine mesh), 13 Nov 2026: 3 elements 32 degrees past the main,
    # Flap 2 separated from 11% of its chord; 4 elements 30 degrees past, Flaps 2 and 3 from 16-21%. But
    # frontwing#1's Flap 2 held 32.5 degrees past its main: the angle past the main depends on the
    # sections and slots, so the estimate warns there and RANS decides, rather than failing the wing.
    def warned(n, main, step):
        old, D.ANGLES[n] = D.ANGLES[n], tuple([float(main)] + [main + step * i for i in range(1, n)])
        try:
            w = D.layout([naca4("6212")] * n, 0.44, True)
        finally:
            D.ANGLES[n] = old
        els = [{"coords": e.placed().tolist(), "unit": e.unit.tolist(), "chord": e.chord, "angle": e.angle,
                "inverted": e.inverted} for e in w.elements]
        return [w for w in estimate(els, [0.0], 15.0)["rows"][0]["warnings"] if "past the main" in w]

    assert not warned(3, -2, 12) and not warned(4, -2, 8)  # 24 degrees: RANS attached
    for case in ((3, -2, 16), (4, -2, 10), (3, 2, 19)):  # 32, 30, 38 degrees: RANS separated
        assert any("past the main" in w for w in warned(*case))


def test_an_element_alone_has_no_upwash_at_any_angle():
    """Nothing round it, so the angle that gives its in-place lift alone is
    the freestream's. A straight-line fit of lift against angle (0 to 5
    degrees) put it 0.5 degrees off at 18 degrees, and 30 off on the 30P30N
    slat, whose in-place angle sits far outside the fit."""
    from aeroengine.wing.airfoils import naca4
    from aeroengine.wing.geometry import Element

    e = Element(naca4("4412"), 0.3, 18.0, [0.0, 0.0], False)
    els = [{"coords": e.placed().tolist(), "unit": e.unit.tolist(), "chord": 0.3, "angle": 18.0, "inverted": False}]
    for row in estimate(els, [-10.0, 0.0, 6.0], 15.0)["rows"]:
        assert abs(row["elements"][0]["upwash"]) < 0.01


def test_label_names_slats_ahead_of_the_main():
    from aeroengine.wing.geometry import label

    assert [label(i) for i in range(3)] == ["Main", "Flap 1", "Flap 2"]
    assert [label(i, main=1) for i in range(3)] == ["Slat", "Main", "Flap 1"]
    assert [label(i, main=2) for i in range(4)] == ["Slat 1", "Slat 2", "Main", "Flap 1"]


def _p30(alphas):
    """30P30N (slat, main, flap at 30/30 deg) at the tunnel's Reynolds number, 9 million on the stowed chord."""
    import json

    c = json.loads((Path(__file__).parent / "data" / "30p30n.json").read_text())
    els = [{k: e[k] for k in ("coords", "unit", "chord", "angle", "inverted")} for e in c["elements"]]
    rho, mu = 1.225, 1.81e-5
    return estimate(els, alphas, 9.0e6 * mu / (rho * c["ref_chord"]), rho=rho, mu=mu, ref_chord=c["ref_chord"])["rows"]


def test_a_slatted_wing_against_the_tunnel():
    """NASA LTPT, 30P30N (Klausmeyer and Lin, NASA TM-112858): Cl 3.135 at 8.10
    degrees, 3.976 at 16.21, 4.278 at 21.34 (about Cl max), 4.170 at 23.28. Before
    slats were known the estimate called the slat the main and the main a flap
    turned 47 degrees, and read 28 to 46% low."""
    rows = _p30([8.10, 16.21, 21.34, 23.28])
    for r, cl in zip(rows[:3], (3.135, 3.976, 4.278)):
        assert not r["separating"], r["why"]
        assert r["cl"] == pytest.approx(cl, rel=0.08)
        assert r["elements"][0]["cl"] > 0  # the slat lifts
        assert all(e["deflection"] is None for e in r["elements"][:2])
    assert rows[3]["separating"] and rows[3]["why"].startswith("Slat")


def test_the_deflection_limit_rises_with_reynolds_number():
    """25 degrees where RANS fixed it (flaps to 1.4 x 10^5), 35 at the 30P30N flap's 2.7 x 10^6."""
    from aeroengine.wing.estimate import max_deflection

    assert max_deflection(5e4) == max_deflection(1.5e5) == pytest.approx(25.0)
    assert max_deflection(2.7e6) == max_deflection(9e6) == pytest.approx(35.0)
    assert 25.0 < max_deflection(5e5) < 35.0


def test_a_flap_as_big_as_the_main_is_not_a_slat_case():
    from aeroengine.wing.estimate import main_index

    assert main_index([0.3, 0.32]) == 0
    assert main_index([0.15, 0.83, 0.30]) == 1


def test_a_flap_is_held_to_the_element_in_front_not_to_the_main():
    # frontwing#1: Flap 2 is 30 deg past the main, Flap 3 42 deg, each 13-16 deg past the one in front.
    # RANS held Flap 2 attached 32.5 deg past the main; the 25 deg limit was fitted flap to element in front.
    import json
    from pathlib import Path

    from aeroengine.wing.estimate import estimate

    w = json.loads((Path(__file__).parent / "data" / "frontwing1_study.json").read_text())
    r = estimate(w["elements"], [0.0], 20.0, 1.184, 1.81e-5, 9.0, w["ref_chord"])["rows"][0]
    assert "past the main" not in (r["why"] or "")


def test_a_single_element_met_from_its_pressure_side_separates():
    """RANS separated two single elements at negative angles from the leading edge of their pressure side
    (jobs of 17 Nov 2026); the estimate only looked at the suction side and called both attached."""
    from aeroengine.wing.airfoils import naca4
    from aeroengine.wing.geometry import Element

    def row(angle):
        e = Element(naca4("4412"), 0.3, angle, [0.0, 0.0], False)
        return estimate([{"coords": e.placed().tolist(), "unit": e.unit.tolist(), "chord": 0.3, "angle": angle,
                          "inverted": False}], [0.0], 15.0)["rows"][0]

    assert not row(-4.0)["separating"]
    late = row(-14.0)
    assert late["separating"] and "pressure side" in late["why"]


def test_a_flap_turned_too_little_for_the_flow_off_the_main_separates():
    """design-12 #455: RANS separated Flap 1, 2.3 degrees past the main, from 62% of its chord. The estimate
    read it attached and 55% high."""
    import json

    w = json.loads((Path(__file__).parent / "data" / "underturned_flap.json").read_text())
    r = estimate(w["elements"], [0.0], w["speed"], w["rho"], w["mu"], ref_chord=w["ref_chord"],
                 ride_height=w["ride_height"])["rows"][0]
    assert r["separating"] and r["why"].startswith("Flap 1") and "pressure side" in r["why"]


def test_a_section_with_no_stall_in_its_polar_is_named():
    """design-4 #1223's Flap 2: NeuralFoil's lift is highest at the end of the sweep, so it gives no stall angle and
    the estimate had silently judged the flap against 25 degrees. It now says so instead."""
    import json

    import numpy as np

    from aeroengine.wing.geometry import Element

    f = json.loads((Path(__file__).parent / "data" / "no_stall_flap.json").read_text())
    e = Element(np.asarray(f["unit"]), f["chord"], 0.0, [0.0, 0.0], False)
    r = estimate([{"coords": e.placed().tolist(), "unit": f["unit"], "chord": f["chord"], "angle": 0.0,
                   "inverted": False}], [0.0], 15.0)["rows"][0]
    assert r["elements"][0]["stall_found"] is False
    assert any("no stall angle for main's section" in w for w in r["warnings"])


def test_a_section_that_stalls_in_its_polar_gives_no_stall_warning():
    from aeroengine.wing.airfoils import naca4
    from aeroengine.wing.geometry import Element

    e = Element(naca4("4412"), 0.3, 4.0, [0.0, 0.0], False)
    r = estimate([{"coords": e.placed().tolist(), "unit": e.unit.tolist(), "chord": 0.3, "angle": 4.0,
                   "inverted": False}], [0.0], 15.0)["rows"][0]
    assert r["elements"][0]["stall_found"] is True and not r["warnings"]
