from __future__ import annotations

from pathlib import Path


def test_intermediates_removed_by_default(engine, tmp_path: Path):
    workdir = tmp_path / "job"
    code, _, _ = engine.run("dummy", {"params": {"duration": 0.1, "steps": 2}}, workdir)
    assert code == 0
    assert sorted(p.name for p in workdir.iterdir()) == ["result.json"]


def test_keep_mesh_keeps_only_the_mesh(engine, tmp_path: Path):
    workdir = tmp_path / "job"
    job = {"params": {"duration": 0.1, "steps": 2}, "options": {"keep_mesh": True}}
    code, _, _ = engine.run("dummy", job, workdir)
    assert code == 0
    assert sorted(p.name for p in workdir.iterdir()) == ["mesh", "result.json"]
    assert (workdir / "mesh" / "dummy.su2").exists()


def test_failed_job_still_cleans_up(engine, tmp_path: Path):
    workdir = tmp_path / "job"
    job = {"params": {"duration": 0.1, "steps": 4, "fail_at_pct": 50}}
    code, _, _ = engine.run("dummy", job, workdir)
    assert code == 1
    assert list(workdir.iterdir()) == []


def test_nothing_written_outside_workdir(engine, tmp_path: Path):
    workdir = tmp_path / "job"
    job_file = tmp_path / "dummy-job.json"  # written by the test fixture, not the engine
    outside = lambda: {p for p in tmp_path.rglob("*") if not p.is_relative_to(workdir) and p != job_file}
    before = outside()
    engine.run("dummy", {"params": {"duration": 0.1, "steps": 2}, "options": {"keep_mesh": True}}, workdir)
    assert outside() == before
