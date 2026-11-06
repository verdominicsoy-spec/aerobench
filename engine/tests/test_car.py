"""The car builder's engine: setup, sections, mesh, SU2 case, the car result."""

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


# The car mesh -----------------------------------------------------------------

import numpy as np  # noqa: E402

from aeroengine.car import mesh as car_mesh  # noqa: E402


def front_wing():
    """A 300 mm ellipse-like element whose back 50 mm sit inside the synthetic car's nose."""
    t = np.linspace(0, 2 * np.pi, 81)[:-1]
    xs, zs = 0 + 150 * np.cos(t), 95 + 15 * np.sin(t)
    return {"position": "front", "elements": [np.c_[xs, zs].tolist()], "span": 1.0, "factor3d": 1.0, "endplate": None}


def test_a_centreline_mesh_has_the_markers(car_step, tmp_path):
    s = car_setup.setup(car_step)
    cut = section.cut(car_setup.load_part(car_step, None)[0], 0.0, s)
    st = car_mesh.build(cut, [], s, "coarse", tmp_path / "m.su2")
    assert set(st["markers"]) == {"body", "ground", "road", "inlet", "outlet", "top"} and st["cells"] > 1000


def test_a_wing_through_the_nose_is_fused_but_keeps_its_marker(car_step, tmp_path):
    s = car_setup.setup(car_step)
    cut = section.cut(car_setup.load_part(car_step, None)[0], 0.0, s)
    wing = front_wing()
    wing["elements"][0] = [[x - 100, z] for x, z in wing["elements"][0]]  # 50 mm into the nose at x = -100
    st = car_mesh.build(cut, [wing], s, "coarse", tmp_path / "m.su2")
    assert "wing_front" in st["markers"] and st["obstacles"] == 1 and st["quads"] > 0


def test_a_section_through_a_wheel_has_its_marker(car_step, tmp_path):
    s = car_setup.setup(car_step)
    cut = section.cut(car_setup.load_part(car_step, None)[0], 400.0, s)
    st = car_mesh.build(cut, [], s, "coarse", tmp_path / "m.su2")
    assert {"wheel_FL", "wheel_RL"} <= set(st["markers"])


def test_maxed_is_finer_than_coarse(car_step, tmp_path):
    s = car_setup.setup(car_step)
    cut = section.cut(car_setup.load_part(car_step, None)[0], 0.0, s)
    coarse = car_mesh.build(cut, [], s, "coarse", tmp_path / "c.su2")["cells"]
    maxed = car_mesh.build(cut, [], s, "maxed", tmp_path / "x.su2")["cells"]
    assert maxed > 2 * coarse


# The SU2 car case ---------------------------------------------------------------

from aeroengine.car import case as car_case  # noqa: E402


def flow(ground=True, wheels=True, speed=15.0):
    return {"speed": speed, "ground": {"moving": ground, "speed": speed}, "wheels": {"rotating": wheels, "speed": speed}}


def _su2():
    try:
        return car_case.su2.find_su2()
    except Exception:
        return None


SETUP = {"ground_z": 0.0, "speed": 15.0, "wheels": [{"name": "FL", "centre": [-400, 400, 230], "radius": 230, "width": 200}]}


def test_config_slips_a_ground_at_the_air_speed_and_turns_the_wheels():
    text = car_case.config(["body", "wheel_FL", "road"], SETUP, flow(), "m.su2")
    assert "MARKER_SYM= ( ground, road )" in text and "MARKER_HEATFLUX= ( body, 0.0, wheel_FL, 0.0 )" in text
    assert "MARKER_MOVING= ( wheel_FL )" in text
    assert "SURFACE_TRANSLATION_RATE= ( 0.0, 0.0, 0.0 )" in text
    # rolling: 15 m/s over r 0.23 m, about the wheel's centre (X = 0.4, Y = 0.23 m)
    assert "SURFACE_ROTATION_RATE= ( 0.0, 0.0, 65.2174 )" in text
    assert "SURFACE_MOTION_ORIGIN= ( 0.4, 0.23, 0.0 )" in text
    assert "MARKER_WALL_FUNCTIONS" not in text


