"""The car cut by a plane across it (y = c): closed outlines in (x, z) mm.

The cut's edges are joined into wires; closed wires become outlines, open
ones are reported where they end (a gap in the CAD) so the user can see
them, and the closed outlines still go on to be meshed. An outline whose
centre lies inside a wheel at that y is that wheel, so it can rotate.
"""

from __future__ import annotations

from OCP.BRepAdaptor import BRepAdaptor_CompCurve
from OCP.BRepAlgoAPI import BRepAlgoAPI_Section
from OCP.GCPnts import GCPnts_QuasiUniformDeflection
from OCP.gp import gp_Dir, gp_Pln, gp_Pnt
from OCP.OCP.collections import HSequence_TopoDS_Shape
from OCP.ShapeAnalysis import ShapeAnalysis_FreeBounds
from OCP.TopAbs import TopAbs_EDGE
from OCP.TopoDS import TopoDS

from ..cad.bodyrepair import _subshapes

JOIN_MM = 0.05
DEFLECTION_MM = 0.5


def _area(points) -> float:
    return abs(sum(x0 * z1 - x1 * z0 for (x0, z0), (x1, z1) in zip(points, points[1:] + points[:1]))) / 2


def _wheel_at(points, y: float, setup: dict) -> str | None:
    cx = sum(p[0] for p in points) / len(points)
    cz = sum(p[1] for p in points) / len(points)
    for w in setup.get("wheels", []):
        (wx, wy, wz), r = w["centre"], w["radius"]
        if abs(y - wy) <= w["width"] / 2 and ((cx - wx) ** 2 + (cz - wz) ** 2) ** 0.5 <= r:
            return w["name"]
    return None


def cut(shape, y_mm: float, setup: dict, min_area_mm2: float = 25.0) -> dict:
    op = BRepAlgoAPI_Section(shape, gp_Pln(gp_Pnt(0, y_mm, 0), gp_Dir(0, 1, 0)), False)
    op.ComputePCurveOn1(False)
    op.Approximation(True)
    op.Build()
    edges = HSequence_TopoDS_Shape()
    for e in _subshapes(op.Shape(), TopAbs_EDGE):
        edges.Append(e)
    out = {"y": float(y_mm), "loops": [], "open": []}
    if edges.Length() == 0:
        return out
    wires = HSequence_TopoDS_Shape()
    ShapeAnalysis_FreeBounds.ConnectEdgesToWires_s(edges, JOIN_MM, False, wires)
    for i in range(1, wires.Length() + 1):
        wire = TopoDS.Wire(wires.Value(i))
        curve = BRepAdaptor_CompCurve(wire)
        sampler = GCPnts_QuasiUniformDeflection(curve, DEFLECTION_MM)
        if not sampler.IsDone() or sampler.NbPoints() < 3:
            continue
        pts = [sampler.Value(k) for k in range(1, sampler.NbPoints() + 1)]
        closed = pts[0].Distance(pts[-1]) <= JOIN_MM * 10
        xz = [[round(p.X(), 4), round(p.Z(), 4)] for p in pts]
        if not closed:
            out["open"] += [xz[0], xz[-1]]
            continue
        xz = xz[:-1]  # the last point repeats the first
        if _area(xz) < min_area_mm2:
            continue
        name = _wheel_at(xz, y_mm, setup)
        out["loops"].append({"kind": "wheel", "wheel": name, "points": xz} if name else {"kind": "body", "points": xz})
    return out
