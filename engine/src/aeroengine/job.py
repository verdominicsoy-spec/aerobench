"""Job context shared by every command: input, work folder, housekeeping."""

from __future__ import annotations

import json
import os
import shutil
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import __version__
from .events import Emitter

RESULT_FILE = "result.json"
SCRATCH_DIR = "scratch"
MESH_DIR = "mesh"


class EngineError(Exception):
    """An expected failure with a message fit to show the user."""

    def __init__(self, msg: str, detail: str | None = None) -> None:
        super().__init__(msg)
        self.msg = msg
        self.detail = detail


class JobCancelled(Exception):
    """Raised inside the job when the app asks it to stop (SIGTERM)."""


@dataclass
class JobOptions:
    keep_mesh: bool = False
    cores: int = 1
    su2_path: str | None = None

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "JobOptions":
        cores = data.get("cores", 1)
        if not isinstance(cores, int) or isinstance(cores, bool) or cores < 1:
            raise EngineError(f"options.cores must be a positive integer, got {cores!r}")
        return cls(
            keep_mesh=bool(data.get("keep_mesh", False)),
            cores=cores,
            su2_path=data.get("su2_path") or None,
        )


@dataclass
class JobContext:
    command: str
    workdir: Path
    params: dict[str, Any]
    options: JobOptions
    emit: Emitter
    _made: set[str] = field(default_factory=set)

    @classmethod
    def load(cls, command: str, input_path: Path | None, workdir: Path, emit: Emitter) -> "JobContext":
        job: dict[str, Any] = {}
        if input_path is not None:
            try:
                job = json.loads(input_path.read_text())
            except FileNotFoundError:
                raise EngineError(f"Job file not found: {input_path}") from None
            except json.JSONDecodeError as exc:
                raise EngineError(f"Job file is not valid JSON: {input_path}", str(exc)) from None
            if not isinstance(job, dict):
                raise EngineError("Job file must contain a JSON object")
        job_command = job.get("command")
        if job_command is not None and job_command != command:
            raise EngineError(f"Job file is for '{job_command}' but the command was '{command}'")
        params = job.get("params", {})
        if not isinstance(params, dict):
            raise EngineError("params must be a JSON object")
        options = job.get("options", {})
        if not isinstance(options, dict):
            raise EngineError("options must be a JSON object")
        workdir.mkdir(parents=True, exist_ok=True)
        return cls(command, workdir, params, JobOptions.from_dict(options), emit)

    # Intermediates. Commands put throwaway files in scratch/ and meshes in
    # mesh/. Both are removed when the job ends; mesh/ survives only when the
    # user ticked keep mesh.

    @property
    def scratch_dir(self) -> Path:
        return self._subdir(SCRATCH_DIR)

    @property
    def mesh_dir(self) -> Path:
        return self._subdir(MESH_DIR)

    def _subdir(self, name: str) -> Path:
        path = self.workdir / name
        path.mkdir(exist_ok=True)
        self._made.add(name)
        return path

    def cleanup(self) -> None:
        doomed = [SCRATCH_DIR]
        if not self.options.keep_mesh:
            doomed.append(MESH_DIR)
        for name in doomed:
            if name in self._made:
                shutil.rmtree(self.workdir / name, ignore_errors=True)

    def thread_env(self) -> dict[str, str]:
        """Environment for child solvers so they respect the per-job core limit."""
        env = dict(os.environ)
        n = str(self.options.cores)
        env.update(OMP_NUM_THREADS=n, OPENBLAS_NUM_THREADS=n, MKL_NUM_THREADS=n, VECLIB_MAXIMUM_THREADS=n)
        return env

    def write_result(self, data: dict[str, Any]) -> Path:
        payload = {
            "command": self.command,
            "engine_version": __version__,
            "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "data": data,
        }
        path = self.workdir / RESULT_FILE
        tmp = path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload, indent=2, default=str) + "\n")
        tmp.replace(path)
        self.emit.result(RESULT_FILE)
        return path
