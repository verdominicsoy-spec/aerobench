"""validate: the quick methods against published wind-tunnel data."""

from __future__ import annotations

from ..job import JobContext
from . import command


@command("validate")
def validate(ctx: JobContext) -> dict:
    """Runs the validation cases (all, or params.cases by key) and returns
    each one's errors against the measurements; see aeroengine/validation.py."""
    from .. import validation

    keys = ctx.params.get("cases")
    return validation.run([str(k) for k in keys] if keys else None, progress=lambda pct, msg: ctx.emit.progress(pct, msg))


@command("validate-uiuc")
def validate_uiuc(ctx: JobContext) -> dict:
    """The ten-section UIUC benchmark: the estimate and RANS on each, appended
    to data/validation/uiuc_results.json; see validation.run_benchmark."""
    from .. import validation

    return validation.run_benchmark(ctx.workdir, ctx.options.cores, ctx.params.get("su2") or ctx.options.su2_path,
                                    progress=lambda pct, msg: ctx.emit.progress(pct, msg))
