"""The sections of a STEP front wing at given spanwise stations (y, mm), per
element: leading and trailing edge, chord, chord-line slope and lowest point.
Faces spanning under 100 mm in y (the endplates) are skipped. Flow along -x,
z up, as the user's CATIA parts are drawn.

    engine/.venv/bin/python docs/validation/frontwing1/cad_sections.py part.stp -472.45 [-215 ...]
"""
import sys

import numpy as np
from OCP.BRepAdaptor import BRepAdaptor_Curve
from OCP.BRepAlgoAPI import BRepAlgoAPI_Section
from OCP.BRepBndLib import BRepBndLib
from OCP.Bnd import Bnd_Box
from OCP.GCPnts import GCPnts_UniformAbscissa
from OCP.STEPControl import STEPControl_Reader
from OCP.TopAbs import TopAbs_EDGE, TopAbs_FACE
from OCP.TopExp import TopExp_Explorer
from OCP.TopoDS import TopoDS
from OCP.gp import gp_Dir, gp_Pln, gp_Pnt


def cuts(shape, y: float) -> list[np.ndarray]:
    """Every wing face's exact cut by the plane at y, as (x, z) points 0.1 mm apart."""
    plane, out = gp_Pln(gp_Pnt(0, y, 0), gp_Dir(0, 1, 0)), []
    faces = TopExp_Explorer(shape, TopAbs_FACE)
    while faces.More():
        f = TopoDS.Face(faces.Current())
        faces.Next()
        box = Bnd_Box()
        BRepBndLib.Add_s(f, box)
        if box.CornerMax().Y() - box.CornerMin().Y() < 100:
            continue
        sec = BRepAlgoAPI_Section(f, plane, False)
        sec.Approximation(True)
        sec.Build()
        edges = TopExp_Explorer(sec.Shape(), TopAbs_EDGE)
        while edges.More():
            c = BRepAdaptor_Curve(TopoDS.Edge(edges.Current()))
            edges.Next()
            u = GCPnts_UniformAbscissa(c, 0.1)
            ts = [u.Parameter(i) for i in range(1, u.NbPoints() + 1)] if u.IsDone() and u.NbPoints() > 1 \
                else [c.FirstParameter(), c.LastParameter()]
            out.append(np.array([[c.Value(t).X(), c.Value(t).Z()] for t in ts]))
    return out


def join(parts: list[np.ndarray], tol: float = 0.05) -> list[np.ndarray]:
    """Cuts whose ends meet (within tol mm) joined into one outline per element."""
    parts = list(parts)
    joined = True
    while joined:
        joined = False
        for i, a in enumerate(parts):
            for j, b in enumerate(parts):
                if i == j:
                    continue
                for ae, be in ((-1, 0), (-1, -1), (0, 0), (0, -1)):
                    if np.linalg.norm(a[ae] - b[be]) < tol:
                        a2, b2 = (a if ae == -1 else a[::-1]), (b if be == 0 else b[::-1])
                        parts[i] = np.vstack([a2, b2[1:]])
                        parts.pop(j)
                        joined = True
                        break
                if joined:
                    break
            if joined:
                break
    return sorted((p for p in parts if len(p) > 50), key=lambda p: -p[:, 0].max())


if __name__ == "__main__":
    reader = STEPControl_Reader()
    if reader.ReadFile(sys.argv[1]) != 1:
        raise SystemExit(f"cannot read {sys.argv[1]}")
    reader.TransferRoots()
    shape = reader.OneShape()
    for y in map(float, sys.argv[2:]):
        print(f"y = {y:g} mm")
        for k, e in enumerate(join(cuts(shape, y))):
            le, te = e[e[:, 0].argmax()], e[e[:, 0].argmin()]
            chord = float(np.linalg.norm(le - te))
            slope = np.degrees(np.arcsin((te[1] - le[1]) / chord))
            print(f"  element {k}: LE ({le[0]:.2f}, {le[1]:.2f})  TE ({te[0]:.2f}, {te[1]:.2f})  chord {chord:.1f}"
                  f"  trailing edge {slope:+.2f} deg up  lowest z {e[:, 1].min():.2f}")