def test_config_without_moving_parts():
    text = car_case.config(["body", "wheel_FL", "wing_front", "road"], SETUP, flow(False, False), "m.su2")
    assert "MARKER_MOVING" not in text and "SURFACE_MOVEMENT" not in text
    assert "MARKER_HEATFLUX= ( body, 0.0, wheel_FL, 0.0, wing_front, 0.0, ground, 0.0 )" in text
    assert "MARKER_SYM= ( road )" in text


def test_config_moves_a_ground_slower_than_the_air():
    f = {**flow(True, False), "ground": {"moving": True, "speed": 10.0}}
    text = car_case.config(["body", "wheel_FL"], SETUP, f, "m.su2")
    assert "MARKER_MOVING= ( ground )" in text and "SURFACE_MOVEMENT= ( MOVING_WALL )" in text
    assert "SURFACE_TRANSLATION_RATE= ( 10.0, 0.0, 0.0 )" in text and "ground, 0.0" in text


@pytest.mark.skipif(_su2() is None, reason="SU2 is not installed")
def test_a_section_solves(car_step, tmp_path):
    s = car_setup.setup(car_step)
    cut = section.cut(car_setup.load_part(car_step, None)[0], 0.0, s)
    r = car_case.solve_section(cut, [], s, flow(), "coarse", tmp_path, None, 4, lambda p, m: None, iterations=400)
    assert np.isfinite(r["lift"]) and np.isfinite(r["drag"]) and r["drag"] > 0
    assert isinstance(r["converged"], bool) and np.isfinite(r["x_cp"])


# The car result -----------------------------------------------------------------

from aeroengine.car import totals  # noqa: E402

AXLES = {"ground_z": 0.0, "wheels": [{"name": n, "centre": [x, y, 230], "radius": 230, "width": 200}
                                       for n, x, y in (("FL", -400, 400), ("FR", -400, -400), ("RL", -1950, 400), ("RR", -1950, -400))]}
Q = 0.5 * 1.225 * 15 ** 2


def sec(lift, x_cp, drag=10.0, converged=True, wing=None):
    return {"y": 0.0, "lift": lift, "drag": drag, "x_cp": x_cp, "converged": converged,
            "wing_lift": wing or {}, "wing_drag": {k: 1.0 for k in (wing or {})}}


def test_the_car_s_numbers_are_2d_on_its_length():
    r = totals.combine(sec(-100, -1175), AXLES, 15, 1.225, [], "coarse", 3.0)
    assert r["cl"] == pytest.approx(-100 / (Q * 3.0)) and r["cd"] == pytest.approx(10 / (Q * 3.0))
    assert r["ref_length"] == 3.0 and r["n"] == 1 and r["converged"] and r["mesh"] == "coarse"
    assert "cla" not in r and "cda" not in r


def test_rear_share_follows_where_the_downforce_acts():
    at = lambda x: totals.combine(sec(-100, x), AXLES, 15, 1.225, [], "coarse", 3.0)["rear_share"]  # noqa: E731
    assert at(-400) == pytest.approx(0) and at(-1950) == pytest.approx(1) and at(-1175) == pytest.approx(0.5)


def test_a_section_not_converged_marks_the_car():
    assert totals.combine(sec(-100, -1175, converged=False), AXLES, 15, 1.225, [], "coarse", 3.0)["converged"] is False


def test_a_wing_s_numbers_are_its_2d_ones_on_its_chord():
    wing = {"position": "front", "elements": [[[150, 95], [-150, 95], [0, 110]]], "span": 1.0, "factor3d": 0.8, "endplate": None}
    r = totals.combine(sec(-150, -300, wing={"front": -60}), AXLES, 15, 1.225, [wing], "coarse", 3.0)
    front = r["wings"][0]
    assert front["position"] == "front" and front["chord"] == pytest.approx(0.3)
    assert front["cl"] == pytest.approx(-60 / (Q * 0.3)) and front["cd"] == pytest.approx(1 / (Q * 0.3))
    assert r["cl"] == pytest.approx(-150 / (Q * 3.0))  # the car's own number is the section's, untouched by the wing's span


