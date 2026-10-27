"""tessellate: STEP or IGES to model.glb, keeping the assembly tree and names."""

from __future__ import annotations

from pathlib import Path

from ..job import EngineError, JobContext
from . import command

GLB = "model.glb"


def _tree(model, node) -> dict:
    out = {"name": node.name}
    if node.mesh is not None:
        out["triangles"] = model.meshes[node.mesh].triangle_count
    if node.children:
        out["children"] = [_tree(model, c) for c in node.children]
    return out


@command("tessellate")
def tessellate(ctx: JobContext) -> dict:
    # Imported here so other commands do not pay for loading OpenCascade.
    from OCP.OSD import OSD_ThreadPool

    from ..cad.meshio import write_glb
    from ..cad.tessellate import PRESETS, tessellate_file

    raw = ctx.params.get("path")
    if not raw:
        raise EngineError("params.path is required")
    path = Path(raw).expanduser()
    if not path.is_file():
        raise EngineError(f"file not found: {path}")
    preset = ctx.params.get("preset", "medium")
    if preset not in PRESETS:
        raise EngineError(f"unknown preset '{preset}'", f"expected one of {', '.join(PRESETS)}")

    # Keep OpenCascade's parallel mesher inside the per-job core limit.
    OSD_ThreadPool.DefaultPool_s(ctx.options.cores)

    model = tessellate_file(path, preset, progress=ctx.emit.progress)
    ctx.emit.progress(92, "writing model.glb")
    write_glb(model, ctx.workdir / GLB)
    lo, hi = model.bounds()
    return {
        "glb": GLB,
        "source": str(path),
        "preset": preset,
        "units": "m",
        "up_axis": "z",
        "meshes": len(model.meshes),
        "instances": len(model.instances()),
        "triangles": model.triangle_count,
        "bbox_min": lo.tolist(),
        "bbox_max": hi.tolist(),
        "tree": [_tree(model, r) for r in model.roots],
    }
