"""The part editor's geometry: points, splines, planes, surfaces, and the
operations that change the solid. Millimetres throughout. Operations that
change the solid also return OpenCascade's maker, whose history lets
references follow faces and edges through them.
"""

from __future__ import annotations

from OCP.BRep import BRep_Tool
from OCP.BRepAdaptor import BRepAdaptor_Curve, BRepAdaptor_Surface
from OCP.Bnd import Bnd_Box
from OCP.BRepAlgoAPI import BRepAlgoAPI_Cut, BRepAlgoAPI_Defeaturing, BRepAlgoAPI_Fuse
from OCP.BRepBndLib import BRepBndLib
from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeEdge, BRepBuilderAPI_MakeFace, BRepBuilderAPI_MakeVertex, BRepBuilderAPI_Transform
from OCP.BRepOffsetAPI import BRepOffsetAPI_MakeThickSolid
from OCP.BRepExtrema import BRepExtrema_DistShapeShape
from OCP.BRepGProp import BRepGProp
from OCP.BRepFilletAPI import BRepFilletAPI_MakeChamfer, BRepFilletAPI_MakeFillet
from OCP.BRepOffsetAPI import BRepOffsetAPI_MakeFilling
from OCP.BRepPrimAPI import BRepPrimAPI_MakePrism
from OCP.GeomAbs import GeomAbs_C0, GeomAbs_G1, GeomAbs_Plane
from OCP.GeomAPI import GeomAPI_Interpolate
from OCP.GProp import GProp_GProps
from OCP.gp import gp_Ax1, gp_Ax2, gp_Ax3, gp_Dir, gp_Pln, gp_Pnt, gp_Trsf, gp_Vec
from OCP.OCP.collections import List_TopoDS_Shape
from OCP.OCP.collections import HArray1_gp_Pnt as TColgp_HArray1OfPnt
from OCP.TopAbs import TopAbs_FACE, TopAbs_REVERSED
from OCP.OCP.collections import IndexedMap_TopoDS_Shape_TopTools_ShapeMapHasher as TopTools_IndexedMapOfShape
from OCP.TopExp import TopExp
from OCP.TopoDS import TopoDS

from ...job import EngineError
from ..bodyrepair import CLEAN_TOL_MM, _compound, _sew, free_edges, sew_stepped, to_solids

CLOSE_MM = 0.01  # a fill's boundary pieces must meet within this

STD = {
    "XY": gp_Pln(gp_Ax3(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1))),
    "YZ": gp_Pln(gp_Ax3(gp_Pnt(0, 0, 0), gp_Dir(1, 0, 0))),
    "ZX": gp_Pln(gp_Ax3(gp_Pnt(0, 0, 0), gp_Dir(0, 1, 0))),
}


def _xyz(p) -> str:
    return f"{p.X():.2f}, {p.Y():.2f}, {p.Z():.2f}"


def point_on_edge(edge, t: float) -> gp_Pnt:
    c = BRepAdaptor_Curve(edge)
    return c.Value(c.FirstParameter() + (c.LastParameter() - c.FirstParameter()) * t)


def point_on_face(face, u: float, v: float) -> gp_Pnt:
    s = BRepAdaptor_Surface(face)
    return s.Value(s.FirstUParameter() + (s.LastUParameter() - s.FirstUParameter()) * u,
                   s.FirstVParameter() + (s.LastVParameter() - s.FirstVParameter()) * v)


def point_near(sub, p: gp_Pnt) -> gp_Pnt:
    """The point of an edge or face nearest `p`: where a click lands on it."""
    d = BRepExtrema_DistShapeShape(BRepBuilderAPI_MakeVertex(p).Vertex(), sub)
    if not d.IsDone() or d.NbSolution() == 0:
        raise EngineError("the point could not be placed on that edge or face")
    return d.PointOnShape2(1)


def spline(points: list[gp_Pnt]):
    """A curve through every point, in order; two points make a line."""
    if len(points) < 2:
        raise EngineError("a spline needs two or more points")
    if len(points) == 2:
        return BRepBuilderAPI_MakeEdge(points[0], points[1]).Edge()
    arr = TColgp_HArray1OfPnt(1, len(points))
    for i, p in enumerate(points):
        arr.SetValue(i + 1, p)
    interp = GeomAPI_Interpolate(arr, False, 1e-6)
    interp.Perform()
    if not interp.IsDone():
        raise EngineError("no spline runs through those points", "two of them may be on top of each other")
    return BRepBuilderAPI_MakeEdge(interp.Curve()).Edge()


def face_plane(face) -> gp_Pln:
    s = BRepAdaptor_Surface(face)
    if s.GetType() != GeomAbs_Plane:
        raise EngineError("pick a flat face", "a plane needs a flat face as its reference")
    return s.Plane()