@pytest.mark.skipif(_su2() is None, reason="SU2 is not installed")
def test_the_car_section_through_the_engine(engine, car_step, tmp_path):
    import json
    s = car_setup.setup(car_step)
    job = {"params": {"setup": s, "preset": "coarse", "iterations": 300,
                      "flow": flow()}, "options": {"cores": 2}}
    code, events, err = engine.run("car-strips", job, tmp_path / "w", timeout=300)
    assert code == 0, (events[-3:], err[-2000:])
    r = json.loads((tmp_path / "w" / "result.json").read_text())["data"]
    assert len(r["strips"]) == 1 and r["strips"][0]["y"] == 0 and np.isfinite(r["cd"]) and r["ref_length"] > 1
    assert (tmp_path / "w" / "car_result.json").exists()


def su2_markers_on_cells(path: Path) -> dict:
    """Per marker: (elements, zero-length, not an edge of any cell)."""
    lines = path.read_text().split("\n")
    i, cells, marks = 0, [], {}
    while i < len(lines):
        line = lines[i]
        if line.startswith("NELEM="):
            n = int(line.split("=")[1])
            cells = [list(map(int, lines[i + 1 + k].split()[1:-1])) for k in range(n)]
            i += n
        elif line.startswith("MARKER_TAG="):
            tag, n = line.split("=")[1].strip(), int(lines[i + 1].split("=")[1])
            marks[tag] = [tuple(map(int, lines[i + 2 + k].split()[1:])) for k in range(n)]
            i += n + 1
        i += 1
    edges = {frozenset((a, b)) for c in cells for a, b in zip(c, c[1:] + c[:1])}
    return {t: (len(es), sum(e[0] == e[1] for e in es), sum(frozenset(e) not in edges for e in es)) for t, es in marks.items()}


@needs_base
def test_the_base_car_mesh_has_clean_markers(tmp_path):
    s = car_setup.setup(BASE)
    shape = car_setup.load_part(BASE, None)[0]
    for y in [0.0, 450.0]:
        car_mesh.build(section.cut(shape, y, s), [], s, "coarse", tmp_path / f"m{y}.su2")
        for tag, (n, zero, loose) in su2_markers_on_cells(tmp_path / f"m{y}.su2").items():
            assert n > 0 and zero == 0 and loose == 0, (y, tag, n, zero, loose)


# Final review fixes ---------------------------------------------------------------


def test_contact_blocks_are_not_rotating_wheel_walls(car_step, tmp_path):
    s = car_setup.setup(car_step)
    cut = section.cut(car_setup.load_part(car_step, None)[0], 400.0, s)
    out = tmp_path / "m.su2"
    car_mesh.build(cut, [], s, "coarse", out)
    lines = out.read_text().split("\n")
    i = lines.index("NPOIN= " + lines[[k for k, l in enumerate(lines) if l.startswith("NPOIN=")][0]].split("=")[1].strip())
    n = int(lines[i].split("=")[1].split()[0])
    pts = [list(map(float, lines[i + 1 + k].split()[:2])) for k in range(n)]
    k = next(j for j, l in enumerate(lines) if l.strip() == "MARKER_TAG= wheel_FL")
    m = int(lines[k + 1].split("=")[1])
    nodes = {int(x) for e in lines[k + 2:k + 2 + m] for x in e.split()[1:]}
    w = next(w for w in s["wheels"] if w["name"] == "FL")
    cx, cy, r = -w["centre"][0] / 1000, (w["centre"][2] - s["ground_z"]) / 1000, w["radius"] / 1000
    off = [abs(np.hypot(pts[j][0] - cx, pts[j][1] - cy) - r) for j in nodes]
    assert max(off) < 0.003  # every rotating-wall node on the tyre, none on the block


def test_the_engine_defaults_to_a_moving_ground():
    text = car_case.config(["body"], SETUP, {"speed": 15.0}, "m.su2")
    assert "MARKER_SYM= ( ground )" in text and "ground, 0.0" not in text



