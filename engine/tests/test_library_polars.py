"""Library polars: each section's maximum lift and best L/D at one Reynolds number."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from aeroengine.wing import library_polars
from aeroengine.wing.airfoils import build_index, naca4


def test_cambered_sections_lift_more_and_stall_later():
    flat = library_polars.summary(naca4("0012"), 3e5)
    cambered = library_polars.summary(naca4("4412"), 3e5)
    assert 1.0 < flat["cl_max"] < cambered["cl_max"] < 2.0
    assert cambered["ld_max"] > flat["ld_max"] > 20
    assert 5 <= cambered["alpha_ld_max"] < cambered["alpha_cl_max"] <= 20
    assert flat["trusted"] and cambered["trusted"]


def test_the_whole_library_in_seconds(engine, tmp_path: Path):
    build_index(tmp_path)  # the NACA set
    code, events, err = engine.run("airfoil-polars", {"params": {"re": 2e5, "data_dir": str(tmp_path)}},
                                   tmp_path / "job", timeout=120)
    assert code == 0, err
    saved = json.loads((tmp_path / "airfoils" / "polars.json").read_text())
    assert saved["re"] == 2e5 and len(saved["rows"]) > 150
    assert saved["rows"]["naca/4412"]["cl_max"] > saved["rows"]["naca/0012"]["cl_max"]
    assert all(np.isfinite(r["ld_max"]) for r in saved["rows"].values())


def test_needs_a_library(tmp_path: Path):
    with pytest.raises(Exception, match="no airfoil library"):
        library_polars.build(tmp_path / "airfoils", 3e5)
