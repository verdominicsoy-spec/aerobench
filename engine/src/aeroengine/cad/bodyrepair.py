"""STEP repair to one closed body.

Small defects are fixed without asking: tiny edges and sliver faces at a
cleanup tolerance, and gaps up to an automatic limit by sewing at the
smallest tolerance that closes them. Larger gaps inside a part become items
the user reviews; gaps between parts are never touched, so wing slots stay
open. Every solid is then fused into one body.
"""

from __future__ import annotations

from dataclasses import dataclass

from OCP.Bnd import Bnd_Box
from OCP.BRep import BRep_Builder
from OCP.BRepAdaptor import BRepAdaptor_Curve
from OCP.BRepBndLib import BRepBndLib
from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeVertex, BRepBuilderAPI_MakeWire, BRepBuilderAPI_Sewing
from OCP.BRepExtrema import BRepExtrema_DistShapeShape
from OCP.BRepGProp import BRepGProp
from OCP.BRepOffsetAPI import BRepOffsetAPI_MakeFilling, BRepOffsetAPI_ThruSections
from OCP.GeomAbs import GeomAbs_C0
from OCP.GProp import GProp_GProps
from OCP.gp import gp_Pnt
from OCP.OCP.collections import IndexedDataMap_TopoDS_Shape_List_TopoDS_Shape_TopTools_ShapeMapHasher as EdgeFaceMap
from OCP.ShapeFix import ShapeFix_FixSmallFace, ShapeFix_Shape, ShapeFix_Solid, ShapeFix_Wireframe
from OCP.TopAbs import TopAbs_EDGE, TopAbs_FACE, TopAbs_SHELL, TopAbs_SOLID
from OCP.TopExp import TopExp
from OCP.TopoDS import TopoDS, TopoDS_Compound

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


# Gaps and holes -------------------------------------------------------------

QUEUE_MAX_MM = 10.0
SAMPLES = 11


@dataclass
class Gap:
    edges: tuple
    size_mm: float
    centre_mm: tuple
    lines_mm: list


@dataclass
class Hole:
    edges: list
    centre_mm: tuple
    lines_mm: list


def _points(edge, n: int = SAMPLES) -> list[tuple[float, float, float]]:
    c = BRepAdaptor_Curve(edge)
    t0, t1 = c.FirstParameter(), c.LastParameter()
    out = []
    for k in range(n):
        p = c.Value(t0 + (t1 - t0) * k / (n - 1))
        out.append((p.X(), p.Y(), p.Z()))
    return out


def _length(edge) -> float:
    props = GProp_GProps()
    BRepGProp.LinearProperties_s(edge, props)
    return props.Mass()


def _distance(a, b) -> float:
    d = BRepExtrema_DistShapeShape(a, b)
    return d.Value() if d.IsDone() else float("inf")


def _gap_size(a, b) -> float:
    """Largest distance from points along the shorter edge to the other."""
    if _length(a) > _length(b):
        a, b = b, a
    return max(_distance(BRepBuilderAPI_MakeVertex(gp_Pnt(*p)).Vertex(), b) for p in _points(a))


def _box(edge, pad: float) -> Bnd_Box:
    box = Bnd_Box()
    BRepBndLib.Add_s(edge, box)
    box.Enlarge(pad)
    return box


def _mean(points) -> tuple:
    return tuple(sum(p[i] for p in points) / len(points) for i in range(3))