@needs_base
@pytest.mark.skipif(_su2() is None, reason="SU2 is not installed")
def test_the_base_car_centreline_settles_on_a_moving_ground(tmp_path):
    # With wall functions SST ran away at the car's corners: CD 7 to 18 per metre, never converged.
    s = car_setup.setup(BASE)
    cut = section.cut(car_setup.load_part(BASE, None)[0], 0.0, s)
    r = car_case.solve_section(cut, [], s, flow(), "coarse", tmp_path, None, 6, lambda p, m: None)
    assert r["converged"], r["reason"]
    assert 0.3 < r["drag"] / Q < 2.0
    # The ground's no-slip on cells too big for it set the lift by the mesh (CL +0.3 coarse, -0.1 medium);
    # slip: -0.56 coarse, -0.61 medium.
    assert -0.75 < r["lift"] / Q < -0.45


def test_no_lift_gives_no_centre_of_pressure_not_nan():
    r = totals.combine(sec(0.0, None), AXLES, 15, 1.225, [], "coarse", 3.0)
    assert r["rear_share"] is None
    import json
    json.loads(json.dumps(r, allow_nan=False))


def test_the_result_says_how_it_was_run():
    r = totals.combine(sec(-100, -1175), AXLES, 15, 1.225, [], "coarse", 3.0, flow={"speed": 15, "ground": {"moving": False}})
    assert r["flow"]["ground"]["moving"] is False


# Deferred minors -----------------------------------------------------------------


def test_gaps_in_the_cad_are_counted_in_the_result(car_step, tmp_path, monkeypatch):
    s = car_setup.setup(car_step)
    monkeypatch.setattr("aeroengine.car.case.solve_section", lambda sec, *a, **k: {
        "y": sec["y"], "lift": -1.0, "drag": 1.0, "x_cp": -1175.0, "converged": True, "wing_lift": {}, "wing_drag": {}})
    monkeypatch.setattr("aeroengine.car.section.cut", lambda shape, y, setup: {
        "y": y, "loops": [{"kind": "body", "points": [[0, 0], [-2500, 0], [-2500, 500]]}], "open": [[0, 0], [1, 1]] * 2})
    r = totals.run(s, [], {"speed": 15}, "coarse", tmp_path, None, 1, lambda p, m: None)
    assert [st["open_gaps"] for st in r["strips"]] == [2] and r["open_gaps"] == 2 and r["strips"][0]["folder"] == "section"
    assert r["ref_length"] == pytest.approx(2.5)



@pytest.mark.parametrize("dip", [1.0, 2.0, 4.0])
def test_a_flap_just_proud_of_the_nose_meshes(tmp_path, dip):
    """A flap dipping a few mm below the nose's sloping underside it runs through (Car 2's front
    wing at y 82 mm): its wall layers have no room there, and growing them made gmsh fail with
    "Edge not recovered" at 2 mm."""
    body = {"kind": "body", "points": [[80, 67], [0.2, 47.6], [-141.8, 29.3], [-1500, 29.3], [-1500, 400], [80, 400]]}
    ang = np.arctan2(47.6 - 29.3, 0.2 + 141.8)
    t = np.linspace(0, 2 * np.pi, 81)[:-1]
    xs, zs = 63 * np.cos(t), 12 * np.sin(t)
    x = -72 + xs * np.cos(ang) - zs * np.sin(ang)
    z = 47.6 - 72.2 * np.tan(ang) + 12 - dip + xs * np.sin(ang) + zs * np.cos(ang)
    wing = {"position": "front", "elements": [np.c_[x, z].tolist()], "span": 1.0, "factor3d": 1.0, "endplate": None}
    st = car_mesh.build({"y": 0.0, "loops": [body], "open": []}, [wing], {"ground_z": 0.0, "speed": 20.0},
                        "medium", tmp_path / "m.su2")
    assert "wing_front" in st["markers"] and st["cells"] > 1000


def test_config_has_the_limited_fallback():
    text = car_case.config(["body", "road"], SETUP, flow(), "m.su2", scheme="fds_limited")
    assert "MUSCL_FLOW= YES" in text and "SLOPE_LIMITER_FLOW= VENKATAKRISHNAN" in text
    assert "SLOPE_LIMITER_FLOW= NONE" in car_case.config(["body", "road"], SETUP, flow(), "m.su2")
