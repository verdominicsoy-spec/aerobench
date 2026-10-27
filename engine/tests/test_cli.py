from __future__ import annotations

import json
import signal
import time
from pathlib import Path


def test_ping_round_trip(engine, tmp_path: Path):
    workdir = tmp_path / "job"
    code, events, _ = engine.run("ping", {"command": "ping", "params": {"echo": "hello"}}, workdir)
    assert code == 0
    assert events[-1] == {"type": "result", "path": "result.json"}
    result = json.loads((workdir / "result.json").read_text())
    assert result["command"] == "ping"
    assert result["data"]["pong"] is True
    assert result["data"]["echo"] == "hello"


def test_every_line_is_a_typed_event(engine, tmp_path: Path):
    _, events, _ = engine.run("dummy", {"params": {"duration": 0.2, "steps": 5}}, tmp_path / "job")
    assert all(e["type"] in {"progress", "log", "result", "error"} for e in events)


def test_ping_without_job_file(engine, tmp_path: Path):
    code, events, _ = engine.run("ping", None, tmp_path / "job")
    assert code == 0
    assert events[-1]["type"] == "result"


def test_cores_option_reaches_the_job(engine, tmp_path: Path):
    workdir = tmp_path / "job"
    engine.run("ping", {"options": {"cores": 3}}, workdir)
    assert json.loads((workdir / "result.json").read_text())["data"]["cores"] == 3


def test_dummy_reports_monotonic_progress_to_100(engine, tmp_path: Path):
    code, events, _ = engine.run("dummy", {"params": {"duration": 0.5, "steps": 10}}, tmp_path / "job")
    assert code == 0
    pcts = [e["pct"] for e in events if e["type"] == "progress"]
    assert len(pcts) == 10
    assert pcts == sorted(pcts)
    assert pcts[-1] == 100


def test_unknown_command_is_an_error_event(engine, tmp_path: Path):
    code, events, _ = engine.run("nope", None, tmp_path / "job")
    assert code == 2
    assert events == [events[0]] and events[0]["type"] == "error"
    assert "unknown command" in events[0]["msg"]


def test_missing_workdir_is_an_error_event(engine):
    code, events, _ = engine.run("ping", None, None)
    assert code == 2
    assert events[-1]["type"] == "error"


def test_bad_job_json_is_an_error_event(engine, tmp_path: Path):
    bad = tmp_path / "bad.json"
    bad.write_text("{not json")
    import subprocess, sys

    proc = subprocess.run(
        [sys.executable, "-m", "aeroengine", "ping", "--input", str(bad), "--workdir", str(tmp_path / "job")],
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 1
    last = json.loads(proc.stdout.splitlines()[-1])
    assert last["type"] == "error" and "not valid JSON" in last["msg"]


def test_job_file_for_another_command_is_rejected(engine, tmp_path: Path):
    code, events, _ = engine.run("ping", {"command": "dummy"}, tmp_path / "job")
    assert code == 1
    assert events[-1]["type"] == "error"


def test_failure_inside_a_command_is_reported_not_faked(engine, tmp_path: Path):
    workdir = tmp_path / "job"
    code, events, _ = engine.run("dummy", {"params": {"duration": 0.2, "steps": 10, "fail_at_pct": 50}}, workdir)
    assert code == 1
    assert events[-1]["type"] == "error"
    assert not (workdir / "result.json").exists()


def test_sigterm_cancels_cleanly_and_cleans_up(engine, tmp_path: Path, events):
    workdir = tmp_path / "job"
    proc = engine.start("dummy", {"params": {"duration": 10, "steps": 100}}, workdir)
    # Wait for real progress so we know the job is mid-run.
    seen = []
    for line in proc.stdout:
        seen.append(json.loads(line))
        if seen[-1]["type"] == "progress":
            break
    t0 = time.monotonic()
    proc.send_signal(signal.SIGTERM)
    out, _ = proc.communicate(timeout=5)
    assert time.monotonic() - t0 < 2, "cancel should be prompt"
    assert proc.returncode == 143
    seen += events(out)
    assert seen[-1] == {"type": "log", "level": "warning", "msg": "cancelled"}
    assert not any(e["type"] == "result" for e in seen)
    assert not (workdir / "result.json").exists()
    assert not (workdir / "scratch").exists()
    assert not (workdir / "mesh").exists()


def test_sigkill_mid_job_leaves_no_result(engine, tmp_path: Path):
    # The app has to treat this as a failure: the process dies without
    # emitting a result or an error event.
    workdir = tmp_path / "job"
    proc = engine.start("dummy", {"params": {"duration": 10, "steps": 100}}, workdir)
    for line in proc.stdout:
        if json.loads(line)["type"] == "progress":
            break
    proc.kill()
    proc.communicate(timeout=5)
    assert proc.returncode == -signal.SIGKILL
    assert not (workdir / "result.json").exists()