def offset(plane: gp_Pln, mm: float) -> gp_Pln:
    """The plane moved along its normal."""
    return plane.Translated(gp_Vec(plane.Axis().Direction()).Multiplied(mm)) if mm else plane


def plane_through(reference: gp_Pln, point: gp_Pnt) -> gp_Pln:
    return gp_Pln(point, reference.Axis().Direction())


def _moved(shape, v: gp_Vec):
    t = gp_Trsf()
    t.SetTranslation(v)
    return BRepBuilderAPI_Transform(shape, t, True).Shape()


def extrude(curve, plane: gp_Pln, distance: float, symmetric: bool):
    """A surface swept from `curve` along the plane's normal."""
    n = gp_Vec(plane.Axis().Direction())
    if symmetric:
        curve = TopoDS.Edge(_moved(curve, n.Multiplied(-distance)))
        distance *= 2
    return TopoDS.Face(BRepPrimAPI_MakePrism(curve, n.Multiplied(distance)).Shape())


def _ends(edge):
    return [BRep_Tool.Pnt_s(TopExp.FirstVertex_s(edge)), BRep_Tool.Pnt_s(TopExp.LastVertex_s(edge))]


def fill(boundary: list[tuple]):
    """A surface inside a closed loop of edges. An edge given with a face is
    held tangent to that face (G1); one without only has to meet (C0)."""
    for i, (e, _) in enumerate(boundary):
        a, b = _ends(e), _ends(boundary[(i + 1) % len(boundary)][0])
        gap = min(p.Distance(q) for p in a for q in b)
        if gap > CLOSE_MM:
            at = min(((p, q) for p in a for q in b), key=lambda pq: pq[0].Distance(pq[1]))[0]
            raise EngineError(f"the boundary is open at {_xyz(at)} mm", f"a {gap:.2f} mm gap between pieces {i + 1} and {i + 2}")
    try:
        filling = BRepOffsetAPI_MakeFilling()
        for e, face in boundary:
            if face is None:
                filling.Add(e, GeomAbs_C0)
            else:
                filling.Add(e, face, GeomAbs_G1)
        filling.Build()
        if not filling.IsDone():
            raise RuntimeError
        return TopoDS.Face(filling.Shape())
    except Exception:
        raise EngineError("the fill could not be built", "try a simpler boundary, or fewer tangent edges")


def _fuse(a, b, fuzzy: float = CLEAN_TOL_MM):
    args, tools = List_TopoDS_Shape(), List_TopoDS_Shape()
    args.Append(a)
    tools.Append(b)
    op = BRepAlgoAPI_Fuse()
    op.SetArguments(args)
    op.SetTools(tools)
    op.SetFuzzyValue(fuzzy)
    op.Build()
    if not op.IsDone():
        raise EngineError("the new material could not be joined to the part")
    return op.Shape(), op


def add(solid, surfaces: list):
    """Closes the surfaces into a volume and fuses it onto the solid."""
    # Sew once at the cleanup tolerance first: faces that already share edges
    # have no gaps for stepped sewing to close, and still need a shell.
    sewn, _ = sew_stepped(_sew(_compound(surfaces), CLEAN_TOL_MM), 0.5)
    solids, open_ = to_solids(sewn)
    if open_ or not solids:
        where = "; ".join(_xyz(_ends(e)[0]) for e in free_edges(sewn)[:4])
        raise EngineError("the surfaces do not close a volume", f"open at {where} mm" if where else None)
    volume = solids[0] if len(solids) == 1 else _compound(solids)
    return _fuse(solid, volume)


def _built(maker, what: str, hint: str):
    try:
        maker.Build()
        if not maker.IsDone():
            raise RuntimeError
        return maker.Shape(), maker
    except Exception:
        raise EngineError(f"the {what} could not be built", hint)


def fillet(solid, edges: list, radius: float):
    """Constant radius; OpenCascade carries on along edges that meet tangentially."""
    mk = BRepFilletAPI_MakeFillet(solid)
    for e in edges:
        mk.Add(radius, e)
    return _built(mk, f"{radius:g} mm fillet", "try a smaller radius")


def chamfer(solid, edges: list, distance: float):
    mk = BRepFilletAPI_MakeChamfer(solid)
    for e in edges:
        mk.Add(distance, e)
    return _built(mk, f"{distance:g} mm chamfer", "try a smaller distance")


def pushpull(solid, face, distance: float):
    """Moves a flat face along its outward normal: material added when
    positive, cut away when negative."""
    s = BRepAdaptor_Surface(face)
    if s.GetType() != GeomAbs_Plane:
        raise EngineError("push/pull works on flat faces", "this face is curved")
    n = gp_Vec(s.Plane().Axis().Direction())
    if face.Orientation() == TopAbs_REVERSED:
        n.Reverse()
    if distance >= 0:
        return _fuse(solid, BRepPrimAPI_MakePrism(face, n.Multiplied(distance)).Shape())
    op = BRepAlgoAPI_Cut(solid, BRepPrimAPI_MakePrism(face, n.Multiplied(distance)).Shape())
    if not op.IsDone():
        raise EngineError("the face could not be pushed in")
    return op.Shape(), op


