"""A fake long job used to exercise progress, cancel and housekeeping."""

from __future__ import annotations

import time

from ..job import EngineError, JobContext
from . import command


@command("dummy")
def dummy(ctx: JobContext) -> dict:
    duration = float(ctx.params.get("duration", 10.0))
    steps = int(ctx.params.get("steps", 100))
    fail_at = ctx.params.get("fail_at_pct")
    if duration < 0 or steps < 1:
        raise EngineError("duration must be >= 0 and steps >= 1")

    # Stand-ins for real intermediates so housekeeping has something to do.
    (ctx.scratch_dir / "partial.dat").write_text("throwaway\n")
    (ctx.mesh_dir / "dummy.su2").write_text("% fake mesh\nNDIME= 2\n")

    started = time.monotonic()
    ctx.emit.log(f"dummy job: {duration:g} s in {steps} steps")
    for i in range(1, steps + 1):
        time.sleep(duration / steps)
        pct = 100.0 * i / steps
        if fail_at is not None and pct >= float(fail_at):
            raise EngineError(f"dummy job failed on purpose at {pct:.0f}%", "fail_at_pct was set in params")
        ctx.emit.progress(pct, f"step {i}/{steps}")
    return {"duration": duration, "steps": steps, "elapsed": round(time.monotonic() - started, 3)}
