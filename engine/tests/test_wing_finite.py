"""The finite-wing estimate: endplates help, long wings approach 2D."""

from __future__ import annotations

import math

import numpy as np
import pytest

from aeroengine.wing.finite import car_contribution, effective_aspect_ratio, lift_factor


def test_endplates_and_span():
    # An FS rear wing: 1 m span, 0.44 m total chord, 0.25 m endplates.
    assert effective_aspect_ratio(1.0, 0.44, 0.0) == pytest.approx(2.273, abs=1e-3)
    assert effective_aspect_ratio(1.0, 0.44, 0.25) == pytest.approx(2.273 * 1.475, abs=1e-3)
    assert lift_factor(1.0, 0.44, 0.0) < lift_factor(1.0, 0.44, 0.25) < 1
    assert lift_factor(100.0, 0.44, 0.0) > 0.99  # a very long wing is nearly 2D


def test_car_contribution():
    cla, cda = car_contribution(-2.0, 0.04, 1.0, 0.44, 0.25)
    k = lift_factor(1.0, 0.44, 0.25)
    assert cla == pytest.approx(2.0 * k * 0.44)
    induced = (2.0 * k) ** 2 / (3.141592653589793 * effective_aspect_ratio(1.0, 0.44, 0.25))
    assert cda == pytest.approx((0.04 + induced) * 0.44)
    assert car_contribution(-2.0, 0.04, 1.0, 0.44, None, 0.8) == pytest.approx((2.0 * 0.44 * 0.8, 0.04 * 0.44 * 0.8))


def test_induced_angle_unloads_the_wing():
    from aeroengine.wing.finite import induced_angle

    # AR 2 (2 m span, 1 m chord, no endplates), Cl -2 (downforce): the flow turns up by about Cl/(pi AR) = 18.2 deg
    # (the lattice's span efficiency on so short a wing is 0.999).
    assert induced_angle(-2.0, 2.0, 1.0, 0.0, None) == pytest.approx(18.24, rel=0.005)
    assert induced_angle(2.0, 2.0, 1.0, 0.0, None) == pytest.approx(-18.24, rel=0.005)  # a lifting wing: downwash


def test_ground_cuts_the_induced_angle():
    from aeroengine.wing.finite import ground_factor, induced_angle

    assert ground_factor(None, 1.0) == 1.0
    # Wieselsberger: sigma = (1 - 1.32 h/b) / (1.05 + 7.4 h/b); at h/b 0.1, 0.868 / 1.79.
    assert ground_factor(0.1, 1.0) == pytest.approx(1 - 0.868 / 1.79)
    # Held at the ends of the range the formula was made for.
    assert ground_factor(0.001, 1.0) == ground_factor(0.033, 1.0) and ground_factor(1.0, 1.0) == ground_factor(0.25, 1.0)
    # The lattice's ground (the induced angle on AR 2 at h/b 0.1) lands on Wieselsberger's.
    assert induced_angle(-2.0, 2.0, 1.0, 0.0, 0.2) == pytest.approx(18.24 * ground_factor(0.2, 2.0), rel=0.03)


def test_endplates_down_to_the_ground_cut_the_induced_angle():
    from aeroengine.wing.finite import induced_angle

    flush = induced_angle(-1.0, 0.5245, 0.682, 0.315, 0.0966, planform=0.61)
    low = induced_angle(-1.0, 0.5245, 0.682, 0.315, 0.0966, planform=0.61, endplate_bottom=0.035)
    assert 0 < low < flush


def test_settle_finds_the_angle_the_flow_meets_the_wing_at():
    import math

    from aeroengine.wing.finite import settle

    calls = []

    def cl_at(a):  # a downforce wing losing 0.08 a degree the flow turns up, zero lift at +12 deg
        calls.append(a)
        return -0.08 * (12 - a)

    a, cl = settle(cl_at, 0.0, 2.0, 1.0, 0.0, None)
    k = 0.08 * 180 / math.pi / (math.pi * 2.0)  # AR 2: induced angle = k (12 - a)
    assert a == pytest.approx(12 * k / (1 + k), abs=0.05) and cl == pytest.approx(cl_at(a)) and len(calls) <= 6


