from __future__ import annotations

import os
import platform
import sys

from .. import __version__
from ..job import JobContext
from . import command


@command("ping")
def ping(ctx: JobContext) -> dict:
    ctx.emit.log("pong")
    return {
        "pong": True,
        "echo": ctx.params.get("echo"),
        "engine_version": __version__,
        "python": platform.python_version(),
        "executable": sys.executable,
        "platform": platform.platform(),
        "machine": platform.machine(),
        "cpu_count": os.cpu_count(),
        "cores": ctx.options.cores,
        "pid": os.getpid(),
    }
