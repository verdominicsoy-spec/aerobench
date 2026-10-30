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
