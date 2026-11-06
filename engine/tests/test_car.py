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


# Strips and the car result ---------------------------------------------------------

from aeroengine.car import strips  # noqa: E402

AXLES = {"ground_z": 0.0, "wheels": [{"name": n, "centre": [x, y, 230], "radius": 230, "width": 200}
                                       for n, x, y in (("FL", -400, 400), ("FR", -400, -400), ("RL", -1950, 400), ("RR", -1950, -400))]}
Q = 0.5 * 1.225 * 15 ** 2


def strip(y, w, lift, x_cp, drag=10.0, converged=True, wing=None):
    return {"y": y, "width": w, "lift": lift, "drag": drag, "x_cp": x_cp, "converged": converged,
            "wing_lift": wing or {}, "wing_drag": {k: 1.0 for k in (wing or {})}}


def test_strips_cover_half_the_car_finer_outside():
    p = strips.plan(700, 7)
    assert sum(w for _, w in p) == pytest.approx(700)
    ys = [y for y, _ in p]
    assert ys == sorted(ys) and ys[-1] >= 600 and p[-1][1] < p[0][1]


def test_combine_sums_both_halves():
    r = strips.combine([strip(100, 400, -100, -1175), strip(500, 300, -50, -1175)], AXLES, 15, 1.225, [], "coarse")
    assert r["cla"] == pytest.approx(2 * 55 / Q, rel=1e-6) and r["cla"] == pytest.approx(0.79819, rel=1e-4)
    assert r["cda"] == pytest.approx(2 * (10 * 0.4 + 10 * 0.3) / Q, rel=1e-6)
    assert r["converged"] and r["mesh"] == "coarse"


def test_rear_share_follows_where_the_downforce_acts():
    at = lambda x: strips.combine([strip(100, 400, -100, x)], AXLES, 15, 1.225, [], "coarse")["rear_share"]  # noqa: E731
    assert at(-400) == pytest.approx(0) and at(-1950) == pytest.approx(1) and at(-1175) == pytest.approx(0.5)


def test_one_strip_not_converged_marks_the_car():
    r = strips.combine([strip(100, 400, -100, -1175), strip(500, 300, -50, -1175, converged=False)], AXLES, 15, 1.225, [], "coarse")
    assert r["converged"] is False


def test_wing_shares_are_corrected_to_3d():
    wing = {"position": "front", "elements": [[[150, 95], [-150, 95], [0, 110]]], "span": 1.0, "factor3d": 0.8, "endplate": None}
    s = [strip(100, 400, -150, -300, wing={"front": -60}), strip(600, 300, -50, -1175)]  # the wing reaches y 500: one strip
    r = strips.combine(s, AXLES, 15, 1.225, [wing], "coarse")
    two_d = 2 * 60 * 0.4 / Q
    assert r["cla_2d_wings"] == pytest.approx(2 * (150 * 0.4 + 50 * 0.3) / Q, rel=1e-6)
    cl = -60 * 0.4 / (Q * 0.3 * 0.4)  # the wing's 2D coefficient over the strips it covers, on its 300 mm chord
    assert r["wings"][0]["cla"] == pytest.approx(-cl * 1.0 * 0.3 * 0.8, rel=1e-6)  # over its whole 1 m span, factor 0.8
    front = r["wings"][0]
    assert front["position"] == "front" and front["cla_2d"] == pytest.approx(two_d, rel=1e-6)
    assert r["cla"] == pytest.approx(r["cla_2d_wings"] - two_d + front["cla"], rel=1e-6)


@pytest.mark.skipif(_su2() is None, reason="SU2 is not installed")
def test_car_strips_through_the_engine(engine, car_step, tmp_path):
    import json
    s = car_setup.setup(car_step)
    job = {"params": {"setup": s, "preset": "coarse", "planes": [[0, 300], [400, 200]], "iterations": 300,
                      "flow": flow()}, "options": {"cores": 2}}
    code, events, err = engine.run("car-strips", job, tmp_path / "w", timeout=300)
    assert code == 0, (events[-3:], err[-2000:])
    r = json.loads((tmp_path / "w" / "result.json").read_text())["data"]
    assert len(r["strips"]) == 2 and r["strips"][1]["width"] == 200 and np.isfinite(r["cda"])
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
    half = max(abs(w["centre"][1]) + w["width"] / 2 for w in s["wheels"])
    for y in [0.0, 450.0] + [y for y, _ in strips.plan(half, 3)] + [y for y, _ in strips.plan(half, 7)]:
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


