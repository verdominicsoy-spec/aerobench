"""cad-check and cad-repair: geometry health for STEP, IGES, STL and OBJ."""

from __future__ import annotations

from pathlib import Path

import numpy as np

from ..job import EngineError, JobContext
from . import command

UNITS = {"mm": 0.001, "m": 1.0, "in": 0.0254}


def _source(ctx: JobContext) -> Path:
    raw = ctx.params.get("path")
    if not raw:
        raise EngineError("params.path is required")
    path = Path(raw).expanduser()
    if not path.is_file():
        raise EngineError(f"file not found: {path}")
    return path


def _model(ctx: JobContext, path: Path):
    from ..cad import meshio
    from ..cad.tessellate import tessellate_file

    ext = path.suffix.lower()
    scale = UNITS.get(ctx.params.get("units", "mm"), 0.001)
    if ext in (".step", ".stp", ".iges", ".igs"):
        return tessellate_file(path, ctx.params.get("preset", "medium"), progress=lambda p, m: ctx.emit.progress(p * 0.4, m))
    if ext == ".stl":
        return meshio.read_stl(path, scale)
    if ext == ".obj":
        return meshio.read_obj(path, scale)
    if ext == ".glb":
        return meshio.read_glb(path)
    raise EngineError(f"cannot check .{ext.lstrip('.')} files")


def _soup(model):
    from ..cad.meshcheck import Soup

    verts, faces, body, names = [], [], [], []
    base = 0
    for k, (path, world, mesh) in enumerate(model.instances()):
        p = mesh.positions.astype(np.float64) @ world[:3, :3].T + world[:3, 3]
        verts.append(p)
        faces.append(mesh.indices.astype(np.int64) + base)
        body.append(np.full(len(mesh.indices), k))
        names.append("/".join(path[1:] or path))
        base += len(p)
    if not verts:
        raise EngineError("the file contains no triangles")
    return Soup(np.concatenate(verts), np.concatenate(faces), np.concatenate(body), names)


@command("cad-check")
def cad_check(ctx: JobContext) -> dict:
    from ..cad.meshcheck import check

    path = _source(ctx)
    model = _model(ctx, path)
    ctx.emit.progress(45, "checking the mesh")
    report = {"file": str(path), "mesh": check(_soup(model), intersections=bool(ctx.params.get("intersections", True)))}
    if path.suffix.lower() in (".step", ".stp", ".iges", ".igs"):
        from ..cad.brepcheck import check_brep

        ctx.emit.progress(75, "checking the B-rep")
        report["brep"] = check_brep(path, float(ctx.params.get("tolerance_mm", 0.01)))
    issues = report["mesh"]["issues"] + report.get("brep", {}).get("issues", [])
    report["problems"] = int(sum(i["count"] for i in issues if i["severity"] in ("error", "warning")))
    return report


@command("cad-repair")
def cad_repair(ctx: JobContext) -> dict:
    from ..cad.meshcheck import check, repair

    path = _source(ctx)
    ext = path.suffix.lower()
    if ext in (".step", ".stp", ".iges", ".igs"):
        from ..cad.brepcheck import check_brep, repair_brep

        out = ctx.workdir / f"{path.stem}_repaired.step"
        ctx.emit.progress(10, "fixing shapes and sewing")
        done = repair_brep(path, out, float(ctx.params.get("tolerance_mm", 0.01)))
        ctx.emit.progress(70, "checking the result")
        after = check_brep(out, float(ctx.params.get("tolerance_mm", 0.01)))
        return {"output": out.name, "done": done, "after": {"problems": after["problems"], "issues": [
            {k: i[k] for k in ("kind", "title", "count")} for i in after["issues"]]}}

    from ..cad import meshio
    from ..cad.meshcheck import Soup

    scale = UNITS.get(ctx.params.get("units", "mm"), 0.001)
    model = _model(ctx, path)
    soup = _soup(model)
    ctx.emit.progress(40, "repairing")
    fixed, done = repair(soup, max_hole_edges=int(ctx.params.get("max_hole_edges", 64)))
    ctx.emit.progress(70, "checking the result")
    after = check(fixed, intersections=bool(ctx.params.get("intersections", True)))
    # Write back in the file's own units and format, one object per body for OBJ.
    meshes, nodes = [], []
    for b in np.unique(fixed.body):
        f = fixed.faces[fixed.body == b]
        used, inv = np.unique(f, return_inverse=True)
        pos = fixed.vertices[used].astype(np.float32)
        idx = inv.reshape(-1, 3).astype(np.uint32)
        name = fixed.body_names[b] if b < len(fixed.body_names) else f"Body {b + 1}"
        meshes.append(meshio.Mesh(pos, meshio.vertex_normals(pos, idx), idx, name))
        nodes.append(meshio.Node(name, mesh=len(meshes) - 1))
    out_model = meshio.Model(meshes, [meshio.Node(path.stem, children=nodes)])
    if ext == ".obj":
        out = ctx.workdir / f"{path.stem}_repaired.obj"
        meshio.write_obj(out_model, out, scale=1 / scale)
    else:
        out = ctx.workdir / f"{path.stem}_repaired.stl"
        meshio.write_stl(out_model, out, scale=1 / scale)
    return {"output": out.name, "done": done,
            "after": {"problems": after["problems"], "issues": [{k: i[k] for k in ("kind", "title", "count")} for i in after["issues"]]}}
