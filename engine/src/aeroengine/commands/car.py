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


@command("car-strips")
def car_strips(ctx: JobContext) -> dict:
    """The car (and any placed wings) as strips across it, solved in SU2."""
    import json

    from ..car.strips import run

    setup = ctx.params.get("setup")
    if not isinstance(setup, dict) or not setup.get("wheels"):
        raise EngineError("params.setup must be a car setup with its wheels", "run car-setup first")
    flow = ctx.params.get("flow") or {"speed": setup.get("speed", 15.0)}
    result = run(setup, list(ctx.params.get("wings") or []), flow, ctx.params.get("preset", "medium"), ctx.workdir,
                 ctx.params.get("su2") or ctx.options.su2_path, ctx.options.cores, ctx.emit.progress,
                 ctx.params.get("planes"), int(ctx.params.get("iterations", 6000)), int(ctx.params.get("n", 7)))
    (ctx.workdir / "car_result.json").write_text(json.dumps(result, indent=1))
    return result
