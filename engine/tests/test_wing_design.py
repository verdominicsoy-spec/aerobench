"""The starting wing for a design from scratch."""

from __future__ import annotations

from pathlib import Path

import pytest

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
    main, flap = w.elements[0].chord, w.elements[1].chord
    assert vs["chord_0"].high == pytest.approx(min(1.6 * main, 0.70), abs=1e-4)
    assert vs["chord_1"].high == pytest.approx(min(1.6 * flap, 0.70), abs=1e-4)
    assert (vs["xfrac_0"].low, vs["xfrac_0"].high, vs["yfrac_0"].low, vs["yfrac_0"].high) == (0, 1, 0, 1)


def test_a_place_in_the_room_never_leaves_the_box():
    import numpy as np

    from aeroengine.wing.geometry import apply

    box = (0.0, 0.03, 0.70, 0.35)
    w = layout([naca4("6412")] * 2, 0.30, True, box)
    w.ground_frame = True
    for fx, fy in ((0, 0), (1, 1), (0.5, 0.2)):
        moved = apply(w, {"xfrac_0": fx, "yfrac_0": fy})
        pts = np.vstack([e.placed() for e in moved.elements])
        assert not moved.issues()
        if (fx, fy) == (0, 0):
            assert pts[:, 1].min() == pytest.approx(0.03, abs=1e-6) and moved.ride_height == pytest.approx(0.03, abs=1e-6)
        if (fx, fy) == (1, 1):
            assert pts[:, 0].max() == pytest.approx(0.70, abs=1e-6) and pts[:, 1].max() == pytest.approx(0.35, abs=1e-6)


def _design(engine, tmp_path, name, timeout=300, **params):
    import json

    job = {"command": "wing-design", "params": {"box": [0.0, 0.03, 0.70, 0.35], "elements": 2, "inverted": True,
                                                "goal": "max_cla", "span": 1.2, "endplate": 0.25, "speed": 15.0,
                                                "trials": 12, "checks": 0, "storage": str(tmp_path / f"{name}.db"),
                                                "name": name, **params}}
    code, events, stderr = engine.run("wing-design", job, tmp_path / f"job-{name}", timeout=timeout)
    result = tmp_path / f"job-{name}" / "result.json"
    return code, events, (json.loads(result.read_text())["data"] if code == 0 else stderr + str(events[-3:]))


def test_design_without_rans_returns_ranked_finalists(engine, tmp_path):
    import numpy as np

    code, _, out = _design(engine, tmp_path, "d", trials=30)
    assert code == 0, out
    f = out["finalists"]
    assert f and all(x["rans"] is None for x in f)
    values = [x["estimate_value"] for x in f]
    assert values == sorted(values, reverse=True)
    assert all(x["cla"] > 0 and x["cda"] > 0 and x["cla_cda"] == pytest.approx(x["cla"] / x["cda"]) for x in f)
    pts = np.vstack([np.asarray(e["coords"]) for e in out["base"]["elements"]])
    assert np.ptp(pts[:, 0]) >= 0.6 or np.ptp(pts[:, 1]) >= 0.3  # the starting wing fills the box


def test_design_refuses_a_box_too_small(engine, tmp_path):
    code, _, out = _design(engine, tmp_path, "small", box=[0.0, 0.03, 0.15, 0.08], elements=5, trials=5)
    assert code != 0 and "box" in out


def test_a_start_wing_outside_the_box_is_moved_inside(engine, tmp_path):
    import numpy as np

    w = layout([naca4("6412")] * 2, 0.40, True)
    start = [{"unit": e.unit.tolist(), "chord": e.chord, "angle": e.angle, "inverted": True,
              "leading_edge": (e.leading_edge + np.array([0.9, 0.5])).tolist()} for e in w.elements]
    code, _, out = _design(engine, tmp_path, "s", start=start, trials=5)
    assert code == 0, out
    pts = np.vstack([np.asarray(e["coords"]) for e in out["base"]["elements"]])
    assert pts[:, 0].max() <= 0.70 + 1e-9 and pts[:, 1].max() <= 0.35 + 1e-9 and pts[:, 1].min() >= 0.03 - 1e-9


