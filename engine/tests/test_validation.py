"""The quick methods against published wind-tunnel data (aeroengine.validation).

These pin how accurate the viscous core is today, so a change that makes it
worse shows up. The UIUC cases download the data from the University of
Illinois the first time (it is not committed); without a connection they
are skipped and say so."""

from __future__ import annotations

import pytest

from aeroengine import validation as v
from aeroengine.job import EngineError

SAMPLE_RUNS = """Airfoil: E387 (C)
Builder: J. Robertson
Comment: clean

Number of Reynolds #'s:
 2

Average Reynolds #:
 59700
Number of angles of attack:
 3
 alpha /   Cl   /  Cd   /  Spanwise Cd's >>>
 -6.16  -0.356   0.0657   0.0542   0.0561
  0.06   0.270   0.0230   0.0223   0.0190
 10.26   1.232   0.0318   0.0333   0.0292
Tabulated from data in file CL01573.DAT & reduced using program Q05.01D

Average Reynolds #:
 459200
Number of angles of attack:
 1
 alpha /   Cl   /  Cd   /  Spanwise Cd's >>>
  0.02   0.336   0.0071   0.0073   0.0073
"""

SAMPLE_COORDS = """::::::::::::::
e387a.dap
::::::::::::::
  E387 (A)
""" + "\n".join(f"  {1 - k / 20:.5f}  {0.01 * (1 - k / 20) * k / 20:.5f}" for k in range(21)) + "\n" + \
    "\n".join(f"  {k / 20:.5f}  {-0.005 * k / 20 * (1 - k / 20):.5f}" for k in range(1, 21)) + "\n"


def test_reading_the_uiuc_files():
    runs = v.parse_runs(SAMPLE_RUNS)
    assert [r["re"] for r in runs] == [59700, 459200]
    assert runs[0]["airfoil"] == "E387 (C)" and runs[0]["comment"] == "clean"
    assert runs[0]["rows"] == [(-6.16, -0.356, 0.0657), (0.06, 0.270, 0.0230), (10.26, 1.232, 0.0318)]
    coords = v.parse_coords(SAMPLE_COORDS)
    assert list(coords) == ["e387a.dap"] and coords["e387a.dap"].shape == (41, 2)
    assert v._model("E387 (A)", coords) == "e387a.dap"


def test_naca0012_against_ladson():
    """Re 6 million, tripped (NASA TM-4074): the viscous core within 5% of
    the measured lift and drag up to 2 degrees short of maximum lift."""
    r = v.compare(v.ladson_case())
    assert r["lift_error_mean"] <= 0.05 and r["drag_error_mean"] <= 0.05
    assert r["stalled"] and r["cl_max"] == pytest.approx(1.63, abs=0.01)


def _uiuc_or_skip():
    try:
        return v.uiuc_cases()
    except EngineError as exc:
        pytest.skip(f"UIUC data not available here: {exc.msg}")


def test_high_lift_sections_at_fs_reynolds_numbers():
    """Where the quick estimate stands on FS-type sections at Re 200,000 to
    300,000 (the numbers are what it gets today; docs/DECISIONS.md has the
    whole table). It reads lift high on every one, most on the most cambered."""
    cases = {c.key: v.compare(c) for c in _uiuc_or_skip()}
    assert {"s1223_200k", "s1223_250k", "s1223_300k", "e387_200k", "e387_300k", "fx63137_300k"} <= set(cases)
    assert all(c["lift_error_signed"] > 0 for c in cases.values())
    assert cases["e387_300k"]["lift_error_mean"] <= 0.06
    assert 0.12 <= cases["s1223_300k"]["lift_error_mean"] <= 0.22  # S1223's lift reads high by about a sixth
    # Drag within 25% except E387's, 28 to 37% off: its laminar separation
    # bubble's drag is what the viscous core gets worst.
    assert all(c["drag_error_mean"] <= 0.25 for k, c in cases.items() if not k.startswith("e387"))
    assert all(c["drag_error_mean"] <= 0.40 for c in cases.values())


def test_survey_of_every_clean_uiuc_run():
    _uiuc_or_skip()
    s = v.survey()
    if s["skipped"]:
        pytest.skip("; ".join(s["skipped"]))
    assert s["runs"] >= 150 and s["sections"] >= 45
    assert s["lift_median"] <= 0.09 and s["lift_signed_median"] > 0  # reads high, by about 8% in the middle
    assert s["drag_median"] <= 0.10 and s["drag_within_target"] >= 0.8
