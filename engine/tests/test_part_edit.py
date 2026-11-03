"""The part editor: references, operations, rebuild."""

from __future__ import annotations

import pytest
from OCP.Bnd import Bnd_Box
from OCP.BRepBndLib import BRepBndLib
from OCP.BRepFilletAPI import BRepFilletAPI_MakeFillet
from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox
from OCP.gp import gp_Vec
from stepfixtures import write_parts

from aeroengine.cad.edit.refs import History, Topology, load_part
from aeroengine.job import EngineError


def box(d=100.0):
    return BRepPrimAPI_MakeBox(d, d, d).Shape()


def bounds(shape):
    b = Bnd_Box()
    BRepBndLib.Add_s(shape, b)
    lo, hi = b.CornerMin(), b.CornerMax()
    return (lo.X(), lo.Y(), lo.Z()), (hi.X(), hi.Y(), hi.Z())


def centre(shape):
    lo, hi = bounds(shape)
    return tuple(round((a + b) / 2, 6) for a, b in zip(lo, hi))


def test_a_single_part_loads_in_its_own_frame(tmp_path):
    step = write_parts(tmp_path / "p.stp", {"Box": box()}, {"Box": [gp_Vec(500, 0, 0)]})
    shape, names, fp = load_part(step, None)
    assert names == ["Box"] and bounds(shape)[0][0] == pytest.approx(0, abs=1e-6)
    assert fp.count(":") == 2


def test_several_parts_need_a_name(tmp_path):
    step = write_parts(tmp_path / "two.stp", {"A": box(), "B": box(50)})
    with pytest.raises(EngineError, match="pick a part"):
        load_part(step, None)
    shape, names, _ = load_part(step, "B")
    assert names == ["A", "B"] and bounds(shape)[1][0] == pytest.approx(50)


def test_topology_order_is_stable():
    a, b = Topology(box()), Topology(box())
    assert len(a.faces) == 6 and len(a.edges) == 12
    assert [centre(f) for f in a.faces] == [centre(f) for f in b.faces]
    assert a.index(a.edges[3]) == 3


def test_an_edge_follows_a_fillet_and_a_filleted_edge_is_gone():
    solid = box()
    t = Topology(solid)
    hist = History(solid)
    mk = BRepFilletAPI_MakeFillet(solid)
    mk.Add(10.0, t.edges[0])
    mk.Build()
    hist.apply(mk, solid)
    e0 = centre(t.edges[0])
    # an edge sharing no vertex with edge 0 stays one piece
    far = max(range(len(t.edges)), key=lambda i: sum((a - b) ** 2 for a, b in zip(centre(t.edges[i]), e0)))
    assert hist.forward(t.edges[0]) == []
    assert len(hist.forward(t.edges[far])) == 1


# Geometry operations -------------------------------------------------------

import math  # noqa: E402

from OCP.BRepAdaptor import BRepAdaptor_Surface  # noqa: E402
from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeEdge  # noqa: E402
from OCP.BRepGProp import BRepGProp  # noqa: E402
from OCP.BRepPrimAPI import BRepPrimAPI_MakeCylinder  # noqa: E402
from OCP.GeomAPI import GeomAPI_ProjectPointOnSurf  # noqa: E402
from OCP.GProp import GProp_GProps  # noqa: E402
from OCP.gp import gp_Pnt  # noqa: E402
from OCP.BRep import BRep_Tool  # noqa: E402

from aeroengine.cad.edit import ops  # noqa: E402
from test_bodyrepair import faces_of_box  # noqa: E402


def volume(shape):
    p = GProp_GProps()
    BRepGProp.VolumeProperties_s(shape, p)
    return abs(p.Mass())


def area(shape):
    p = GProp_GProps()
    BRepGProp.SurfaceProperties_s(shape, p)
    return p.Mass()


def edge_at(shape, c):
    return next(e for e in Topology(shape).edges if all(abs(a - b) < 1e-6 for a, b in zip(centre(e), c)))


def face_at(shape, c):
    return next(f for f in Topology(shape).faces if all(abs(a - b) < 1e-6 for a, b in zip(centre(f), c)))


def xyz(p):
    return (p.X(), p.Y(), p.Z())


def test_point_on_edge_midway():
    assert xyz(ops.point_on_edge(edge_at(box(), (50, 0, 0)), 0.5)) == pytest.approx((50, 0, 0))


def test_spline_passes_through_its_points():
    pts = [gp_Pnt(0, 0, 0), gp_Pnt(30, 10, 0), gp_Pnt(60, 0, 5), gp_Pnt(100, 20, 0)]
    e = ops.spline(pts)
    for p in pts:
        d = BRepBuilderAPI_MakeEdge(p, gp_Pnt(p.X() + 1e-3, p.Y(), p.Z())).Edge()
        from OCP.BRepExtrema import BRepExtrema_DistShapeShape
        assert BRepExtrema_DistShapeShape(e, d).Value() < 1e-6


