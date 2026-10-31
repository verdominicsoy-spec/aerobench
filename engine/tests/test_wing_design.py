"""The starting wing for a design from scratch."""

from __future__ import annotations

from pathlib import Path

from aeroengine.wing.airfoils import build_index, naca4
from aeroengine.wing.design import layout, starter, variables


def test_layout_fits_the_rules_box():
    box = (-0.05, -0.05, 0.40, 0.25)
    w = layout([naca4("4412")] * 3, 0.60, True, box)  # asked for more chord than fits
    assert not w.issues()
    assert sum(e.chord for e in w.elements) < 0.60
    v = variables(w)
    assert [x.name for x in v] == ["angle_0", "angle_1", "gap_1", "overlap_1", "angle_2", "gap_2", "overlap_2"]


def test_starter_picks_a_high_lift_section(engine, tmp_path: Path):
    build_index(tmp_path)  # the NACA set
    out = starter(tmp_path / "airfoils", elements=2, chord_total=0.44, min_thickness=0.10)
    assert out["ranked"] > 50 and len(out["tried"]) == 6
    assert len(out["elements"]) == 2 and out["elements"][0]["key"].startswith("naca/")
    best = max(t["load"] for t in out["tried"] if t["valid"])
    assert out["section"]["key"] in [t["key"] for t in out["tried"] if t["load"] == best]
    assert int(out["section"]["key"][-2:]) >= 10  # the thickness floor held
    assert int(out["section"]["key"][5]) >= 4  # cambered: the high-lift end of the NACA set
    assert out["seconds"] < 20
