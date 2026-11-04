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
    assert [x.name for x in v] == ["angle_0", "angle_1", "gap_1", "overlap_1", "angle_2", "gap_2", "overlap_2",
                                   "chord_0", "chord_1", "chord_2"]
    # Every slot stays overlapped: the estimate's slot rule knows nothing else.
    assert all(x.low > 0 for x in v if x.kind == "overlap")


def test_four_and_five_element_layouts():
    box = (-0.05, -0.05, 0.40, 0.25)
    for n in (4, 5):
        w = layout([naca4("4412")] * n, 0.60, True, box)
        assert not w.issues() and len(w.elements) == n
        # Flaps step steeper, each starting where the one before ends.
        assert [e.angle for e in w.elements] == sorted(e.angle for e in w.elements)
        assert len(variables(w)) == 1 + 3 * (n - 1) + n


def test_starter_picks_a_high_lift_section(engine, tmp_path: Path):
    build_index(tmp_path)  # the NACA set
    out = starter(tmp_path / "airfoils", elements=2, chord_total=0.44, min_thickness=0.10)
    assert out["ranked"] > 50 and len(out["tried"]) == 6
    assert len(out["elements"]) == 2 and out["elements"][0]["key"].startswith("naca/")
    best = max(t["load"] for t in out["tried"] if t["valid"])
    assert out["section"]["key"] in [t["key"] for t in out["tried"] if t["load"] == best]
    assert int(out["section"]["key"][-2:]) >= 10  # the thickness floor held
    assert int(out["section"]["key"][5]) >= 4  # cambered: the high-lift end of the NACA set
    assert out["seconds"] < 30
    # Each element gets a shortlist of sections to choose between, its own first.
    assert [len(s) for s in out["shortlists"]] == [6, 6]
    assert all(s[0]["key"] == out["section"]["key"] for s in out["shortlists"])
    kinds = [v["kind"] for v in out["variables"]]
    assert kinds.count("chord") == 2 and kinds.count("airfoil") == 2
    pick = next(v for v in out["variables"] if v["kind"] == "airfoil" and v["element"] == 1)
    assert pick["choices"] == [s["key"] for s in out["shortlists"][1]]


def test_shortlists_rank_each_element_at_its_own_reynolds_number(engine, tmp_path: Path):
    from aeroengine.wing.design import shortlist

    build_index(tmp_path)  # the NACA set
    lists = shortlist(tmp_path / "airfoils", [0.30, 0.14], ["naca/0012", None], min_thickness=0.10, size=4)
    assert [len(x) for x in lists] == [4, 4]
    assert lists[0][0]["key"] == "naca/0012"  # the element's own section first, whatever its rank
    assert lists[1][0]["key"] != "naca/0012" and all(int(x["key"][-2:]) >= 10 for x in lists[1])
    assert len({x["key"] for x in lists[0]}) == 4  # no repeats


def test_a_filled_layout_uses_the_box():
    import numpy as np
    import pytest

    box = (0.0, 0.03, 0.70, 0.35)  # the front wing's box in the design frame: 700 mm long, 30 to 350 mm up
    for n in (2, 3, 5):
        w = layout([naca4("6412")] * n, 0.44, True, box, fill=True)
        pts = np.vstack([e.placed() for e in w.elements])
        assert not w.issues()
        width, height = np.ptp(pts[:, 0]), np.ptp(pts[:, 1])
        assert width >= 0.95 * 0.70 or height >= 0.95 * 0.32  # grown until one side of the box stops it
        assert pts[:, 0].min() == pytest.approx(0.0, abs=0.002) and pts[:, 1].min() == pytest.approx(0.03, abs=0.002)


def test_the_wing_moves_in_the_design_frame():
    import numpy as np
    import pytest

    from aeroengine.wing.geometry import apply

    w = layout([naca4("6412")] * 2, 0.44, True, (0.0, 0.03, 0.70, 0.35), fill=True)
    w.ground_frame = True
    moved = apply(w, {"height_0": 0.08, "x_0": 0.10})
    pts = np.vstack([e.placed() for e in moved.elements])
    assert pts[:, 1].min() == pytest.approx(0.08, abs=1e-9) and moved.ride_height == pytest.approx(0.08, abs=1e-9)
    assert pts[:, 0].min() == pytest.approx(0.10, abs=1e-9)


def test_chords_may_grow_to_the_box():
    import pytest

    w = layout([naca4("6412")] * 2, 0.30, True)
    vs = {v.name: v for v in variables(w, box=(0.0, 0.03, 0.70, 0.35))}
    assert vs["chord_0"].high == pytest.approx(0.70) and vs["chord_1"].high == pytest.approx(0.70)
    assert vs["height_0"].low == pytest.approx(0.03) and vs["x_0"].high == pytest.approx(0.70)
