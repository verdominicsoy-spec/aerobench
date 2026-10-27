"""Synthetic sample geometry with exactly known dimensions."""

from __future__ import annotations

import math
import struct
from pathlib import Path

import numpy as np
from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeEdge, BRepBuilderAPI_MakeFace, BRepBuilderAPI_MakeWire
from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox, BRepPrimAPI_MakeCylinder, BRepPrimAPI_MakePrism
from OCP.GeomAPI import GeomAPI_PointsToBSpline
from OCP.gp import gp_Ax2, gp_Dir, gp_Pnt, gp_Trsf, gp_Vec
from OCP.IFSelect import IFSelect_RetDone
from OCP.IGESCAFControl import IGESCAFControl_Writer
from OCP.STEPCAFControl import STEPCAFControl_Writer
from OCP.STEPControl import STEPControl_AsIs
from OCP.TCollection import TCollection_ExtendedString
from OCP.OCP.collections import Array1_gp_Pnt
from OCP.TDataStd import TDataStd_Name
from OCP.TDocStd import TDocStd_Document
from OCP.TopLoc import TopLoc_Location
from OCP.XCAFDoc import XCAFDoc_DocumentTool

CHASSIS = (1500.0, 600.0, 300.0)  # mm
WHEEL_DIAMETER = 457.2
WHEEL_WIDTH = 200.0
WHEELBASE = 1530.0
FRONT_AXLE_X = -15.0


def naca4(code: str, chord: float, n: int = 60) -> np.ndarray:
    """Closed NACA 4-digit profile in the x-z plane, mm, trailing edge first."""
    m, p, t = int(code[0]) / 100, int(code[1]) / 10, int(code[2:]) / 100
    beta = np.linspace(0, math.pi, n)
    x = (1 - np.cos(beta)) / 2
    yt = 5 * t * (0.2969 * np.sqrt(x) - 0.1260 * x - 0.3516 * x**2 + 0.2843 * x**3 - 0.1015 * x**4)  # original definition, blunt trailing edge
    yc = np.where(x < p, m / p**2 * (2 * p * x - x**2), m / (1 - p) ** 2 * ((1 - 2 * p) + 2 * p * x - x**2)) if p else 0 * x
    upper = np.column_stack([x, yc + yt])[::-1]
    lower = np.column_stack([x, yc - yt])[1:]
    pts = np.vstack([upper, lower]) * chord
    return pts


def _airfoil_solid(code: str, chord: float, span: float):
    pts = naca4(code, chord)
    arr = Array1_gp_Pnt(1, len(pts))
    for i, (x, z) in enumerate(pts, start=1):
        arr.SetValue(i, gp_Pnt(float(x), 0.0, float(z)))
    curve = GeomAPI_PointsToBSpline(arr).Curve()
    edge = BRepBuilderAPI_MakeEdge(curve).Edge()
    # Close the blunt trailing edge between the spline's own end points.
    te = BRepBuilderAPI_MakeEdge(curve.EndPoint(), curve.StartPoint()).Edge()
    wire = BRepBuilderAPI_MakeWire(edge, te).Wire()
    face = BRepBuilderAPI_MakeFace(wire).Face()
    return BRepPrimAPI_MakePrism(face, gp_Vec(0, span, 0)).Shape()


def _loc(dx=0.0, dy=0.0, dz=0.0, rot_y_deg=0.0) -> TopLoc_Location:
    t = gp_Trsf()
    if rot_y_deg:
        r = gp_Trsf()
        from OCP.gp import gp_Ax1

        r.SetRotation(gp_Ax1(gp_Pnt(0, 0, 0), gp_Dir(0, 1, 0)), math.radians(rot_y_deg))
        t = r
    move = gp_Trsf()
    move.SetTranslation(gp_Vec(dx, dy, dz))
    return TopLoc_Location(move.Multiplied(t))


def _name(label, text: str) -> None:
    TDataStd_Name.Set_s(label, TCollection_ExtendedString(text))


