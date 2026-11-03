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
