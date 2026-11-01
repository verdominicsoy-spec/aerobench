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