def _linear_polar(lo=-10.0, hi=20.0):
    a = np.arange(lo, hi + 0.5, 1.0)
    return list(a), list(2 * np.pi * np.radians(a))


def test_one_strip_on_a_linear_polar_is_lifting_line():
    from aeroengine.wing.finite import couple_strips

    kappa = 0.08
    r = couple_strips([_linear_polar()], np.array([[kappa]]), np.array([1.0]), 5.0)
    want = 2 * np.pi * np.radians(5.0) / (1 + 2 * np.pi * kappa)
    assert r["converged"] and r["cl_wing"] == pytest.approx(want, rel=1e-3)
    assert r["alpha"][0] == pytest.approx(5.0 - np.degrees(kappa * want), abs=1e-3)
    assert r["out_of_range"] == [] and r["past_stall"] == [] and r["steep"] == []


def test_strips_weight_by_width_and_feel_each_other():
    from aeroengine.wing.finite import couple_strips

    k = np.array([[0.10, 0.02], [0.02, 0.05]])
    r = couple_strips([_linear_polar(), _linear_polar()], k, np.array([0.3, 0.1]), 5.0)
    cl = np.asarray(r["cl"])
    assert np.asarray(r["alpha"]) == pytest.approx(5.0 - np.degrees(k @ cl), abs=1e-3)
    assert r["cl_wing"] == pytest.approx((0.3 * cl[0] + 0.1 * cl[1]) / 0.4)
    assert cl[0] < cl[1]  # more downwash on the first


def test_a_strip_past_its_polar_is_flagged():
    from aeroengine.wing.finite import couple_strips

    r = couple_strips([_linear_polar(0.0, 5.0)], np.array([[0.01]]), np.array([1.0]), 8.0)
    assert r["out_of_range"] == [0]


def test_a_strip_past_the_lift_peak_is_flagged():
    from aeroengine.wing.finite import couple_strips

    polar = ([0.0, 4.0, 8.0, 12.0, 16.0], [0.0, 0.44, 0.88, 1.0, 0.6])
    r = couple_strips([polar], np.array([[0.005]]), np.array([1.0]), 15.0)
    assert r["past_stall"] == [0] and r["out_of_range"] == []


def test_a_strip_on_a_cliff_in_its_polar_is_flagged():
    # frontwing#1.02's section: Cl -3.2 at +8 deg, all of it gone by +9 (the main stalls on its pressure side).
    from aeroengine.wing.finite import couple_strips

    polar = ([0.0, 4.0, 8.0, 9.0, 12.0], [-4.4, -3.8, -3.2, 0.05, 0.2])
    r = couple_strips([polar], np.array([[0.12]]), np.array([1.0]), -7.45)
    assert r["steep"] == [0] and 8.0 < r["alpha"][0] < 9.0 and r["converged"]


def test_a_polar_falling_everywhere_is_past_stall():
    # A section's Cl rises with its angle (an inverted wing's toward zero); one that falls is stalled.
    from aeroengine.wing.finite import couple_strips

    polar = ([-10.0, 10.0], [-0.4, -2.6])
    r = couple_strips([polar, polar], np.array([[0.05, 0.01], [0.01, 0.05]]), np.array([1.0, 1.0]), 0.0)
    assert r["past_stall"] == [0, 1]


