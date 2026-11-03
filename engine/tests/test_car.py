"""The car builder's engine: setup, sections, mesh, SU2 case, strips."""

from __future__ import annotations

from pathlib import Path

import pytest
from OCP.BRep import BRep_Builder
from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox, BRepPrimAPI_MakeCylinder
from OCP.gp import gp_Ax2, gp_Dir, gp_Pnt
from OCP.TopoDS import TopoDS_Compound
from stepfixtures import write_parts

from aeroengine.car import setup as car_setup

BASE = Path.home() / "Downloads" / "basemodel.stp"
needs_base = pytest.mark.skipif(not BASE.exists(), reason="the user's base car is not on this machine")


def compound(shapes):
    c = TopoDS_Compound()
    b = BRep_Builder()
    b.MakeCompound(c)
    for s in shapes:
        b.Add(c, s)
    return c


def synthetic_car():
    """A 2000 x 600 x 400 body on four wheels r 230, w 200, ground at z 0; +x forward, +y left."""
    body = BRepPrimAPI_MakeBox(gp_Pnt(-2100, -300, 30), 2000, 600, 400).Shape()
    wheels = [BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(x, y0, 230), gp_Dir(0, 1, 0)), 230, 200).Shape()
              for x in (-400, -1950) for y0 in (300, -500)]
    return compound([body] + wheels)


@pytest.fixture
def car_step(tmp_path):
    return write_parts(tmp_path / "car.stp", {"Car": synthetic_car()})


def test_wheels_and_ground_of_a_synthetic_car(car_step):
    s = car_setup.setup(car_step)
    names = {w["name"]: w for w in s["wheels"]}
    assert set(names) == {"FL", "FR", "RL", "RR"}
    assert names["FL"]["centre"][0] == pytest.approx(-400, abs=1) and names["FL"]["centre"][1] > 0
    assert names["RR"]["centre"][0] == pytest.approx(-1950, abs=1) and names["RR"]["centre"][1] < 0
    assert names["FL"]["radius"] == pytest.approx(230, abs=1) and names["FL"]["width"] == pytest.approx(200, abs=1)
    assert s["ground_z"] == pytest.approx(0, abs=1) and s["speed"] == 15 and s["head_restraint"] is None


@needs_base
def test_wheels_and_ground_of_the_base_car():
    s = car_setup.setup(BASE)
    names = {w["name"]: w for w in s["wheels"]}
    assert set(names) == {"FL", "FR", "RL", "RR"}
    assert names["FL"]["centre"][0] == pytest.approx(-629, abs=15)
    assert names["RL"]["centre"][0] == pytest.approx(-2179, abs=15)
    assert s["ground_z"] == pytest.approx(-48, abs=5)


# Sections ---------------------------------------------------------------------

from aeroengine.car import section  # noqa: E402


def loop_area(points):
    return abs(sum(x0 * z1 - x1 * z0 for (x0, z0), (x1, z1) in zip(points, points[1:] + points[:1]))) / 2


def test_a_centreline_section_is_the_body(car_step):
    s = car_setup.setup(car_step)
    cut = section.cut(car_setup.load_part(car_step, None)[0], 0.0, s)
    assert [lp["kind"] for lp in cut["loops"]] == ["body"] and cut["open"] == []
    assert loop_area(cut["loops"][0]["points"]) == pytest.approx(2000 * 400, rel=0.01)


def test_a_section_through_the_wheels_tags_them(car_step):
    s = car_setup.setup(car_step)
    cut = section.cut(car_setup.load_part(car_step, None)[0], 400.0, s)
    assert sorted(lp.get("wheel") for lp in cut["loops"]) == ["FL", "RL"]
    assert all(lp["kind"] == "wheel" for lp in cut["loops"])


def test_a_section_beside_the_car_is_empty(car_step):
    s = car_setup.setup(car_step)
    assert section.cut(car_setup.load_part(car_step, None)[0], 1000.0, s) == {"y": 1000.0, "loops": [], "open": []}


def test_open_bits_are_reported_and_closed_loops_kept(car_step):
    from test_bodyrepair import faces_of_box
    s = car_setup.setup(car_step)
    holed = faces_of_box(200, 200, 200, drop="top")
    shape = compound([car_setup.load_part(car_step, None)[0], holed])
    cut = section.cut(shape, 100.0, s)
    assert cut["open"]  # the cut through the open box does not close
    assert any(lp["kind"] == "wheel" for lp in cut["loops"]) is False and cut["loops"]  # the body still closes


@needs_base
def test_the_base_car_centreline():
    s = car_setup.setup(BASE)
    cut = section.cut(car_setup.load_part(BASE, None)[0], 0.0, s)
    xs = [p[0] for lp in cut["loops"] for p in lp["points"]]
    assert cut["loops"] and min(xs) == pytest.approx(-2199, abs=20) and max(xs) == pytest.approx(282, abs=20)
