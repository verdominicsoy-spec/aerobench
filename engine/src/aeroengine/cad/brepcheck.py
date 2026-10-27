"""B-rep (STEP/IGES) checks and repair through OpenCascade.

These see problems a mesh cannot: faces and edges that fail OpenCascade's
validity checks, self-intersecting face boundaries, tiny edges, and free
(open) edges of surfaces that should be closed.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
from OCP.Bnd import Bnd_Box
from OCP.BRepBndLib import BRepBndLib
from OCP.BRepBuilderAPI import BRepBuilderAPI_Sewing
from OCP.BRepCheck import BRepCheck_Analyzer
from OCP.IFSelect import IFSelect_RetDone
from OCP.OCP.collections import IndexedDataMap_TopoDS_Shape_List_TopoDS_Shape_TopTools_ShapeMapHasher as EdgeFaceMap
from OCP.OCP.collections import Sequence_TDF_Label
from OCP.ShapeAnalysis import ShapeAnalysis_Wire
from OCP.ShapeFix import ShapeFix_Shape
from OCP.STEPCAFControl import STEPCAFControl_Writer
from OCP.STEPControl import STEPControl_AsIs
from OCP.TDF import TDF_Label
from OCP.TopAbs import TopAbs_EDGE, TopAbs_FACE, TopAbs_WIRE
from OCP.TopExp import TopExp, TopExp_Explorer
from OCP.TopoDS import TopoDS
from OCP.XCAFDoc import XCAFDoc_DocumentTool, XCAFDoc_ShapeTool

from ..job import EngineError
from .tessellate import MM, _entry, _name, _read

MAX_POINTS = 2000


def _centre(shape) -> list[float]:
    box = Bnd_Box()
    BRepBndLib.Add_s(shape, box)
    lo, hi = box.CornerMin(), box.CornerMax()
    return [(lo.X() + hi.X()) / 2 * MM, (lo.Y() + hi.Y()) / 2 * MM, (lo.Z() + hi.Z()) / 2 * MM]


def _subshapes(shape, kind):
    exp = TopExp_Explorer(shape, kind)
    while exp.More():
        yield exp.Current()
        exp.Next()


def _parts(doc):
    """(label, name) of every leaf part, once each."""
    tool = XCAFDoc_DocumentTool.ShapeTool_s(doc.Main())
    free = Sequence_TDF_Label()
    tool.GetFreeShapes(free)
    out, seen = [], set()

    def walk(label):
        if XCAFDoc_ShapeTool.IsAssembly_s(label):
            comps = Sequence_TDF_Label()
            XCAFDoc_ShapeTool.GetComponents_s(label, comps)
            for i in range(1, comps.Length() + 1):
                ref = TDF_Label()
                XCAFDoc_ShapeTool.GetReferredShape_s(comps.Value(i), ref)
                walk(ref)
        else:
            entry = _entry(label)
            if entry not in seen:
                seen.add(entry)
                out.append((label, _name(label) or f"Part {len(out) + 1}"))

    for i in range(1, free.Length() + 1):
        walk(free.Value(i))
    return out


def analyse_shape(shape, tolerance: float) -> dict:
    analyzer = BRepCheck_Analyzer(shape)
    res = {"valid": bool(analyzer.IsValid()), "invalid_faces": [], "invalid_edges": [], "free_edges": [],
           "self_intersecting_wires": [], "small_edges": []}
    for face in _subshapes(shape, TopAbs_FACE):
        f = TopoDS.Face(face)
        if not analyzer.IsValid(f):
            res["invalid_faces"].append(_centre(f))
        for wire in _subshapes(f, TopAbs_WIRE):
            sw = ShapeAnalysis_Wire(TopoDS.Wire(wire), f, tolerance)
            if sw.CheckSelfIntersection():
                res["self_intersecting_wires"].append(_centre(wire))
            if sw.CheckSmall(tolerance):
                res["small_edges"].append(_centre(wire))
    if not res["valid"]:
        for edge in _subshapes(shape, TopAbs_EDGE):
            if not analyzer.IsValid(edge):
                res["invalid_edges"].append(_centre(edge))
    emap = EdgeFaceMap()
    TopExp.MapShapesAndAncestors_s(shape, TopAbs_EDGE, TopAbs_FACE, emap)
    for i in range(1, emap.Extent() + 1):
        if emap.FindFromIndex(i).Size() == 1:
            res["free_edges"].append(_centre(emap.FindKey(i)))
    return res


def check_brep(path: Path, tolerance_mm: float = 0.01) -> dict:
    doc = _read(path)
    parts = _parts(doc)
    totals = {k: [] for k in ("invalid_faces", "invalid_edges", "free_edges", "self_intersecting_wires", "small_edges")}
    invalid_parts = []
    for label, name in parts:
        shape = XCAFDoc_ShapeTool.GetShape_s(label)
        r = analyse_shape(shape, tolerance_mm)
        if not r["valid"]:
            invalid_parts.append(name)
        for k in totals:
            totals[k] += r[k]

    def issue(kind, title, severity, points, detail, fixable):
        pts = np.asarray(points, float).reshape(-1, 3)
        if len(pts) > MAX_POINTS:
            pts = pts[np.linspace(0, len(pts) - 1, MAX_POINTS).round().astype(int)]
        return {"kind": kind, "title": title, "severity": severity, "count": len(points), "detail": detail,
                "fixable": fixable, "points": np.round(pts, 6).tolist()}

    issues = [
        issue("brep_invalid_faces", "Invalid faces (B-rep)", "error", totals["invalid_faces"],
              "Faces that fail OpenCascade's validity check (bad boundaries, curves off the surface, wrong orientation).", True),
        issue("brep_invalid_edges", "Invalid edges (B-rep)", "error", totals["invalid_edges"],
              "Edges whose curves or tolerances are inconsistent.", True),
        issue("brep_self_intersecting_wires", "Self-intersecting face boundaries", "error", totals["self_intersecting_wires"],
              "A face's boundary loop crosses itself.", True),
        issue("brep_small_edges", "Tiny edges", "warning", totals["small_edges"],
              f"Edges shorter than {tolerance_mm:g} mm. They often cause meshing and boolean failures.", True),
        issue("brep_free_edges", "Free edges (open surfaces)", "warning", totals["free_edges"],
              "Edges with a face on one side only. Expected for surface models; for solids it means gaps. Sewing can close small gaps.", True),
    ]
    return {"parts": len(parts), "invalid_parts": invalid_parts, "issues": issues,
            "problems": int(sum(i["count"] for i in issues if i["severity"] in ("error", "warning")))}


def repair_brep(path: Path, out: Path, sew_tolerance_mm: float = 0.01) -> dict:
    """ShapeFix on every part, sewing where it has free edges, written back
    out as STEP with the assembly and names kept."""
    doc = _read(path)
    parts = _parts(doc)
    tool = XCAFDoc_DocumentTool.ShapeTool_s(doc.Main())
    fixed, sewn = 0, 0
    for label, _ in parts:
        shape = XCAFDoc_ShapeTool.GetShape_s(label)
        before = analyse_shape(shape, sew_tolerance_mm)
        sf = ShapeFix_Shape(shape)
        sf.Perform()
        new = sf.Shape()
        if before["free_edges"]:
            sewing = BRepBuilderAPI_Sewing(sew_tolerance_mm)
            sewing.Add(new)
            sewing.Perform()
            new = sewing.SewedShape()
            sewn += 1
        if not new.IsSame(shape):
            tool.SetShape(label, new)
            fixed += 1
    tool.UpdateAssemblies()
    writer = STEPCAFControl_Writer()
    writer.SetNameMode(True)
    writer.Transfer(doc, STEPControl_AsIs)
    if writer.Write(str(out)) != IFSelect_RetDone:
        raise EngineError("could not write the repaired STEP file")
    return {"parts_changed": fixed, "parts_sewn": sewn}
