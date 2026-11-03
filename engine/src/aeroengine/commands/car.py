"""car-*: the car builder's base car, sections and 2D car runs."""

from __future__ import annotations

from pathlib import Path

from ..job import EngineError, JobContext
from . import command


def _step(ctx: JobContext) -> Path:
    path = Path(ctx.params.get("path") or "").expanduser()
    if not path.is_file():
        raise EngineError(f"file not found: {path}")
    return path


@command("car-setup")
def car_setup(ctx: JobContext) -> dict:
    from ..car.setup import setup

    ctx.emit.progress(10, "reading the car")
    return setup(_step(ctx), ctx.params.get("forward", "+x"), ctx.params.get("up", "+z"))