def test_strips_settle_on_a_polar_with_a_cliff():
    # frontwing#1.02's strips: Cl holds to +8.6 deg and is gone past it. Every strip's own equation is
    # still one-signed, so the coupled answer exists; a Newton step across the kink loses it.
    from aeroengine.wing.finite import couple_strips
    from aeroengine.wing.vlm import Lattice

    a = [2.0, 4.0, 6.0, 7.0, 8.0, 8.75, 9.5, 10.5]
    s = Lattice(span=0.5245, chord=0.6245, height=0.0966, endplate=0.315, endplate_bottom=0.035, drop=0.045).strips(6)
    # the cliff 0.1 deg later per mm higher off the ground
    polars = [(a, [-4.6 + 0.17 * x if x < 8.6 + 100 * (h - 0.0966) else 0.05 for x in a]) for h in s.height]
    r = couple_strips(polars, s.k * 0.682 / 0.6245, s.width, -7.45)
    assert r["converged"]
    gap = -7.45 - np.degrees(s.k * 0.682 / 0.6245 @ np.asarray(r["cl"])) - np.asarray(r["alpha"])
    assert np.abs(gap).max() < 1e-4


def test_a_polar_needs_two_angles():
    # A height whose solves mostly did not converge can leave one point: no slope, no polar.
    from aeroengine.wing.finite import couple_strips

    with pytest.raises(ValueError, match="two angles"):
        couple_strips([([6.0], [-3.9])], np.array([[0.1]]), np.array([1.0]), -7.45)


def test_one_element_keeps_the_mean_induced_angle():
    from aeroengine.wing.finite import element_turns

    assert element_turns(-2.0, [0.75], [1.0], 1.0, 0.25, 0.2, 0.05) == [0.0]


STATIONS, SHARES = [0.2, 0.55, 0.73, 0.89], [0.37, 0.31, 0.2, 0.12]


def test_element_turns_average_out_over_the_load():
    from aeroengine.wing.finite import element_turns

    t = element_turns(-2.0, STATIONS, SHARES, 0.5245, 0.682, 0.315, 0.0966, 0.6245, 0.035)
    assert sum(s * x for s, x in zip(SHARES, t)) == pytest.approx(0.0, abs=1e-9)


def test_flaps_of_a_short_downforce_wing_turn_the_unloading_way():
    # frontwing#1.02 at STAR's Cl: the flaps meet a steeper flow than the main (alpha's sense: positive unloads)
    from aeroengine.wing.finite import element_turns

    main, f1, f2, f3 = element_turns(-2.0, STATIONS, SHARES, 0.5245, 0.682, 0.315, 0.0966, 0.6245, 0.035)
    assert main < 0 < f1 < f2 < f3


EXTENTS = [(0.0, 0.39), (0.39, 0.68), (0.66, 0.86), (0.84, 1.0)]  # frontwing#1.02's elements along its planform


def test_element_turns_on_the_rans_loading_still_average_out():
    from aeroengine.wing.finite import element_turns

    t = element_turns(-2.0, STATIONS, SHARES, 0.5245, 0.682, 0.315, 0.0966, 0.6245, 0.035, extents=EXTENTS)
    assert sum(s * x for s, x in zip(SHARES, t)) == pytest.approx(0.0, abs=1e-9) and t[0] < 0 < t[-1]
    assert element_turns(-2.0, [0.75], [1.0], 1.0, 0.25, 0.2, 0.05, extents=[(0.0, 1.0)]) == [0.0]


def _frontwing_sections():
    """frontwing#1.02 as drawn (m): an inverted 4412 at each element's nose, chord and chord-line angle."""
    from aeroengine.wing.airfoils import naca4

    unit = naca4("4412") * np.array([1.0, -1.0])  # inverted: suction underneath
    out = []
    for nose, chord, deg in (((0.0139, 0.0615), 0.237, -10.37), ((0.242, 0.0376), 0.185, 2.63),
                             ((0.4191, 0.0597), 0.137, 22.13), ((0.5372, 0.1218), 0.123, 34.63)):
        a = math.radians(deg)
        rot = np.array([[math.cos(a), math.sin(a)], [-math.sin(a), math.cos(a)]])  # trailing edge up for deg > 0
        out.append(unit * chord @ rot + np.array(nose))
    return out


FRONT = dict(span=0.5245, chord=0.682, endplate=0.315, ride_height=0.0966, endplate_bottom=0.035)


