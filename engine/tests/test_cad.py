"""CAD import: STEP/IGES through OCP to .glb. Uses the synthetic sample car,
whose dimensions are known exactly (see engine/scripts/make_sample_cad.py)."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("OCP")

from aeroengine.cad import sample  # noqa: E402
from aeroengine.cad.meshio import read_glb, write_glb  # noqa: E402
from aeroengine.cad.tessellate import tessellate_file  # noqa: E402
from aeroengine.job import EngineError  # noqa: E402


@pytest.fixture(scope="module")
def car_files(tmp_path_factory) -> tuple[Path, Path]:
    d = tmp_path_factory.mktemp("cad")
    sample.build_sample_car(d / "car.step", d / "car.igs")
    return d / "car.step", d / "car.igs"


@pytest.fixture(scope="module")
def car(car_files):
    return tessellate_file(car_files[0], "medium")


def _instance(model, name):
    hits = [(w, m) for p, w, m in model.instances() if p[-1] == name]
    assert len(hits) == 1, [p for p, _, _ in model.instances()]
    return hits[0]


def _world(world, mesh) -> np.ndarray:
    return mesh.positions.astype(np.float64) @ world[:3, :3].T + world[:3, 3]


def test_step_keeps_assembly_tree_and_names(car):
    (root,) = car.roots
    assert root.name == "Sample Car"
    assert [c.name for c in root.children] == [
        "Chassis", "Wheel FL", "Wheel FR", "Wheel RL", "Wheel RR", "Front Wing", "Rear Wing"]
    wings = {c.name: [g.name for g in c.children] for c in root.children if "Wing" in c.name}
    assert wings == {"Front Wing": ["Main Plane", "Flap 1"], "Rear Wing": ["Main Plane", "Flap 1"]}


def test_repeated_parts_share_one_mesh(car):
    # Chassis, Wheel, Main Plane, Flap 1: four parts, eleven instances.
    assert len(car.meshes) == 4
    assert len(car.instances()) == 9
    wheel_meshes = {id(m) for p, _, m in car.instances() if p[-1].startswith("Wheel")}
    assert len(wheel_meshes) == 1


def test_known_dimensions_survive_to_within_a_micron(car):
    # Acceptance check for measuring: box corners are mesh vertices, so the
    # chassis must come out at exactly 1500 x 600 x 300 mm.
    w, m = _instance(car, "Chassis")
    pts = _world(w, m)
    size_mm = (pts.max(0) - pts.min(0)) * 1000
    assert size_mm == pytest.approx(sample.CHASSIS, abs=1e-3)


def test_instance_placement_gives_the_wheelbase(car):
    fl = _world(*_instance(car, "Wheel FL"))
    rl = _world(*_instance(car, "Wheel RL"))
    # Same mesh, so any tessellation offset cancels between the two.
    assert (rl.mean(0)[0] - fl.mean(0)[0]) * 1000 == pytest.approx(sample.WHEELBASE, abs=1e-3)


def test_presets_refine(car_files):
    counts = [tessellate_file(car_files[0], p).triangle_count for p in ("coarse", "medium", "fine")]
    assert counts[0] < counts[1] < counts[2]


def test_normals_are_unit_length(car):
    for m in car.meshes:
        assert np.allclose(np.linalg.norm(m.normals, axis=1), 1, atol=1e-4)


def test_iges_without_assembly_is_split_into_bodies(car_files):
    model = tessellate_file(car_files[1], "medium")
    (root,) = model.roots
    assert len(root.children) == 9  # chassis, 4 wheels, 4 wing elements
    sizes = sorted(tuple(np.round((m.positions.max(0) - m.positions.min(0)) * 1000, 1)) for m in model.meshes)
    assert (1500.0, 600.0, 300.0) in sizes


def test_glb_round_trip(car, tmp_path: Path):
    path = tmp_path / "car.glb"
    write_glb(car, path)
    back = read_glb(path)
    assert [p for p, _, _ in back.instances()] == [p for p, _, _ in car.instances()]
    for (_, w1, m1), (_, w2, m2) in zip(car.instances(), back.instances()):
        assert np.allclose(w1, w2)
        assert np.array_equal(m1.indices, m2.indices)
        assert np.array_equal(m1.positions, m2.positions)


def test_glb_is_valid_gltf(car, tmp_path: Path):
    path = tmp_path / "car.glb"
    write_glb(car, path)
    data = path.read_bytes()
    assert data[:4] == b"glTF"
    assert int.from_bytes(data[8:12], "little") == len(data)
    js = json.loads(data[20 : 20 + int.from_bytes(data[12:16], "little")])
    assert js["asset"]["version"] == "2.0"
    for acc in js["accessors"]:
        if acc["type"] == "VEC3" and "min" in acc:
            assert len(acc["min"]) == 3


def test_unreadable_files_are_engine_errors(tmp_path: Path):
    bad = tmp_path / "junk.step"
    bad.write_text("not a step file")
    with pytest.raises(EngineError):
        tessellate_file(bad)
    with pytest.raises(EngineError):
        tessellate_file(tmp_path / "model.stl")


def test_tessellate_command(engine, car_files, tmp_path: Path):
    workdir = tmp_path / "job"
    job = {"params": {"path": str(car_files[0]), "preset": "coarse"}, "options": {"cores": 2}}
    code, events, stderr = engine.run("tessellate", job, workdir, timeout=120)
    assert code == 0, (events, stderr)
    # OpenCascade's own console output must not reach the event stream.
    assert all(isinstance(e, dict) and "type" in e for e in events)
    data = json.loads((workdir / "result.json").read_text())["data"]
    assert data["glb"] == "model.glb" and (workdir / "model.glb").is_file()
    assert data["instances"] == 9 and data["meshes"] == 4
    assert data["tree"][0]["name"] == "Sample Car"
    assert sorted(p.name for p in workdir.iterdir()) == ["model.glb", "result.json"]


def test_tessellate_command_missing_file(engine, tmp_path: Path):
    code, events, _ = engine.run("tessellate", {"params": {"path": str(tmp_path / "nope.step")}}, tmp_path / "job")
    assert code == 1 and "not found" in events[-1]["msg"]


def test_dense_stl_has_about_a_million_triangles(tmp_path: Path):
    n = sample.write_dense_stl(tmp_path / "dense.stl", 1_000_000)
    assert 950_000 <= n <= 1_050_000
    assert (tmp_path / "dense.stl").stat().st_size == 84 + 50 * n
