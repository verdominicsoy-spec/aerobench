"""Quick viscous polars (NeuralFoil): physics sanity, not NeuralFoil's own accuracy."""

from __future__ import annotations

import numpy as np
import pytest

from aeroengine.job import EngineError
from aeroengine.wing.airfoils import naca4
from aeroengine.wing.viscous import polar, reynolds


def test_reynolds():
    assert reynolds(20, 0.3) == pytest.approx(1.225 * 20 * 0.3 / 1.81e-5)
    with pytest.raises(EngineError):
        reynolds(0, 0.3)


def test_symmetric_section_and_ladson_range():
    """NACA 0012 at Re 6 million: lift slope near 0.1 per degree and a
    laminar-assisted Cd at zero lift in the 0.004 to 0.007 range (Ladson's
    tripped value is about 0.008)."""
    rows = polar(naca4("0012"), [-4, 0, 4], 6e6)["rows"]
    assert rows[0]["cl"] == pytest.approx(-rows[2]["cl"], abs=0.01)
    assert rows[0]["cd"] == pytest.approx(rows[2]["cd"], rel=0.05)
    assert abs(rows[1]["cl"]) < 0.01
    slope = (rows[2]["cl"] - rows[0]["cl"]) / 8
    assert 0.095 < slope < 0.115
    assert 0.004 < rows[1]["cd"] < 0.007
    assert all(r["trusted"] for r in rows)


def test_reynolds_number_and_transition_trends():
    low = polar(naca4("4412"), [2.0], 2e5)["rows"][0]
    high = polar(naca4("4412"), [2.0], 2e6)["rows"][0]
    assert low["cd"] > high["cd"]
    sweep = polar(naca4("4412"), [0, 4, 8, 12], 5e5)["rows"]
    xtr = [r["transition_suction"] for r in sweep]
    assert all(a >= b - 1e-6 for a, b in zip(xtr, xtr[1:]))  # moves forward on the suction side
    assert xtr[0] > 0.3 and xtr[-1] < 0.2


def test_inverted_mirrors():
    up = polar(naca4("4412"), [6.0], 5e5)["rows"][0]
    down = polar(naca4("4412"), [6.0], 5e5, inverted=True)["rows"][0]
    assert down["cl"] == pytest.approx(-up["cl"]) and down["cd"] == pytest.approx(up["cd"])
    assert down["alpha"] == 6.0
    assert down["transition_suction"] == pytest.approx(up["transition_suction"])


def test_bad_input():
    with pytest.raises(EngineError):
        polar(naca4("0012")[:5], [0], 1e6)
    with pytest.raises(EngineError):
        polar(naca4("0012"), [0], 10)