def test_camber_line_of_a_symmetric_section_is_its_chord_line():
    from aeroengine.wing.airfoils import naca4
    from aeroengine.wing.vlm import camber_line

    line = camber_line(naca4("0012") * 0.5, 8)
    assert line[0] == pytest.approx([0.0, 0.0], abs=1e-3) and line[-1] == pytest.approx([0.5, 0.0], abs=1e-3)
    assert np.abs(line[:, 1]).max() < 1e-3
    assert camber_line(naca4("4412") * 0.5, 8)[4, 1] > 0.015  # 4% camber, near its peak


def test_element_turns_on_the_sections_keep_one_element_at_the_mean():
    from aeroengine.wing.finite import element_turns

    one = _frontwing_sections()[:1]
    assert element_turns(-2.0, [0.75], [1.0], 0.5245, 0.237, 0.315, 0.0966, endplate_bottom=0.035, sections=one,
                         alpha=-7.45) == [0.0]


def test_element_turns_on_the_sections_average_out_and_unload_the_flaps():
    from aeroengine.wing.finite import element_turns

    t = element_turns(-2.0, STATIONS, SHARES, FRONT["span"], FRONT["chord"], FRONT["endplate"], FRONT["ride_height"],
                      endplate_bottom=FRONT["endplate_bottom"], sections=_frontwing_sections(), alpha=-7.45)
    assert sum(s * x for s, x in zip(SHARES, t)) == pytest.approx(0.0, abs=1e-9)
    assert t[0] < 0 < t[1] and t[0] < t[2] and t[0] < t[3]


def test_the_sections_bend_matches_each_elements_turn_at_its_three_quarter_chord():
    from aeroengine.wing.finite import element_turns

    secs = _frontwing_sections()
    kw = dict(endplate_bottom=FRONT["endplate_bottom"], sections=secs, alpha=-7.45)
    args = (-2.0, STATIONS, SHARES, FRONT["span"], FRONT["chord"], FRONT["endplate"], FRONT["ride_height"])
    turns = element_turns(*args, **kw)
    lo = min(float(s[:, 0].min()) for s in secs)
    plan = max(float(s[:, 0].max()) for s in secs) - lo
    at = []
    for s in secs:
        te = 0.5 * (s[0] + s[-1])
        nose = s[int(np.argmax(np.linalg.norm(s - te, axis=1)))]
        at.append((nose[0] + 0.75 * (te[0] - nose[0]) - lo) / plan)
    assert element_turns(*args, at=at, **kw) == pytest.approx(turns, abs=0.05)


def test_consistent_turns_in_free_air_are_the_onset():
    # off the ground, turning the section is turning the flow
    from aeroengine.wing.finite import consistent_turns

    secs = _frontwing_sections()
    onset = [10.0, 14.0, 16.0, 15.0]
    assert consistent_turns(secs, -7.45, None, onset) == pytest.approx(onset, abs=1e-9)


def test_consistent_turns_by_the_ground_carry_what_the_turned_flow_does():
    # frontwing#1.02: the section turned 17 deg nose up lifts its main off the ground; the main is turned
    # less than its onset, so its load (in the 2D lattice) is the one the turned flow gives it
    from aeroengine.wing.finite import consistent_turns, section_loads

    secs = _frontwing_sections()
    onset = [10.0, 18.0, 21.0, 19.0]
    t = consistent_turns(secs, -7.45, 0.0966, onset)
    assert t[0] < onset[0]
    target = section_loads(secs, -7.45, 0.0966, onset=onset)
    assert section_loads(secs, -7.45, 0.0966, turns=t) == pytest.approx(target, rel=1e-3)


def test_consistent_turn_of_a_single_element_by_the_ground_is_nearly_its_onset():
    # Zerihan's wing (validated within 3%): 1 deg of flow is 0.96 deg of turn at h/c 0.45
    from aeroengine.wing.airfoils import naca4
    from aeroengine.wing.finite import consistent_turns

    wing = naca4("6412") * np.array([0.2234, -0.2234])
    (t,) = consistent_turns([wing], 0.0, 0.1, [1.5])
    assert 0.9 * 1.5 < t < 1.5
