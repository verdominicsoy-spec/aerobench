"""Flow Field Viewer commands: demo, preview, reconstruct, iso, export."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from ..job import EngineError, JobContext
from . import command


def _path(ctx: JobContext, key: str) -> Path:
    raw = ctx.params.get(key)
    if not raw:
        raise EngineError(f"params.{key} is required")
    p = Path(raw).expanduser()
    if not p.exists():
        raise EngineError(f"not found: {p}")
    return p


def _calibration(ctx: JobContext):
    from ..flow.calibration import Calibration

    return Calibration(ctx.params.get("calibration"))


@command("flow-demo")
def flow_demo(ctx: JobContext) -> dict:
    from ..flow.synthetic import VIEWS, make_sweep

    perspective = bool(ctx.params.get("perspective", True))
    frames = int(ctx.params.get("frames", 121))
    view = ctx.params.get("view", "front")
    if view not in VIEWS:
        raise EngineError(f"view must be one of {', '.join(VIEWS)}")
    ctx.emit.progress(5, "rendering and encoding demo sweep")
    cal = make_sweep(ctx.workdir / "demo.mp4", frames=frames, perspective=perspective, view=view)
    (ctx.workdir / "demo_calibration.json").write_text(json.dumps(cal, indent=2))
    return {"video": "demo.mp4", "calibration": "demo_calibration.json", "frames": frames, "perspective": perspective,
            "view": view}


@command("flow-detect")
def flow_detect(ctx: JobContext) -> dict:
    """Finds the crop, the overlays to exclude, the legend bar and whether the
    ground is in view, so the calibration starts filled in."""
    from ..flow.detect import detect
    from ..flow.reconstruct import FrameSource

    source = FrameSource(_path(ctx, "source"))
    partial = ctx.params.get("calibration") or {}
    if not isinstance(partial, dict):
        raise EngineError("params.calibration must be an object")
    ctx.emit.progress(5, "reading frames across the sweep")
    return detect(source, partial)


@command("flow-preview")
def flow_preview(ctx: JobContext) -> dict:
    import cv2

    from ..flow.reconstruct import colorize, preview

    cal = _calibration(ctx)
    source = _path(ctx, "source")
    frame = int(ctx.params.get("frame", cal.first_frame))
    values, y, z, stats, rgb = preview(source, cal, frame)
    img = colorize(values, cal.vmin, cal.vmax, rgb)
    cv2.imwrite(str(ctx.workdir / "preview.png"), cv2.cvtColor(img, cv2.COLOR_RGBA2BGRA))
    finite = values[~np.isnan(values)]
    return {
        "image": "preview.png",
        "frame": frame,
        "y": [float(y[0]), float(y[-1])],
        "z": [float(z[0]), float(z[-1])],
        "grid": [len(y), len(z)],
        "median_dE": stats["median_dE"],
        "empty_fraction": stats["empty_fraction"],
        "value_min": float(finite.min()) if finite.size else None,
        "value_max": float(finite.max()) if finite.size else None,
    }


@command("flow-reconstruct")
def flow_reconstruct(ctx: JobContext) -> dict:
    from ..flow.reconstruct import reconstruct

    cal = _calibration(ctx)
    source = _path(ctx, "source")
    vol, summary = reconstruct(source, cal, progress=ctx.emit.progress)
    meta = vol.save(ctx.workdir, ctx.params["calibration"], str(source))
    (ctx.workdir / "calibration.json").write_text(json.dumps(ctx.params["calibration"], indent=2))
    ctx.emit.log(f"{summary['planes']} planes, median colour distance {summary['median_dE']:.1f}, "
                 f"{100 * summary['empty_fraction']:.0f}% empty")
    return {
        "volume": "volume.npz",
        "raw": "volume.bin",
        "meta": "volume.json",
        "shape": meta["shape"],
        "x": [float(vol.x[0]), float(vol.x[-1])],
        "y": [float(vol.y[0]), float(vol.y[-1])],
        "z": [float(vol.z[0]), float(vol.z[-1])],
        **summary,
    }


@command("flow-iso")
def flow_iso(ctx: JobContext) -> dict:
    from ..cad.meshio import Model, Node, write_glb, write_obj
    from ..flow.iso import enclosed_volume, isosurface
    from ..flow.reconstruct import Volume

    vol = Volume.load(_path(ctx, "volume"))
    levels = ctx.params.get("levels")
    if not isinstance(levels, list) or not levels:
        raise EngineError("params.levels must be a non-empty list of values")
    fill = ctx.params.get("fill")
    meshes, nodes, out = [], [], []
    for k, level in enumerate(levels):
        mesh = isosurface(vol, float(level), None if fill is None else float(fill))
        ctx.emit.progress(10 + 80 * (k + 1) / len(levels), f"Cp0 = {level}: {mesh.triangle_count} triangles")
        out.append({"level": float(level), "triangles": mesh.triangle_count,
                    "volume": enclosed_volume(mesh) if mesh.triangle_count else 0.0})
        if mesh.triangle_count:
            meshes.append(mesh)
            nodes.append(Node(mesh.name, mesh=len(meshes) - 1))
    model = Model(meshes, [Node("Isosurfaces", children=nodes)])
    write_glb(model, ctx.workdir / "iso.glb")
    if meshes:
        write_obj(model, ctx.workdir / "iso.obj", scale=1000.0)  # mm, like a CAD export
    return {"glb": "iso.glb", "obj": "iso.obj" if meshes else None, "levels": out}


@command("flow-object")
def flow_object(ctx: JobContext) -> dict:
    from ..cad.meshio import Model, Node, write_glb, write_obj
    from ..flow.iso import enclosed_volume, object_surface
    from ..flow.reconstruct import Volume

    vol = Volume.load(_path(ctx, "volume"))
    ground = ctx.params.get("ground_z", 0.0)
    mesh = object_surface(vol, None if ground is None else float(ground), float(ctx.params.get("smooth", 1.0)))
    model = Model([mesh] if mesh.triangle_count else [], [Node("Object", mesh=0 if mesh.triangle_count else None)])
    write_glb(model, ctx.workdir / "object.glb")
    if mesh.triangle_count:
        write_obj(model, ctx.workdir / "object.obj", scale=1000.0)
    return {"glb": "object.glb", "triangles": mesh.triangle_count,
            "volume": enclosed_volume(mesh) if mesh.triangle_count else 0.0}


@command("flow-export")
def flow_export(ctx: JobContext) -> dict:
    from ..flow.iso import write_vti
    from ..flow.reconstruct import Volume

    vol = Volume.load(_path(ctx, "volume"))
    write_vti(vol, ctx.workdir / "volume.vti")
    return {"vti": "volume.vti"}
