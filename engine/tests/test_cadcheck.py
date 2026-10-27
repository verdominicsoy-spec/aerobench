"""Geometry checks and repairs, on meshes with known, planted defects."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from aeroengine.cad.meshcheck import Soup, check, repair

CUBE_V = np.array([[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0], [0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1]], float)
CUBE_F = np.array([[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7], [0, 1, 5], [0, 5, 4],
                   [1, 2, 6], [1, 6, 5], [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7]])


def soup(v=CUBE_V, f=CUBE_F, body=None):
    f = np.asarray(f)
    return Soup(np.asarray(v, float), f, np.zeros(len(f), int) if body is None else np.asarray(body))


def counts(report):
    return {i["kind"]: i["count"] for i in report["issues"]}


def signed_volume(s: Soup) -> float:
    t = s.vertices[s.faces]
    return float(np.einsum("ij,ij->i", t[:, 0], np.cross(t[:, 1], t[:, 2])).sum() / 6)


def test_clean_cube_has_no_problems():
    r = check(soup())
    assert r["problems"] == 0 and r["closed"] and r["bodies"] == 1
    assert signed_volume(soup()) == pytest.approx(1.0)


def test_each_planted_defect_is_found():
    f = CUBE_F.copy()
    f[3] = f[3][::-1]  # flipped face
    f = np.vstack([f, CUBE_F[0]])  # duplicate face
    f = np.vstack([f, [0, 1, 1]])  # degenerate
    c = counts(check(soup(f=f)))
    assert c["duplicate_faces"] == 1
    assert c["degenerate"] == 1
    assert c["flipped"] > 0

    holed = check(soup(f=CUBE_F[1:]))
    assert counts(holed)["open_edges"] == 3 and not holed["closed"]

    v = np.vstack([CUBE_V, [0.5, -1, 0.5]])
    fin = np.vstack([CUBE_F, [0, 1, 8]])  # a third face on edge 0-1
    assert counts(check(soup(v=v, f=fin)))["non_manifold_edges"] == 1


def test_split_vertices_are_welded_before_checking():
    # An STL-style soup: every triangle has its own three vertices.
    v = CUBE_V[CUBE_F].reshape(-1, 3)
    f = np.arange(len(v)).reshape(-1, 3)
    r = check(soup(v=v, f=f))
    assert r["problems"] == 0 and r["closed"]
    assert counts(r)["duplicate_vertices"] == len(v) - 8


@pytest.mark.parametrize("offset", [[0.5, 0.5, 0.5], [0.37, 0.21, 0.63]])
def test_pierced_faces_within_and_between_bodies(offset):
    other = CUBE_V + offset
    v = np.vstack([CUBE_V, other])
    f = np.vstack([CUBE_F, CUBE_F + 8])
    between = counts(check(soup(v=v, f=f, body=[0] * 12 + [1] * 12)))
    assert between["interference"] > 0 and between["self_intersections"] == 0
    within = counts(check(soup(v=v, f=f)))
    assert within["self_intersections"] > 0 and within["interference"] == 0


def test_touching_is_not_piercing():
    other = CUBE_V + [1, 0, 0]  # shares the x = 1 face plane, no overlap
    v = np.vstack([CUBE_V, other])
    f = np.vstack([CUBE_F, CUBE_F + 8])
    c = counts(check(soup(v=v, f=f, body=[0] * 12 + [1] * 12)))
    assert c["interference"] == 0 and c["self_intersections"] == 0


def test_repair_fixes_what_it_safely_can():
    f = CUBE_F[1:].copy()  # hole
    f[2] = f[2][::-1]  # flipped
    f = np.vstack([f, f[0], [2, 2, 5]])  # duplicate and degenerate
    v = CUBE_V[f].reshape(-1, 3)  # split vertices as well
    broken = soup(v=v, f=np.arange(len(v)).reshape(-1, 3))
    fixed, done = repair(broken)
    assert done["duplicates_removed"] == 1 and done["degenerate_removed"] == 1 and done["holes_closed"] == 1
    r = check(fixed)
    assert r["problems"] == 0 and r["closed"]
    assert signed_volume(fixed) == pytest.approx(1.0)  # closed, normals outward


def test_inside_out_part_is_turned_outward():
    fixed, done = repair(soup(f=CUBE_F[:, ::-1]))
    assert signed_volume(fixed) == pytest.approx(1.0) and done["faces_flipped"] == 12


def test_non_manifold_and_piercing_are_left_alone():
    v = np.vstack([CUBE_V, [0.5, -1, 0.5]])
    fin = np.vstack([CUBE_F, [0, 1, 8]])
    fixed, _ = repair(soup(v=v, f=fin))
    assert counts(check(fixed))["non_manifold_edges"] == 1


# Real files --------------------------------------------------------------

SAMPLES = Path(__file__).resolve().parents[2] / "samples"


@pytest.fixture(scope="module")
def car_files(tmp_path_factory):
    pytest.importorskip("OCP")
    from aeroengine.cad import sample

    d = tmp_path_factory.mktemp("cad")
    sample.build_sample_car(d / "car.step", d / "car.igs")
    return d / "car.step", d / "car.igs"


def test_step_check(engine, car_files, tmp_path):
    code, events, err = engine.run("cad-check", {"params": {"path": str(car_files[0]), "preset": "coarse"}}, tmp_path / "job", timeout=180)
    assert code == 0, (events, err)
    r = json.loads((tmp_path / "job" / "result.json").read_text())["data"]
    brep = {i["kind"]: i["count"] for i in r["brep"]["issues"]}
    assert r["brep"]["invalid_parts"] == [] and brep["brep_invalid_faces"] == 0
    assert brep["brep_free_edges"] == 0  # all solids
    mesh = {i["kind"]: i["count"] for i in r["mesh"]["issues"]}
    assert mesh["non_manifold_edges"] == 0 and mesh["self_intersections"] == 0


def test_iges_surfaces_are_sewn_closed(engine, car_files, tmp_path):
    code, events, _ = engine.run("cad-check", {"params": {"path": str(car_files[1]), "intersections": False}}, tmp_path / "check", timeout=180)
    assert code == 0
    before = json.loads((tmp_path / "check" / "result.json").read_text())["data"]
    assert {i["kind"]: i["count"] for i in before["brep"]["issues"]}["brep_free_edges"] > 0
    code, events, err = engine.run("cad-repair", {"params": {"path": str(car_files[1])}}, tmp_path / "fix", timeout=180)
    assert code == 0, (events, err)
    after = json.loads((tmp_path / "fix" / "result.json").read_text())["data"]
    assert {i["kind"]: i["count"] for i in after["after"]["issues"]}["brep_free_edges"] == 0
    assert (tmp_path / "fix" / after["output"]).exists()


def test_stl_repair_round_trip(engine, tmp_path):
    from aeroengine.cad import meshio

    f = CUBE_F[1:].copy()
    f[2] = f[2][::-1]
    tris = (CUBE_V[f] * 100).astype(np.float32)  # mm
    pos = tris.reshape(-1, 3)
    idx = np.arange(len(pos), dtype=np.uint32).reshape(-1, 3)
    broken = meshio.Model([meshio.Mesh(pos, meshio.vertex_normals(pos, idx), idx)], [meshio.Node("cube", mesh=0)])
    path = tmp_path / "broken.stl"
    meshio.write_stl(broken, path)
    code, events, _ = engine.run("cad-check", {"params": {"path": str(path), "units": "mm"}}, tmp_path / "c")
    report = json.loads((tmp_path / "c" / "result.json").read_text())["data"]
    assert report["problems"] > 0
    code, events, err = engine.run("cad-repair", {"params": {"path": str(path), "units": "mm"}}, tmp_path / "r")
    assert code == 0, (events, err)
    data = json.loads((tmp_path / "r" / "result.json").read_text())["data"]
    assert data["after"]["problems"] == 0
    fixed = meshio.read_stl(tmp_path / "r" / data["output"], 0.001)
    lo, hi = fixed.bounds()
    assert np.allclose(hi - lo, 0.1, atol=1e-6)  # still a 100 mm cube, in the file's own units


def test_sample_stl_is_clean_per_part():
    from aeroengine.cad import meshio
    from aeroengine.commands.cadcheck import _soup

    r = check(_soup(meshio.read_obj(SAMPLES / "sample_car.obj", 0.001)), intersections=False)
    c = counts(r)
    assert c["non_manifold_edges"] == 0 and c["duplicate_faces"] == 0
