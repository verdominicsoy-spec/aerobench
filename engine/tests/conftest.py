from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest


def _events(stdout: str) -> list[dict]:
    return [json.loads(line) for line in stdout.splitlines() if line.strip()]


class Engine:
    """Runs the engine as a child process, the way the app does."""

    def __init__(self, tmp_path: Path) -> None:
        self.tmp_path = tmp_path

    def args(self, command: str, job: dict | None, workdir: Path | None) -> list[str]:
        argv = [sys.executable, "-m", "aeroengine", command]
        if job is not None:
            job_file = self.tmp_path / f"{command}-job.json"
            job_file.write_text(json.dumps(job))
            argv += ["--input", str(job_file)]
        if workdir is not None:
            argv += ["--workdir", str(workdir)]
        return argv

    def run(self, command: str, job: dict | None = None, workdir: Path | None = None, timeout: float = 30):
        proc = subprocess.run(self.args(command, job, workdir), capture_output=True, text=True, timeout=timeout)
        return proc.returncode, _events(proc.stdout), proc.stderr

    def start(self, command: str, job: dict | None = None, workdir: Path | None = None) -> subprocess.Popen:
        return subprocess.Popen(
            self.args(command, job, workdir),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env={**os.environ, "PYTHONUNBUFFERED": "1"},
        )


@pytest.fixture
def engine(tmp_path: Path) -> Engine:
    return Engine(tmp_path)


@pytest.fixture
def events():
    return _events