def build_sample_doc() -> TDocStd_Document:
    doc = TDocStd_Document(TCollection_ExtendedString("XmlOcaf"))
    tool = XCAFDoc_DocumentTool.ShapeTool_s(doc.Main())

    chassis = tool.AddShape(BRepPrimAPI_MakeBox(*CHASSIS).Shape(), False)
    _name(chassis, "Chassis")
    r = WHEEL_DIAMETER / 2
    wheel_shape = BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(0, 1, 0)), r, WHEEL_WIDTH).Shape()
    wheel = tool.AddShape(wheel_shape, False)
    _name(wheel, "Wheel")
    main_plane = tool.AddShape(_airfoil_solid("4412", 300.0, 1200.0), False)
    _name(main_plane, "Main Plane")
    flap = tool.AddShape(_airfoil_solid("4412", 150.0, 1200.0), False)
    _name(flap, "Flap 1")

    def wing(name: str):
        assy = tool.NewShape()
        _name(assy, name)
        c = tool.AddComponent(assy, main_plane, TopLoc_Location())
        _name(c, "Main Plane")
        c = tool.AddComponent(assy, flap, _loc(280.0, 0.0, 30.0, rot_y_deg=-20.0))
        _name(c, "Flap 1")
        return assy

    front_wing = wing("Front Wing")
    rear_wing = wing("Rear Wing")

    car = tool.NewShape()
    _name(car, "Sample Car")
    c = tool.AddComponent(car, chassis, TopLoc_Location())
    _name(c, "Chassis")
    y_left, y_right = -WHEEL_WIDTH - 20.0, CHASSIS[1] + 20.0
    rear_x = FRONT_AXLE_X + WHEELBASE
    for label, x, y in [("Wheel FL", FRONT_AXLE_X, y_left), ("Wheel FR", FRONT_AXLE_X, y_right),
                        ("Wheel RL", rear_x, y_left), ("Wheel RR", rear_x, y_right)]:
        c = tool.AddComponent(car, wheel, _loc(x, y, r - 100.0))
        _name(c, label)
    c = tool.AddComponent(car, front_wing, _loc(-500.0, -300.0, -50.0))
    _name(c, "Front Wing")
    c = tool.AddComponent(car, rear_wing, _loc(1600.0, -300.0, 700.0))
    _name(c, "Rear Wing")
    tool.UpdateAssemblies()
    return doc


def build_sample_car(step_path: Path, iges_path: Path | None = None) -> None:
    doc = build_sample_doc()
    writer = STEPCAFControl_Writer()
    writer.SetNameMode(True)
    writer.Transfer(doc, STEPControl_AsIs)
    if writer.Write(str(step_path)) != IFSelect_RetDone:
        raise RuntimeError(f"could not write {step_path}")
    if iges_path is not None:
        # OCP writes IGES as loose trimmed faces, like most CATIA surface exports.
        iw = IGESCAFControl_Writer()
        iw.SetNameMode(True)
        iw.Transfer(doc)
        if not iw.Write(str(iges_path)):
            raise RuntimeError(f"could not write {iges_path}")


def write_dense_stl(path: Path, triangles: int) -> int:
    """A finely tessellated torus-knot-ish surface for frame-rate testing, mm."""
    nu = int(math.sqrt(triangles / 2 * 4))
    nv = max(triangles // (2 * nu), 3)
    u = np.linspace(0, 2 * math.pi, nu, endpoint=False)
    v = np.linspace(0, 2 * math.pi, nv, endpoint=False)
    U, V = np.meshgrid(u, v, indexing="ij")
    R, rr = 800.0, 120.0 * (1 + 0.3 * np.sin(5 * U))
    x = (R + rr * np.cos(V)) * np.cos(U)
    y = (R + rr * np.cos(V)) * np.sin(U)
    z = rr * np.sin(V) + 150 * np.sin(3 * U)
    P = np.stack([x, y, z], -1)
    a = P
    b = np.roll(P, -1, 0)
    c = np.roll(np.roll(P, -1, 0), -1, 1)
    d = np.roll(P, -1, 1)
    tris = np.concatenate([np.stack([a, b, c], -2).reshape(-1, 3, 3), np.stack([a, c, d], -2).reshape(-1, 3, 3)])
    n = np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0])
    n /= np.linalg.norm(n, axis=1, keepdims=True) + 1e-30
    rec = np.zeros(len(tris), dtype=[("n", "<f4", 3), ("v", "<f4", (3, 3)), ("a", "<u2")])
    rec["n"], rec["v"] = n, tris
    with open(path, "wb") as f:
        f.write(b"AeroBench dense test surface".ljust(80, b" "))
        f.write(struct.pack("<I", len(tris)))
        f.write(rec.tobytes())
    return len(tris)
