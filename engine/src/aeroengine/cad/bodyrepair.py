"""STEP repair to one closed body.

Small defects are fixed without asking: tiny edges and sliver faces at a
cleanup tolerance, and gaps up to an automatic limit by sewing at the
smallest tolerance that closes them. Larger gaps inside a part become items
the user reviews; gaps between parts are never touched, so wing slots stay
open. Every solid is then fused into one body.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from OCP.Bnd import Bnd_Box
from OCP.BRep import BRep_Builder
from OCP.BRepAdaptor import BRepAdaptor_Curve
from OCP.BRepBndLib import BRepBndLib
from OCP.BRepAlgoAPI import BRepAlgoAPI_Fuse
from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeVertex, BRepBuilderAPI_MakeWire, BRepBuilderAPI_Sewing
from OCP.BRepCheck import BRepCheck_Analyzer
from OCP.BRepExtrema import BRepExtrema_DistShapeShape
from OCP.BRepGProp import BRepGProp
from OCP.BRepOffsetAPI import BRepOffsetAPI_MakeFilling, BRepOffsetAPI_ThruSections
from OCP.GeomAbs import GeomAbs_C0
from OCP.GProp import GProp_GProps
from OCP.gp import gp_Pnt, gp_Trsf
from OCP.IFSelect import IFSelect_RetDone
from OCP.OCP.collections import IndexedDataMap_TopoDS_Shape_List_TopoDS_Shape_TopTools_ShapeMapHasher as EdgeFaceMap
from OCP.ShapeFix import ShapeFix_FixSmallFace, ShapeFix_Shape, ShapeFix_Solid, ShapeFix_Wireframe
from OCP.ShapeUpgrade import ShapeUpgrade_UnifySameDomain
from OCP.STEPCAFControl import STEPCAFControl_Writer
from OCP.STEPControl import STEPControl_AsIs
from OCP.TCollection import TCollection_ExtendedString
from OCP.TDataStd import TDataStd_Name
from OCP.TDocStd import TDocStd_Document
from OCP.TopAbs import TopAbs_EDGE, TopAbs_FACE, TopAbs_SHELL, TopAbs_SOLID
from OCP.TopExp import TopExp
from OCP.TopLoc import TopLoc_Location
from OCP.TopoDS import TopoDS, TopoDS_Compound
from OCP.OCP.collections import List_TopoDS_Shape as TopTools_ListOfShape
from OCP.XCAFDoc import XCAFDoc_DocumentTool, XCAFDoc_ShapeTool

from ..job import EngineError
from .brepcheck import _instances, _parts, _subshapes
from .tessellate import MM, _entry, _read

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


# The pipeline ----------------------------------------------------------------


def _compound(shapes):
    comp = TopoDS_Compound()
    b = BRep_Builder()
    b.MakeCompound(comp)
    for s in shapes:
        b.Add(comp, s)
    return comp


def _placement(world: np.ndarray) -> TopLoc_Location:
    """A world matrix (translation in metres) as an OCP location in mm."""
    t = gp_Trsf()
    m = world.copy()
    m[:3, 3] /= MM
    t.SetValues(*m[:3].ravel())
    return TopLoc_Location(t)


def _world(points_mm, world: np.ndarray) -> list[list[float]]:
    p = np.asarray(points_mm, float).reshape(-1, 3) * MM
    return np.round(p @ world[:3, :3].T + world[:3, 3], 7).tolist()


def _fuse(solids):
    """One body from every solid, or None when OpenCascade's fuse fails.
    The fuzzy value is the cleanup tolerance, so parts a fraction of a mm
    apart are not merged."""
    try:
        args, tools = TopTools_ListOfShape(), TopTools_ListOfShape()
        args.Append(solids[0])
        for s in solids[1:]:
            tools.Append(s)
        op = BRepAlgoAPI_Fuse()
        op.SetArguments(args)
        op.SetTools(tools)
        op.SetFuzzyValue(CLEAN_TOL_MM)
        op.Build()
        if not op.IsDone():
            return None
        unify = ShapeUpgrade_UnifySameDomain(op.Shape(), True, True, False)
        unify.Build()
        return unify.Shape()
    except Exception:
        return None


def _saved(decisions: Path | None) -> list[dict]:
    if decisions is None or not decisions.is_file():
        return []
    try:
        return list(json.loads(decisions.read_text()).get("decisions", []))
    except (ValueError, AttributeError) as e:
        raise EngineError(f"could not read {decisions.name}", f"delete it to start the decisions afresh ({e})")


def repair_body(path: Path, out: Path, limit_mm: float = 0.5, accept: set[str] | None = None,
                decisions: Path | None = None, progress=lambda pct, msg: None) -> dict:
    """Every part cleaned, sewn and closed, then fused into one body and
    written to `out`. Without `accept` this is the plan run: medium gaps
    and holes become pending items (left open) and the file is still
    written. Items carry the decision applied on this run: accepted ids
    first, then saved decisions."""
    accept = accept or set()
    saved = _saved(decisions)
    doc = _read(path)
    instances = _instances(doc)
    parts = _parts(doc)
    auto = {"parts": len(parts), "parts_sewn": 0, "small_edges_removed": 0, "small_faces_removed": 0, "max_sew_mm": None}
    items, placed_solids, placed_open, open_parts = [], [], [], []

    for n, (label, name) in enumerate(parts):
        progress(60 * n / max(len(parts), 1), f"repairing {name}")
        worlds = [w for lab, _, w in instances if _entry(lab) == _entry(label)] or [np.eye(4)]

        def item(kind, centre_mm, lines_mm, size_mm=None, fix=None, decide=True):
            iid = item_id(kind, name, centre_mm)
            decision = None
            if decide:
                decision = "accept" if iid in accept else match_decision(kind, name, centre_mm, saved)
            items.append({"id": iid, "kind": kind, "part": name, "size_mm": None if size_mm is None else round(size_mm, 4),
                          "centre": _world([centre_mm], worlds[0])[0], "centre_mm": [round(c, 4) for c in centre_mm],
                          "lines": [_world(line, w) for w in worlds for line in lines_mm], "fix": fix, "decision": decision})
            return decision

        shape, stats = clean_part(XCAFDoc_ShapeTool.GetShape_s(label))
        for k in ("small_edges_removed", "small_faces_removed"):
            auto[k] += stats[k]
        shape, tol = sew_stepped(shape, limit_mm)
        if tol is not None:
            auto["parts_sewn"] += 1
            auto["max_sew_mm"] = max(auto["max_sew_mm"] or 0.0, tol)

        to_bridge = []
        for g in find_gaps(shape):
            if g.size_mm <= limit_mm:  # sewing did not close it: still automatic
                to_bridge.append(g.centre_mm)
            elif g.size_mm <= QUEUE_MAX_MM:
                if item("gap", g.centre_mm, g.lines_mm, g.size_mm, "bridge") == "accept":
                    to_bridge.append(g.centre_mm)
            else:
                item("wide_gap", g.centre_mm, g.lines_mm, g.size_mm, decide=False)
        for c in to_bridge:  # bridging rebuilds edges, so find each gap again by its centre
            g = next((g for g in find_gaps(shape) if max(abs(a - b) for a, b in zip(g.centre_mm, c)) < 0.01), None)
            if g is not None:
                shape = bridge(shape, g)

        for h in find_holes(shape, find_gaps(shape)):
            filled = fill(shape, h)
            if item("hole", h.centre_mm, h.lines_mm, fix="fill" if filled is not None else "open_shell") == "accept" \
                    and filled is not None:
                shape = filled

        solids, open_ = to_solids(shape)
        if open_:
            open_parts.append(name)
        for w in worlds:
            loc = _placement(w)
            placed_solids += [s.Moved(loc) for s in solids]
            placed_open += [(name, s.Moved(loc)) for s in open_]

    progress(60, "fusing")
    fused = True
    if len(placed_solids) > 1:
        body = _fuse(placed_solids)
        if body is None:
            fused, body = False, _compound(placed_solids)
    else:
        body = placed_solids[0] if placed_solids else _compound([])

    progress(85, "checking the result")
    everything = _compound([body] + [s for _, s in placed_open])
    free = free_edges(everything)
    nonmanifold = nonmanifold_edges(body)
    for e in nonmanifold:
        pts = _points(e)
        items.append({"id": item_id("nonmanifold_edge", path.stem, _mean(pts)), "kind": "nonmanifold_edge",
                      "part": path.stem, "size_mm": None, "centre": _world([_mean(pts)], np.eye(4))[0],
                      "centre_mm": [round(c, 4) for c in _mean(pts)], "lines": [_world(pts, np.eye(4))],
                      "fix": None, "decision": None})
    valid = bool(BRepCheck_Analyzer(everything).IsValid())
    solid_count = sum(1 for _ in _subshapes(body, TopAbs_SOLID))
    result = {"solids": solid_count, "open_shells": len(placed_open), "open_parts": open_parts, "fused": fused,
              "free_edges": len(free), "nonmanifold_edges": len(nonmanifold), "valid": valid}
    result["closed"] = fused and valid and not free and not placed_open and not nonmanifold and solid_count > 0

    progress(92, "writing")
    _write(out, [(path.stem, body)] + placed_open)
    progress(100, "done")
    return {"output": out.name, "limit_mm": limit_mm, "auto": auto, "items": items, "result": result}


def _write(out: Path, named_shapes) -> None:
    doc = TDocStd_Document(TCollection_ExtendedString("XmlOcaf"))
    tool = XCAFDoc_DocumentTool.ShapeTool_s(doc.Main())
    for name, shape in named_shapes:
        TDataStd_Name.Set_s(tool.AddShape(shape, False), TCollection_ExtendedString(name))
    writer = STEPCAFControl_Writer()
    writer.SetNameMode(True)
    writer.Transfer(doc, STEPControl_AsIs)
    if writer.Write(str(out)) != IFSelect_RetDone:
        raise EngineError("could not write the repaired STEP file")
