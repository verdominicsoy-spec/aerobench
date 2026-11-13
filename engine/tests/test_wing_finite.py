"""The finite-wing estimate: endplates help, long wings approach 2D."""

from __future__ import annotations

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

    # AR_eff 2 (2 m span, 1 m chord, no endplates), Cl -2 (downforce): the flow turns up by Cl/(pi AR) = 18.2 deg.
    assert induced_angle(-2.0, 2.0, 1.0, 0.0, None) == pytest.approx(18.24, abs=0.01)
    assert induced_angle(2.0, 2.0, 1.0, 0.0, None) == pytest.approx(-18.24, abs=0.01)  # a lifting wing: downwash


def test_ground_cuts_the_induced_angle():
    from aeroengine.wing.finite import ground_factor, induced_angle

    assert ground_factor(None, 1.0) == 1.0
    # Wieselsberger: sigma = (1 - 1.32 h/b) / (1.05 + 7.4 h/b); at h/b 0.1, 0.868 / 1.79.
    assert ground_factor(0.1, 1.0) == pytest.approx(1 - 0.868 / 1.79)
    # Held at the ends of the range the formula was made for.
    assert ground_factor(0.001, 1.0) == ground_factor(0.033, 1.0) and ground_factor(1.0, 1.0) == ground_factor(0.25, 1.0)
    assert induced_angle(-2.0, 2.0, 1.0, 0.0, 0.2) == pytest.approx(18.24 * ground_factor(0.2, 2.0), abs=0.01)


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
