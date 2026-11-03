"""STEP repair to one closed body.

Small defects are fixed without asking: tiny edges and sliver faces at a
cleanup tolerance, and gaps up to an automatic limit by sewing at the
smallest tolerance that closes them. Larger gaps inside a part become items
the user reviews; gaps between parts are never touched, so wing slots stay
open. Every solid is then fused into one body.
"""

from __future__ import annotations

from OCP.BRepBuilderAPI import BRepBuilderAPI_Sewing
from OCP.OCP.collections import IndexedDataMap_TopoDS_Shape_List_TopoDS_Shape_TopTools_ShapeMapHasher as EdgeFaceMap
from OCP.ShapeFix import ShapeFix_FixSmallFace, ShapeFix_Shape, ShapeFix_Solid, ShapeFix_Wireframe
from OCP.TopAbs import TopAbs_EDGE, TopAbs_FACE, TopAbs_SHELL, TopAbs_SOLID
from OCP.TopExp import TopExp
from OCP.TopoDS import TopoDS

from .brepcheck import _subshapes

CLEAN_TOL_MM = 0.01  # never the gap limit: thin trailing edges and lips must survive
SEW_STEPS_MM = (0.01, 0.02, 0.05, 0.1, 0.2, 0.5)


def _edge_faces(shape) -> EdgeFaceMap:
    emap = EdgeFaceMap()
    TopExp.MapShapesAndAncestors_s(shape, TopAbs_EDGE, TopAbs_FACE, emap)
    return emap


def free_edges(shape) -> list:
    """Edges with a face on one side only."""
    emap = _edge_faces(shape)
    return [TopoDS.Edge(emap.FindKey(i)) for i in range(1, emap.Extent() + 1) if emap.FindFromIndex(i).Size() == 1]


def nonmanifold_edges(shape) -> list:
    """Edges shared by three or more faces."""
    emap = _edge_faces(shape)
    return [TopoDS.Edge(emap.FindKey(i)) for i in range(1, emap.Extent() + 1) if emap.FindFromIndex(i).Size() >= 3]


def clean_part(shape, tol_mm: float = CLEAN_TOL_MM):
    """ShapeFix at `tol_mm`, then tiny edges and sliver faces removed."""
    sf = ShapeFix_Shape(shape)
    sf.SetPrecision(tol_mm)
    sf.SetMaxTolerance(tol_mm)
    sf.Perform()
    out = sf.Shape()
    edges = sum(1 for _ in _subshapes(out, TopAbs_EDGE))
    wf = ShapeFix_Wireframe(out)
    wf.SetPrecision(tol_mm)
    wf.FixSmallEdges()
    out = wf.Shape()
    small_edges = edges - sum(1 for _ in _subshapes(out, TopAbs_EDGE))
    faces = sum(1 for _ in _subshapes(out, TopAbs_FACE))
    ff = ShapeFix_FixSmallFace()
    ff.Init(out)
    ff.SetPrecision(tol_mm)
    ff.Perform()
    out = ff.FixShape()
    small_faces = faces - sum(1 for _ in _subshapes(out, TopAbs_FACE))
    return out, {"small_edges_removed": max(small_edges, 0), "small_faces_removed": max(small_faces, 0)}


def _sew(shape, tol_mm: float):
    sewing = BRepBuilderAPI_Sewing(tol_mm)
    sewing.Add(shape)
    sewing.Perform()
    return sewing.SewedShape()


def sew_stepped(shape, limit_mm: float):
    """Sews at the smallest step up to `limit_mm` that leaves no free edges,
    so features thinner than the limit are not stitched together. A shape
    with no free edges comes back untouched, with tolerance None."""
    if not free_edges(shape):
        return shape, None
    steps = [s for s in SEW_STEPS_MM if s < limit_mm] + [limit_mm]
    out = shape
    for tol in steps:
        out = _sew(shape, tol)
        if not free_edges(out):
            break
    return out, tol


def to_solids(shape):
    """([solid], [open shell]): closed shells become solids, oriented
    outward; existing solids pass through."""
    solids = [TopoDS.Solid(s) for s in _subshapes(shape, TopAbs_SOLID)]
    open_ = []
    in_solid = [s for solid in solids for s in _subshapes(solid, TopAbs_SHELL)]
    for s in _subshapes(shape, TopAbs_SHELL):
        if any(s.IsSame(t) for t in in_solid):
            continue
        shell = TopoDS.Shell(s)
        if free_edges(shell):
            open_.append(shell)
            continue
        fix = ShapeFix_Solid()
        solids.append(TopoDS.Solid(fix.SolidFromShell(shell)))
    return solids, open_
