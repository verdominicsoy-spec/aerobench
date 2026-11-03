"""2D meshes of a car section, with any wings placed on it, for SU2: the
booleans in OCP, the mesh in gmsh's built-in kernel (gmsh's own
OpenCascade kernel crashes in a process that has loaded OCP).

* Outlines of the cut and the wings' elements become faces, fused into
  solid obstacles: nested and overlapping outlines (a tyre cut as a ring,
  solids that overlap in the CAD, a front wing running through the nose)
  become one shape. The fluid is a box over the ground minus the obstacles.
* Markers are given afterwards by which outline each wall curve lies on
  (wing first), so a wing fused into the nose keeps its own forces.
* A wheel standing on the ground gets a contact block up to 5 mm above the
  floor merged with it: a tyre touching the floor at one point leaves a
  sliver no mesher can fill.
* Body and wheels get fine triangles sized for wall functions (y+ about
  30 to 100); wings get quad wall layers for y+ about 1, as Wing Lab's
  meshes do. Quad layers on a real car's many sharp corners fail, and wall
  functions do not need them.

Coordinates: the section's (x, z) mm become (X, Y) m with X = -x (the car
faces the flow, which runs along +X) and Y = z - ground.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

from OCP.BRep import BRep_Tool
from OCP.BRepAlgoAPI import BRepAlgoAPI_Cut, BRepAlgoAPI_Fuse
from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeFace, BRepBuilderAPI_MakePolygon
from OCP.BRepTools import BRepTools, BRepTools_WireExplorer
from OCP.gp import gp_Pnt
from OCP.OCP.collections import List_TopoDS_Shape
from OCP.ShapeUpgrade import ShapeUpgrade_UnifySameDomain
from OCP.TopAbs import TopAbs_FACE, TopAbs_WIRE
from OCP.TopoDS import TopoDS

from ..cad.bodyrepair import _subshapes
from ..job import EngineError
from ..wing.mesh import boundary_layer_thickness, first_cell_height, layers_for

NU = 1.81e-5 / 1.225
CONTACT_M = 0.005

PRESETS = {  # wall size on body and wheels (m), wing surface size (fraction of chord), growth away from walls
    "coarse": {"wall": 0.02, "wing": 0.01, "far": 0.6},
    "medium": {"wall": 0.008, "wing": 0.006, "far": 0.5},
    "maxed": {"wall": 0.003, "wing": 0.004, "far": 0.4},
}


def _to_m(points, ground: float) -> np.ndarray:
    p = np.asarray(points, float)
    return np.c_[-p[:, 0] / 1000.0, (p[:, 1] - ground) / 1000.0]


def _resample(p: np.ndarray, h: float, corner_deg: float = 25.0) -> np.ndarray:
    """Points no further apart than h, keeping sharp corners."""
    closed = np.vstack([p, p[:1]])
    seg = np.diff(closed, axis=0)
    a, b = np.roll(seg, 1, axis=0), seg
    cos = np.einsum("ij,ij->i", a, b) / np.maximum(np.linalg.norm(a, axis=1) * np.linalg.norm(b, axis=1), 1e-15)
    corner = np.degrees(np.arccos(np.clip(cos, -1, 1))) > corner_deg
    out = []
    for i in range(len(p)):
        start, d = closed[i], seg[i]
        length = float(np.linalg.norm(d))
        n = max(int(np.ceil(length / h)), 1)
        for k in range(n):
            if k == 0 or not corner[i] or True:
                out.append(start + d * (k / n))
    q = np.asarray(out)
    # drop near-duplicates (keeps gmsh from zero-length lines)
    keep = [0]
    for i in range(1, len(q)):
        if np.linalg.norm(q[i] - q[keep[-1]]) > h * 0.2:
            keep.append(i)
    q = q[keep]
    if np.linalg.norm(q[0] - q[-1]) < h * 0.2:
        q = q[:-1]
    return q


def _seg_distance(pt: np.ndarray, poly: np.ndarray) -> float:
    a, b = poly, np.roll(poly, -1, axis=0)
    ab = b - a
    t = np.clip(np.einsum("ij,ij->i", pt - a, ab) / np.maximum(np.einsum("ij,ij->i", ab, ab), 1e-30), 0, 1)
    return float(np.min(np.linalg.norm(a + ab * t[:, None] - pt, axis=1)))


def _face(poly: np.ndarray):
    mk = BRepBuilderAPI_MakePolygon()
    for x, y in poly:
        mk.Add(gp_Pnt(float(x), float(y), 0.0))
    mk.Close()
    return BRepBuilderAPI_MakeFace(mk.Wire(), True).Face()


def _fuse(faces: list):
    if len(faces) == 1:
        return faces[0]
    args, tools = List_TopoDS_Shape(), List_TopoDS_Shape()
    args.Append(faces[0])
    for f in faces[1:]:
        tools.Append(f)
    op = BRepAlgoAPI_Fuse()
    op.SetArguments(args)
    op.SetTools(tools)
    op.SetFuzzyValue(1e-7)
    op.Build()
    if not op.IsDone():
        raise EngineError("the outlines of this section could not be merged")
    unify = ShapeUpgrade_UnifySameDomain(op.Shape(), False, True, False)  # merge faces, keep edges for the markers
    unify.Build()
    return unify.Shape()


def _cut(domain, solid):
    op = BRepAlgoAPI_Cut(domain, solid)
    if not op.IsDone():
        raise EngineError("the section could not be cut out of the flow domain")
    return op.Shape()


def _loops(shape) -> list[list[list[tuple[float, float]]]]:
    out = []
    for f in _subshapes(shape, TopAbs_FACE):
        face = TopoDS.Face(f)
        outer = BRepTools.OuterWire_s(face)
        wires = [outer] + [TopoDS.Wire(w) for w in _subshapes(face, TopAbs_WIRE) if not w.IsSame(outer)]
        polys = []
        for w in wires:
            exp = BRepTools_WireExplorer(TopoDS.Wire(w), face)
            pts = []
            while exp.More():
                p = BRep_Tool.Pnt_s(exp.CurrentVertex())
                pts.append((p.X(), p.Y()))
                exp.Next()
            if len(pts) >= 3:
                polys.append(pts)
        if polys:
            out.append(polys)
    return out


def build(section: dict, wings: list[dict], setup: dict, preset: str, out: Path) -> dict:
    """Meshes the section and writes `out` (.su2). Returns statistics."""
    import gmsh

    if preset not in PRESETS:
        raise EngineError(f"unknown mesh setting '{preset}'", ", ".join(PRESETS))
    if not section.get("loops") and not wings:
        raise EngineError("nothing to mesh at this plane", "move the plane onto the car")
    ps = PRESETS[preset]
    ground = float(setup["ground_z"])
    speed = float(setup.get("speed", 15.0))
    shapes = []  # (marker, polygon in m)
    for lp in section.get("loops", []):
        marker = f"wheel_{lp['wheel']}" if lp.get("kind") == "wheel" and lp.get("wheel") else "body"
        shapes.append((marker, _resample(_to_m(lp["points"], ground), ps["wall"])))
    wing_polys = []
    for w in wings:
        for el in w["elements"]:
            m = _to_m(el, ground)
            chord = float(np.ptp(m[:, 0]))
            poly = _resample(m, max(ps["wing"] * chord, 1e-4))
            wing_polys.append((f"wing_{w['position']}", poly, chord))
            shapes.append((f"wing_{w['position']}", poly))
    allp = np.vstack([p for _, p in shapes])
    x0, x1 = float(allp[:, 0].min()), float(allp[:, 0].max())
    length = max(x1 - x0, 0.1)
    height = max(float(allp[:, 1].max()), 0.1)

    xi, xo, top = x0 - 3 * length, x1 + 6 * length, 4 * height
    obstacles = [_face(p) for _, p in shapes]
    for marker, p in shapes:  # wheels on the ground stand on a contact block
        if marker.startswith("wheel_") and p[:, 1].min() < CONTACT_M:
            low = p[p[:, 1] < CONTACT_M]
            xa, xb = float(low[:, 0].min()), float(low[:, 0].max())
            pad = max(xb - xa, 0.004) * 0.5
            obstacles.append(_face(np.array([[xa - pad, -0.05], [xb + pad, -0.05], [xb + pad, CONTACT_M], [xa - pad, CONTACT_M]])))
    solid = _fuse(obstacles)
    fluid = _cut(_face(np.array([[xi, 0], [xo, 0], [xo, top], [xi, top]])), solid)
    loops = _loops(fluid)  # [outer, hole, hole...] per fluid face, each a list of (x, y)
    if not loops:
        raise EngineError("the section fills the whole domain")
    n_obstacles = sum(len(face_loops) - 1 for face_loops in loops)  # holes in the fluid: separate solid shapes

    gmsh.initialize(interruptible=False)
    try:
        gmsh.option.setNumber("General.Terminal", 0)
        gmsh.model.add("car")
        geo = gmsh.model.geo
        ids: dict = {}

        def point(x, y):
            key = (round(x, 9), round(y, 9))
            if key not in ids:
                ids[key] = geo.addPoint(x, y, 0)
            return ids[key]

        groups: dict[str, list[int]] = {}
        wall_curves, wing_curves = [], []
        fans = set()  # where wing wall layers need a fan: meeting the body, and sharp corners
        tol = 1e-7 * max(length, 1)
        surfaces = []
        for face_loops in loops:
            curve_loops = []
            for poly in face_loops:
                curves = []
                for k in range(len(poly)):
                    (xa, ya), (xb, yb) = poly[k], poly[(k + 1) % len(poly)]
                    c = geo.addLine(point(xa, ya), point(xb, yb))
                    curves.append(c)
                    mx, my = (xa + xb) / 2, (ya + yb) / 2
                    if abs(my) < tol and abs(ya) < tol and abs(yb) < tol:
                        name = "ground"
                    elif abs(mx - xi) < tol:
                        name = "inlet"
                    elif abs(mx - xo) < tol:
                        name = "outlet"
                    elif abs(my - top) < tol:
                        name = "top"
                    else:
                        pt = np.array([mx, my])
                        dist = [(_seg_distance(pt, q), m) for m, q in shapes]
                        wing = [d for d in dist if d[1].startswith("wing_") and d[0] < 2e-4]
                        name = wing[0][1] if wing else min(dist)[1]
                        (wing_curves if name.startswith("wing_") else wall_curves).append(c)
                    groups.setdefault(name, []).append(c)
                curve_loops.append(geo.addCurveLoop(curves))
                names = [next(n for n, cs in groups.items() if c in cs) for c in curves]
                for k in range(len(poly)):  # vertex k joins curve k-1 and curve k
                    before, after = names[k - 1], names[k]
                    if not (before.startswith("wing_") or after.startswith("wing_")):
                        continue
                    a = np.subtract(poly[k], poly[k - 1])
                    b = np.subtract(poly[(k + 1) % len(poly)], poly[k])
                    turn = np.degrees(np.arccos(np.clip(np.dot(a, b) / max(np.linalg.norm(a) * np.linalg.norm(b), 1e-30), -1, 1)))
                    if before != after or turn > 60:
                        fans.add(point(*poly[k]))
            surfaces.append(geo.addPlaneSurface(curve_loops))
        geo.synchronize()
        for name, curves in groups.items():
            gmsh.model.addPhysicalGroup(1, curves, name=name)
        gmsh.model.addPhysicalGroup(2, surfaces, name="fluid")

        fld = gmsh.model.mesh.field
        fields = []
        if wall_curves:
            dist = fld.add("Distance")
            fld.setNumbers(dist, "CurvesList", wall_curves)
            fld.setNumber(dist, "Sampling", 200)
            th = fld.add("Threshold")
            fld.setNumber(th, "InField", dist)
            fld.setNumber(th, "SizeMin", ps["wall"])
            fld.setNumber(th, "SizeMax", ps["far"] * length)
            fld.setNumber(th, "DistMin", 2 * ps["wall"])
            fld.setNumber(th, "DistMax", 2 * length)
            fields.append(th)
        wake = fld.add("Box")  # behind the car and under it, where the flow is busiest
        fld.setNumber(wake, "VIn", 4 * ps["wall"])
        fld.setNumber(wake, "VOut", ps["far"] * length)
        fld.setNumber(wake, "XMin", x0)
        fld.setNumber(wake, "XMax", x1 + 1.5 * length)
        fld.setNumber(wake, "YMin", 0)
        fld.setNumber(wake, "YMax", 1.3 * height)
        fld.setNumber(wake, "Thickness", 0.5 * length)
        fields.append(wake)
        first = None
        if wing_curves:
            chord = max(c for _, _, c in wing_polys)
            re = speed * chord / NU
            first = first_cell_height(re, chord, 1.0)
            thickness = 1.2 * boundary_layer_thickness(re, chord)
            if layers_for(first, 1.15, thickness) < 10:
                thickness = first * 40
            bl = fld.add("BoundaryLayer")
            fld.setNumbers(bl, "CurvesList", wing_curves)
            fld.setNumber(bl, "Size", first)
            fld.setNumber(bl, "Ratio", 1.15)
            fld.setNumber(bl, "Thickness", thickness)
            fld.setNumber(bl, "Quads", 1)
            fld.setNumbers(bl, "FanPointsList", sorted(fans))
            fld.setAsBoundaryLayer(bl)
            dw = fld.add("Distance")
            fld.setNumbers(dw, "CurvesList", wing_curves)
            tw = fld.add("Threshold")
            fld.setNumber(tw, "InField", dw)
            fld.setNumber(tw, "SizeMin", ps["wing"] * chord)
            fld.setNumber(tw, "SizeMax", ps["far"] * length)
            fld.setNumber(tw, "DistMin", 2 * thickness)
            fld.setNumber(tw, "DistMax", 3 * chord)
            fields.append(tw)
        mins = fld.add("Min")
        fld.setNumbers(mins, "FieldsList", fields)
        fld.setAsBackgroundMesh(mins)
        gmsh.option.setNumber("Mesh.MeshSizeExtendFromBoundary", 0)
        gmsh.option.setNumber("Mesh.MeshSizeFromPoints", 0)
        gmsh.option.setNumber("Mesh.MeshSizeFromCurvature", 0)
        gmsh.option.setNumber("Mesh.Algorithm", 6)
        gmsh.model.mesh.generate(2)
        types, tags, _ = gmsh.model.mesh.getElements(2)
        counts = {gmsh.model.mesh.getElementProperties(t)[0]: len(tg) for t, tg in zip(types, tags)}
        out.parent.mkdir(parents=True, exist_ok=True)
        gmsh.option.setNumber("Mesh.SaveAll", 0)
        gmsh.write(str(out))
    finally:
        gmsh.finalize()
    tri = sum(v for k, v in counts.items() if "Triangle" in k)
    quad = sum(v for k, v in counts.items() if "Quadrilateral" in k)
    if tri + quad == 0:
        raise EngineError("gmsh produced no cells")
    return {"file": out.name, "cells": int(tri + quad), "triangles": int(tri), "quads": int(quad),
            "markers": sorted(groups), "obstacles": n_obstacles, "wall_size_m": ps["wall"],
            "wing_first_cell_m": first, "domain": [xi, xo, top]}