def test_plane_through_a_point_is_parallel():
    pl = ops.plane_through(ops.STD["XY"], gp_Pnt(5, 5, 30))
    assert pl.Location().Z() == pytest.approx(30) and xyz(pl.Axis().Direction()) == pytest.approx((0, 0, 1))


def test_extrude_symmetric_area():
    line = BRepBuilderAPI_MakeEdge(gp_Pnt(0, 0, 0), gp_Pnt(100, 0, 0)).Edge()
    f = ops.extrude(line, ops.STD["XY"], 10, True)
    lo, hi = bounds(f)
    assert area(f) == pytest.approx(2000) and lo[2] == pytest.approx(-10) and hi[2] == pytest.approx(10)


def test_fill_is_tangent_to_the_part():
    # an endplate-like extension: the fill carries on from a plate's edge, tangent to the plate
    from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeFace
    plate = BRepBuilderAPI_MakeFace(ops.STD["XY"], 0, 100, 0, 100).Face()
    edge = edge_at(plate, (100, 50, 0))
    line = lambda a, b: BRepBuilderAPI_MakeEdge(gp_Pnt(*a), gp_Pnt(*b)).Edge()
    face = ops.fill([(edge, plate), (line((100, 100, 0), (150, 100, -10)), None),
                     (line((150, 100, -10), (150, 0, -10)), None), (line((150, 0, -10), (100, 0, 0)), None)])
    s = BRepAdaptor_Surface(face)
    u, v = GeomAPI_ProjectPointOnSurf(gp_Pnt(100, 50, 0), BRep_Tool.Surface_s(face)).LowerDistanceParameters()
    n = s.DN(u, v, 1, 0).Crossed(s.DN(u, v, 0, 1))
    angle = math.degrees(n.Angle(gp_Vec(0, 0, 1)))
    assert min(angle, 180 - angle) < 1.0


def test_fill_with_an_open_boundary_says_where():
    a = BRepBuilderAPI_MakeEdge(gp_Pnt(0, 0, 0), gp_Pnt(100, 0, 0)).Edge()
    b = BRepBuilderAPI_MakeEdge(gp_Pnt(100, 0, 0), gp_Pnt(100, 100, 0)).Edge()
    c = BRepBuilderAPI_MakeEdge(gp_Pnt(100, 100, 0), gp_Pnt(0, 90, 0)).Edge()
    with pytest.raises(EngineError, match="boundary is open at"):
        ops.fill([(a, None), (b, None), (c, None)])


def _moved(shape, dz):
    from OCP.BRepBuilderAPI import BRepBuilderAPI_Transform
    from OCP.gp import gp_Trsf
    t = gp_Trsf()
    t.SetTranslation(gp_Vec(0, 0, dz))
    return BRepBuilderAPI_Transform(shape, t, True).Shape()


def test_add_fuses_a_closed_extension():
    cap = Topology(_moved(faces_of_box(100, 100, 20), 100)).faces
    out, _ = ops.add(box(), cap)
    assert volume(out) == pytest.approx(1.2e6, rel=1e-4)


def test_add_with_open_surfaces_changes_nothing():
    cap = Topology(_moved(faces_of_box(100, 100, 20, drop="top"), 100)).faces
    with pytest.raises(EngineError, match="do not close a volume"):
        ops.add(box(), cap)


def test_fillet_volume():
    s = box()
    out, _ = ops.fillet(s, [edge_at(s, (50, 0, 0))], 10)
    assert volume(out) == pytest.approx(1e6 - (1 - math.pi / 4) * 100 * 100, rel=1e-3)


def test_fillet_too_large_raises():
    s = box()
    with pytest.raises(EngineError):
        ops.fillet(s, [edge_at(s, (50, 0, 0))], 150)  # wider than the faces it joins


def test_chamfer_volume():
    s = box()
    out, _ = ops.chamfer(s, [edge_at(s, (50, 0, 0))], 10)
    assert volume(out) == pytest.approx(1e6 - 0.5 * 100 * 100, rel=1e-3)


def test_pushpull_flat_face():
    s = box()
    out, _ = ops.pushpull(s, face_at(s, (50, 50, 100)), 10)
    assert volume(out) == pytest.approx(1.1e6, rel=1e-4)
    out, _ = ops.pushpull(s, face_at(s, (50, 50, 100)), -10)
    assert volume(out) == pytest.approx(0.9e6, rel=1e-4)


def test_pushpull_curved_face_refused():
    cyl = BRepPrimAPI_MakeCylinder(20, 50).Shape()
    side = max(Topology(cyl).faces, key=area)
    with pytest.raises(EngineError, match="flat faces"):
        ops.pushpull(cyl, side, 5)