def test_rear_share_counts_the_3d_correction_where_the_wing_acts():
    wing = {"position": "front", "elements": [[[150, 95], [-150, 95], [0, 110]]], "span": 1.0, "factor3d": 0.5, "endplate": None}
    # Strip total (body and wing) -100 N/m acting midway between the axles; the wing's own -50 N/m at the front axle.
    s = [{**strip(100, 400, -100, -1175, wing={"front": -50}), "wing_x_cp": {"front": -400.0}}]
    r = strips.combine(s, AXLES, 15, 1.225, [wing], "coarse")
    # Half car: total -40 N, rear -20 N. The wing's 2D -20 N becomes -12.5 N in 3D (factor 0.5 over its whole
    # 1 m span from 0.4 m of strips): +7.5 N at the front axle, so the rear keeps -20 N of -32.5 N.
    assert r["rear_share"] == pytest.approx(20 / 32.5, rel=1e-6)


def test_no_lift_gives_no_centre_of_pressure_not_nan():
    r = strips.combine([strip(100, 400, 0.0, None)], AXLES, 15, 1.225, [], "coarse")
    assert r["rear_share"] is None
    import json
    json.loads(json.dumps(r, allow_nan=False))


def test_the_result_says_how_it_was_run():
    r = strips.combine([strip(100, 400, -100, -1175)], AXLES, 15, 1.225, [], "coarse",
                       flow={"speed": 15, "ground": {"moving": False}}, n=7)
    assert r["flow"]["ground"]["moving"] is False and r["n"] == 7


# Deferred minors -----------------------------------------------------------------


def test_a_failed_strip_does_not_lose_the_others(car_step, tmp_path, monkeypatch):
    from aeroengine.job import EngineError
    s = car_setup.setup(car_step)
    calls = []

    def fake(section_, wings, setup, flow_, preset, workdir, su2_hint, cores, progress, iterations=6000):
        calls.append(section_["y"])
        if len(calls) == 2:
            raise EngineError("SU2 diverged at every CFL tried")
        return {"y": section_["y"], "lift": -10.0, "drag": 5.0, "x_cp": -1175.0, "converged": True, "wing_lift": {}, "wing_drag": {}}

    monkeypatch.setattr("aeroengine.car.case.solve_section", fake)
    r = strips.run(s, [], {"speed": 15}, "coarse", tmp_path, None, 1, lambda p, m: None, planes=[[0, 300], [200, 200], [400, 200]])
    assert len(calls) == 3 and r["converged"] is False
    assert [f["y"] for f in r["failed"]] == [200.0] and "diverged" in r["failed"][0]["reason"]
    assert len(r["strips"]) == 2


def test_gaps_in_the_cad_are_counted_in_the_result(car_step, tmp_path, monkeypatch):
    s = car_setup.setup(car_step)
    monkeypatch.setattr("aeroengine.car.case.solve_section", lambda sec, *a, **k: {
        "y": sec["y"], "lift": -1.0, "drag": 1.0, "x_cp": -1175.0, "converged": True, "wing_lift": {}, "wing_drag": {}})
    monkeypatch.setattr("aeroengine.car.section.cut", lambda shape, y, setup: {"y": y, "loops": [], "open": [[0, 0], [1, 1]] * (2 if y else 0)})
    r = strips.run(s, [], {"speed": 15}, "coarse", tmp_path, None, 1, lambda p, m: None, planes=[[0, 300], [200, 200]])
    assert [st["open_gaps"] for st in r["strips"]] == [0, 2] and r["open_gaps"] == 2


def test_a_wing_s_own_chord_is_used_when_given():
    # Only the endplate estimate depends on the chord (its aspect ratio); a plain factor cancels it.
    from aeroengine.wing.finite import car_contribution
    wing = {"position": "front", "elements": [[[150, 95], [-150, 95], [0, 110]]], "span": 1.0, "factor3d": 1.0,
            "endplate": 0.2, "chord": 0.25}
    s = [strip(100, 400, -150, -300, wing={"front": -60})]
    r = strips.combine(s, AXLES, 15, 1.225, [wing], "coarse")
    cl, cd = -60 * 0.4 / (Q * 0.25 * 0.4), 1.0 * 0.4 / (Q * 0.25 * 0.4)
    assert r["wings"][0]["cla"] == pytest.approx(car_contribution(cl, cd, 1.0, 0.25, 0.2)[0], rel=1e-6)



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
