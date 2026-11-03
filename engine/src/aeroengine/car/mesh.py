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
from OCP.BRepAlgoAPI import BRepAlgoAPI_Cut
from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeFace, BRepBuilderAPI_MakePolygon
from OCP.BRepTools import BRepTools, BRepTools_WireExplorer
from OCP.gp import gp_Pnt
from OCP.OCP.collections import List_TopoDS_Shape
from OCP.TopAbs import TopAbs_FACE, TopAbs_WIRE
from OCP.TopoDS import TopoDS

from ..cad.bodyrepair import _subshapes
from ..job import EngineError
from ..wing.mesh import boundary_layer_thickness, first_cell_height, layers_for

NU = 1.81e-5 / 1.225
CONTACT_M = 0.005
MERGE_M = 1e-5  # outline vertices closer than this are one

PRESETS = {  # wall size on body and wheels (m), wing surface size (fraction of chord), growth away from walls
    "coarse": {"wall": 0.012, "wing": 0.01, "far": 0.6},
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


def _split_pinches(poly: list) -> list[list]:
    """A loop that passes through one vertex twice (two solids touching at a
    point) split there into simple loops, which gmsh can mesh."""
    keys = [(round(x, 9), round(y, 9)) for x, y in poly]
    seen: dict = {}
    for j, k in enumerate(keys):
        if k in seen:
            i = seen[k]
            return _split_pinches(poly[i:j]) + _split_pinches(poly[j:] + poly[:i])
        seen[k] = j
    return [poly]


def _signed_area(poly) -> float:
    p = np.asarray(poly, float)
    return 0.5 * float(np.dot(p[:, 0], np.roll(p[:, 1], -1)) - np.dot(p[:, 1], np.roll(p[:, 0], -1)))


def _shoelace(poly) -> float:
    p = np.asarray(poly, float)
    return 0.5 * abs(float(np.dot(p[:, 0], np.roll(p[:, 1], -1)) - np.dot(p[:, 1], np.roll(p[:, 0], -1))))


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


def _cut(domain, tools: list):
    args, tl = List_TopoDS_Shape(), List_TopoDS_Shape()
    args.Append(domain)
    for t in tools:
        tl.Append(t)
    op = BRepAlgoAPI_Cut()
    op.SetArguments(args)
    op.SetTools(tl)
    op.SetFuzzyValue(1e-7)
    op.Build()
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
            # The boolean leaves vertices nanometres apart where outlines met; as
            # separate points they make zero-length walls SU2 cannot partition.
            clean = []
            for p in pts:
                if not clean or np.hypot(p[0] - clean[-1][0], p[1] - clean[-1][1]) > MERGE_M:
                    clean.append(p)
            while len(clean) > 1 and np.hypot(clean[0][0] - clean[-1][0], clean[0][1] - clean[-1][1]) <= MERGE_M:
                clean.pop()
            pieces = [q for q in _split_pinches(clean) if len(q) >= 3]
            if len(pieces) > 1:  # pieces turning the other way are air enclosed by the pinch: not flow round the car
                main = max(pieces, key=lambda q: abs(_signed_area(q)))
                pieces = [q for q in pieces if _signed_area(q) * _signed_area(main) > 0]
            polys += pieces
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
    # Every obstacle as its own tool in one cut: OpenCascade's general fuse
    # sorts out where they overlap. (Fusing them first left overlapping
    # regions on the real car, whose holes in the fluid then overlapped.)
    fluid = _cut(_face(np.array([[xi, 0], [xo, 0], [xo, top], [xi, top]])), obstacles)
    # [outer, hole, hole...] per fluid face. Only the face whose outer edge is
    # the domain is the flow round the car: others are air enclosed inside
    # the car's outline, and their walls would duplicate the main face's.
    loops = [fl for fl in _loops(fluid) if min(p[0] for p in fl[0]) <= xi + 1e-9]
    # Holes smaller than a quarter cell (slivers where two solids nearly meet)
    # cannot be meshed and are too small to matter to the flow: dropped.
    tiny = (ps["wall"] ** 2) / 4
    loops = [[fl[0]] + [h for h in fl[1:] if _shoelace(h) >= tiny] for fl in loops]
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

        tol = 1e-7 * max(length, 1)
        surfaces = []
        for face_loops in loops:
            curve_loops = []
            for poly in face_loops:
                curves = [geo.addLine(point(*poly[k]), point(*poly[(k + 1) % len(poly)])) for k in range(len(poly))]
                curve_loops.append(geo.addCurveLoop(curves))
            surfaces.append(geo.addPlaneSurface(curve_loops))
        # Outlines that touch give the same segment twice: one curve each, or
        # gmsh leaves wall elements on nodes it never writes.
        geo.removeAllDuplicates()
        geo.synchronize()
        surfaces = [t for _, t in gmsh.model.getEntities(2)]

        def name_of(c: int) -> str:
            lo, hi = gmsh.model.getParametrizationBounds(1, c)
            x, y, _ = gmsh.model.getValue(1, c, [(lo[0] + hi[0]) / 2])
            if abs(y) < tol:
                return "ground"
            if abs(x - xi) < tol:
                return "inlet"
            if abs(x - xo) < tol:
                return "outlet"
            if abs(y - top) < tol:
                return "top"
            pt = np.array([x, y])
            dist = [(_seg_distance(pt, q), m) for m, q in shapes]
            wing = [d for d in dist if d[1].startswith("wing_") and d[0] < 2e-4]
            return wing[0][1] if wing else min(dist)[1]

        groups: dict[str, list[int]] = {}
        curve_name: dict[int, str] = {}
        for _, c in gmsh.model.getBoundary([(2, t) for t in surfaces], oriented=False, combined=False):
            c = abs(c)
            if c in curve_name:
                continue
            curve_name[c] = name_of(c)
            groups.setdefault(curve_name[c], []).append(c)
        wall_curves = [c for c, n in curve_name.items() if n == "body" or n.startswith("wheel_")]
        wing_curves = [c for c, n in curve_name.items() if n.startswith("wing_")]
        # Wing wall layers need a fan where a wing curve meets another kind of
        # surface, and at sharp corners (a trailing edge).
        fans = set()
        ends: dict[int, list[int]] = {}
        for c in wing_curves + wall_curves:
            for _, pnt in gmsh.model.getBoundary([(1, c)], oriented=False):
                ends.setdefault(abs(pnt), []).append(c)
        for pnt, cs in ends.items():
            kinds = {curve_name[c] for c in cs}
            if not any(k.startswith("wing_") for k in kinds):
                continue
            if len(kinds) > 1 or len(cs) != 2:
                fans.add(pnt)
                continue
            dirs = []
            for c in cs:
                lo, hi = gmsh.model.getParametrizationBounds(1, c)
                a = np.array(gmsh.model.getValue(1, c, [lo[0]])[:2])
                b = np.array(gmsh.model.getValue(1, c, [hi[0]])[:2])
                here = np.array(gmsh.model.getValue(0, pnt, [])[:2])
                far = b if np.linalg.norm(a - here) < np.linalg.norm(b - here) else a
                dirs.append(far - here)
            cos = np.dot(dirs[0], dirs[1]) / max(np.linalg.norm(dirs[0]) * np.linalg.norm(dirs[1]), 1e-30)
            if np.degrees(np.arccos(np.clip(cos, -1, 1))) < 120:  # the two curves fold back sharply
                fans.add(pnt)
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