def _signed_volume(shape) -> float:
    p = GProp_GProps()
    BRepGProp.VolumeProperties_s(shape, p)
    return p.Mass()


def _box(shape):
    b = Bnd_Box()
    BRepBndLib.Add_s(shape, b)
    return b


def delete_faces(solid, faces: list):
    """Removes faces and heals the gap from the faces around them: a hole,
    fillet, chamfer or boss taken off, as for a cleaner CFD model."""
    mk = BRepAlgoAPI_Defeaturing()
    mk.SetShape(solid)
    for f in faces:
        mk.AddFaceToRemove(f)
    mk.SetRunParallel(True)
    try:
        mk.Build()
        ok = mk.IsDone()
    except Exception:
        ok = False
    if ok:  # a face it cannot heal comes back untouched with only a warning: check they are gone
        left = TopTools_IndexedMapOfShape()
        TopExp.MapShapes_s(mk.Shape(), TopAbs_FACE, left)
        ok = not any(left.Contains(f) for f in faces)
    if not ok:
        raise EngineError("the faces could not be removed",
                          "the faces around them must be able to grow over the gap: pick a whole hole, fillet or boss")
    return mk.Shape(), mk


def move(solid, dx: float, dy: float, dz: float, rx: float, ry: float, rz: float):
    """Turns the part about its own centre, X then Y then Z (degrees), then shifts it (mm)."""
    lo, hi = _box(solid).CornerMin(), _box(solid).CornerMax()
    c = gp_Pnt((lo.X() + hi.X()) / 2, (lo.Y() + hi.Y()) / 2, (lo.Z() + hi.Z()) / 2)
    t = gp_Trsf()
    for angle, axis in ((rx, gp_Dir(1, 0, 0)), (ry, gp_Dir(0, 1, 0)), (rz, gp_Dir(0, 0, 1))):
        if angle:
            r = gp_Trsf()
            r.SetRotation(gp_Ax1(c, axis), angle * 3.141592653589793 / 180)
            t = r.Multiplied(t)
    shift = gp_Trsf()
    shift.SetTranslation(gp_Vec(dx, dy, dz))
    mk = BRepBuilderAPI_Transform(solid, shift.Multiplied(t), True)
    return mk.Shape(), mk


def mirror(solid, plane: gp_Pln, keep: bool):
    """Reflects the part in a plane: joined to the original when `keep`, else in its place."""
    t = gp_Trsf()
    t.SetMirror(gp_Ax2(plane.Location(), plane.Axis().Direction()))
    mk = BRepBuilderAPI_Transform(solid, t, True)
    if not keep:
        return mk.Shape(), mk
    return _fuse(solid, mk.Shape())


def cut_by_plane(solid, plane: gp_Pln, flip: bool):
    """Cuts the part with a plane, keeping the side behind its normal (or in front, with `flip`)."""
    b = _box(solid)
    size = 4 * b.CornerMin().Distance(b.CornerMax()) + 1
    n = gp_Vec(plane.Axis().Direction())
    if flip:  # the tool takes the side the normal points to
        n.Reverse()
    origin = plane.Location()
    sheet = BRepBuilderAPI_MakeFace(gp_Pln(origin, gp_Dir(n)), -size, size, -size, size).Face()
    tool = BRepPrimAPI_MakePrism(sheet, n.Multiplied(size)).Shape()
    op = BRepAlgoAPI_Cut(solid, tool)
    if not op.IsDone():
        raise EngineError("the part could not be cut by that plane")
    out = op.Shape()
    kept, whole = abs(_signed_volume(out)), abs(_signed_volume(solid))
    if kept < 1e-9 or abs(kept - whole) < 1e-9 * max(whole, 1):
        raise EngineError("the plane misses the part", "move the plane so it passes through the part, or flip the side kept")
    return out, op


def thicken(solid, surfaces: list, thickness: float):
    """Gives surfaces a thickness (mm, along their normal; negative the other way) and joins
    the material to the part: an endplate or gurney from a fill or extrude."""
    pieces = []
    for f in surfaces:
        mk = BRepOffsetAPI_MakeThickSolid()
        try:
            mk.MakeThickSolidBySimple(f, thickness)
            mk.Build()
            if not mk.IsDone():
                raise RuntimeError
        except Exception:
            raise EngineError(f"a {thickness:g} mm thickness could not be built", "try a thinner one, or a smoother surface")
        piece = mk.Shape()
        if _signed_volume(piece) < 0:  # MakeThickSolidBySimple can hand back the solid inside out
            piece = piece.Reversed()
        pieces.append(piece)
    return _fuse(solid, pieces[0] if len(pieces) == 1 else _compound(pieces))
