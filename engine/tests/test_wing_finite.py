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