def find_gaps(shape) -> list[Gap]:
    """Pairs of free edges facing each other across a gap, within one
    shape. A pair counts when its size is under half the shorter edge's
    length; wider, it is the rim of a hole, not a gap. Mutual nearest
    pairs only, sorted by size. Sizes above QUEUE_MAX_MM are kept (the
    caller reports them)."""
    edges = free_edges(shape)
    boxes = [_box(e, QUEUE_MAX_MM * 2) for e in edges]
    best: dict[int, tuple[float, int]] = {}
    for i in range(len(edges)):
        for j in range(i + 1, len(edges)):
            if boxes[i].IsOut(_box(edges[j], 0)):
                continue
            size = _gap_size(edges[i], edges[j])
            if size >= 0.5 * min(_length(edges[i]), _length(edges[j])):
                continue
            for a, b in ((i, j), (j, i)):
                if a not in best or size < best[a][0]:
                    best[a] = (size, b)
    gaps = []
    for i, (size, j) in best.items():
        if i < j and best.get(j, (None, None))[1] == i:
            lines = [_points(edges[i]), _points(edges[j])]
            gaps.append(Gap((edges[i], edges[j]), size, _mean(lines[0] + lines[1]), lines))
    return sorted(gaps, key=lambda g: g.size_mm)


def _with(shape, face):
    comp = TopoDS_Compound()
    b = BRep_Builder()
    b.MakeCompound(comp)
    b.Add(comp, shape)
    b.Add(comp, face)
    return _sew(comp, CLEAN_TOL_MM)


def bridge(shape, gap: Gap):
    """Closes a gap with a ruled face between its two edges; the faces on
    either side do not move. A ruled loft rather than BRepFill.Face, which
    follows the curves' parameter direction and twists when they run
    opposite ways."""
    loft = BRepOffsetAPI_ThruSections(False, True)
    for e in gap.edges:
        loft.AddWire(BRepBuilderAPI_MakeWire(e).Wire())
    loft.CheckCompatibility(True)
    loft.Build()
    return _with(shape, loft.Shape())


def find_holes(shape, gaps: list[Gap]) -> list[Hole]:
    """Free edges in no gap, grouped by shared vertices into closed loops.
    Edges that form no closed loop are not holes."""
    used = [e for g in gaps for e in g.edges]
    edges = [e for e in free_edges(shape) if not any(e.IsSame(u) for u in used)]
    ends = [(TopExp.FirstVertex_s(e), TopExp.LastVertex_s(e)) for e in edges]
    groups: list[list[int]] = []
    for i in range(len(edges)):
        touching = [g for g in groups if any(v.IsSame(w) for k in g for v in ends[i] for w in ends[k])]
        merged = [i] + [k for g in touching for k in g]
        groups = [g for g in groups if g not in touching] + [merged]
    holes = []
    for g in groups:
        verts = [v for k in g for v in ends[k]]
        if all(sum(v.IsSame(w) for w in verts) == 2 for v in verts):
            lines = [_points(edges[k]) for k in g]
            holes.append(Hole([edges[k] for k in g], _mean([p for line in lines for p in line]), lines))
    return holes


def fill(shape, hole: Hole):
    """Patches a hole with a filling surface; None when it fails or leaves
    free edges."""
    try:
        filling = BRepOffsetAPI_MakeFilling()
        for e in hole.edges:
            filling.Add(e, GeomAbs_C0)
        filling.Build()
        if not filling.IsDone():
            return None
        out = _with(shape, filling.Shape())
    except Exception:
        return None
    return None if free_edges(out) else out


# Item ids and saved decisions ----------------------------------------------


def item_id(kind: str, part: str, centre_mm) -> str:
    """Deterministic for the same input file, so a plan's ids hold for the apply run."""
    x, y, z = centre_mm
    return f"{kind}:{part}:{x:.1f},{y:.1f},{z:.1f}"


def match_decision(kind: str, part: str, centre_mm, saved: list[dict], within_mm: float = 3.0) -> str | None:
    """The decision of the nearest saved entry of the same kind and part
    within `within_mm` (part-local), or None."""
    best, found = within_mm, None
    for d in saved:
        if d.get("kind") != kind or d.get("part") != part:
            continue
        dist = sum((a - b) ** 2 for a, b in zip(centre_mm, d.get("centre_mm", ()))) ** 0.5
        if dist <= best:
            best, found = dist, d.get("decision")
    return found