def test_design_again_resumes_the_same_study(engine, tmp_path):
    code, _, first = _design(engine, tmp_path, "r")
    assert code == 0, first
    code, _, again = _design(engine, tmp_path, "r")
    assert code == 0, again
    assert again["study"]["complete"] == first["study"]["complete"]  # nothing new to run: the same 12 trials
    assert again["base"] == first["base"]


def test_balance_needs_a_base_car(engine, tmp_path):
    code, _, out = _design(engine, tmp_path, "b", goal="balance", rear_target=0.55, trials=5)
    assert code != 0 and "base car" in out


@pytest.mark.skipif(not __import__("os").environ.get("AEROBENCH_SU2") and not __import__("shutil").which("SU2_CFD"),
                    reason="SU2 not found")
def test_design_with_rans_ranks_by_rans(engine, tmp_path):
    code, _, out = _design(engine, tmp_path, "rans", timeout=1500, trials=80, seed=5, checks=2, mesh="quick", model="sa")
    assert code == 0, out
    f = out["finalists"]
    assert 1 <= len(f) <= 2 and all(x["rans"] is not None for x in f)
    held = [x for x in f if x["rans"]["value"] is not None]
    assert [x["rans"]["value"] for x in held] == sorted((x["rans"]["value"] for x in held), reverse=True)
    assert all(x["from"] == "RANS" for x in held) and f[: len(held)] == held  # held ones first


def test_the_study_starts_from_where_the_wing_sits_in_the_box():
    from aeroengine.wing.geometry import apply
    from aeroengine.wing.optimise import _current

    box = (0.0, 0.03, 0.70, 0.35)
    w = layout([naca4("6412")] * 2, 0.30, True, box)
    w.ground_frame = True
    w = apply(w, {"xfrac_0": 0.25, "yfrac_0": 0.5})
    vs = variables(w, box=box)
    now = _current(w, vs)
    assert now["xfrac_0"] == pytest.approx(0.25, abs=1e-6) and now["yfrac_0"] == pytest.approx(0.5, abs=1e-6)
    again = apply(w, now)  # the first trial is the wing as it is
    assert again.ride_height == pytest.approx(w.ride_height, abs=1e-9)


def test_a_design_in_free_air_has_no_ride_height(engine, tmp_path):
    code, _, out = _design(engine, tmp_path, "free", box=[0.0, 0.0, 0.45, 0.30], free_air=True)
    assert code == 0, out
    assert out["base"]["ride_height"] is None and all(f["ride_height"] is None for f in out["finalists"])


def test_finalists_that_held_in_rans_come_first_and_misses_do_not_hold():
    from aeroengine.commands.wing import rank_finalists

    checks = [{"number": 1, "value": 0.9, "feasible": True}, {"number": 2, "value": 1.2, "feasible": False},
              {"number": 3, "value": None, "separated": True}, {"number": 4, "value": 1.0, "feasible": True}]
    ranked = rank_finalists(checks, "maximize")
    assert [c["number"] for c in ranked] == [4, 1, 2, 3]  # held by value, then the drag-limit miss, then the separated one


def test_a_saved_design_with_other_settings_is_refused(engine, tmp_path):
    code, _, first = _design(engine, tmp_path, "same")
    assert code == 0, first
    code, _, out = _design(engine, tmp_path, "same", elements=3)
    assert code != 0 and "different design" in out


def test_a_canvas_wing_still_searches_sections(engine, tmp_path):
    import numpy as np

    w = layout([naca4("6412")] * 2, 0.30, True, (0.0, 0.03, 0.70, 0.35))
    start = [{"unit": e.unit.tolist(), "chord": e.chord, "angle": e.angle, "inverted": True, "key": "naca/6412",
              "leading_edge": (e.leading_edge + np.array([0.0, 0.1])).tolist()} for e in w.elements]
    code, _, out = _design(engine, tmp_path, "canvas", start=start, trials=5)
    assert code == 0, out
    kinds = [v["kind"] for v in out["study"]["spec"]["variables"]]
    assert "airfoil" in kinds
