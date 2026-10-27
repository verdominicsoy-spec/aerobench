"""STEP and IGES to a mesh model through OCP (OpenCascade).

The XCAF document keeps the assembly tree and names. Each part (prototype
shape) is meshed once in its own frame; instances become nodes carrying the
instance location, so a wheel used four times is stored once.
"""

from __future__ import annotations

from pathlib import Path
from typing import Callable

import numpy as np
from OCP.BRep import BRep_Tool
from OCP.BRepBndLib import BRepBndLib
from OCP.BRepMesh import BRepMesh_IncrementalMesh
from OCP.Bnd import Bnd_Box
from OCP.IFSelect import IFSelect_RetDone
from OCP.IGESCAFControl import IGESCAFControl_Reader
from OCP.OCP.collections import Sequence_TDF_Label
from OCP.STEPCAFControl import STEPCAFControl_Reader
from OCP.TCollection import TCollection_AsciiString, TCollection_ExtendedString
from OCP.TDataStd import TDataStd_Name
from OCP.TDF import TDF_Label, TDF_Tool
from OCP.TDocStd import TDocStd_Document
from OCP.BRepBuilderAPI import BRepBuilderAPI_Sewing
from OCP.TopAbs import TopAbs_FACE, TopAbs_REVERSED, TopAbs_SHELL, TopAbs_SOLID
from OCP.TopExp import TopExp_Explorer
from OCP.TopLoc import TopLoc_Location
from OCP.TopoDS import TopoDS
from OCP.XCAFDoc import XCAFDoc_DocumentTool, XCAFDoc_ShapeTool

from ..job import EngineError
from .meshio import Mesh, Model, Node, vertex_normals

MM = 0.001  # OCP works in millimetres

# Chordal deflection as a fraction of the model's bounding-box diagonal, and
# angular deflection in radians.
PRESETS = {
    "coarse": (2e-3, 0.5),
    "medium": (5e-4, 0.25),
    "fine": (1e-4, 0.1),
}

Progress = Callable[[float, str], None]


def _matrix(loc: TopLoc_Location) -> np.ndarray:
    t = loc.Transformation()
    m = np.eye(4)
    for r in range(3):
        for c in range(4):
            m[r, c] = t.Value(r + 1, c + 1)
    m[:3, 3] *= MM
    return m


def _entry(label: TDF_Label) -> str:
    s = TCollection_AsciiString()
    TDF_Tool.Entry_s(label, s)
    return s.ToCString()


def _name(label: TDF_Label) -> str:
    attr = TDataStd_Name()
    if label.FindAttribute(TDataStd_Name.GetID_s(), attr):
        name = attr.Get().ToExtString().strip()
        # Bare numbers are STEP occurrence ids, not names a person gave.
        return "" if name.isdigit() else name
    return ""


def _sub(shape, kind) -> list:
    out = []
    exp = TopExp_Explorer(shape, kind)
    while exp.More():
        out.append(exp.Current())
        exp.Next()
    return out


def _bodies(shape, tolerance: float) -> list:
    """Splits a part into separately hideable bodies: its solids if it has
    several, otherwise the shells you get by sewing loose faces (IGES)."""
    solids = _sub(shape, TopAbs_SOLID)
    if len(solids) > 1:
        return solids
    if solids or len(_sub(shape, TopAbs_FACE)) < 2:
        return [shape]
    sewing = BRepBuilderAPI_Sewing(tolerance)
    sewing.Add(shape)
    sewing.Perform()
    shells = _sub(sewing.SewedShape(), TopAbs_SHELL)
    return shells if len(shells) > 1 else [shape]


def _read(path: Path) -> TDocStd_Document:
    doc = TDocStd_Document(TCollection_ExtendedString("XmlOcaf"))
    suffix = path.suffix.lower()
    if suffix in (".step", ".stp"):
        reader = STEPCAFControl_Reader()
    elif suffix in (".iges", ".igs"):
        reader = IGESCAFControl_Reader()
    else:
        raise EngineError(f"not a STEP or IGES file: {path.name}")
    reader.SetNameMode(True)
    if reader.ReadFile(str(path)) != IFSelect_RetDone:
        raise EngineError(f"could not read {path.name}", "the file is missing, unreadable or not valid STEP/IGES")
    if not reader.Transfer(doc):
        raise EngineError(f"could not translate {path.name} into shapes")
    return doc


def _mesh_shape(shape, lin: float, ang: float) -> Mesh | None:
    BRepMesh_IncrementalMesh(shape, lin, False, ang, True)
    positions, indices = [], []
    base = 0
    exp = TopExp_Explorer(shape, TopAbs_FACE)
    while exp.More():
        face = TopoDS.Face(exp.Current())
        loc = TopLoc_Location()
        tri = BRep_Tool.Triangulation_s(face, loc)
        exp.Next()
        if tri is None:
            continue
        trsf = loc.Transformation()
        n = tri.NbNodes()
        pts = np.empty((n, 3))
        for i in range(n):
            p = tri.Node(i + 1).Transformed(trsf)
            pts[i] = (p.X(), p.Y(), p.Z())
        t = np.empty((tri.NbTriangles(), 3), np.int64)
        for i in range(tri.NbTriangles()):
            t[i] = tri.Triangle(i + 1).Get()
        t -= 1
        if face.Orientation() == TopAbs_REVERSED:
            t = t[:, ::-1]
        positions.append(pts)
        indices.append(t + base)
        base += n
    if not positions:
        return None
    pos = np.concatenate(positions) * MM
    idx = np.concatenate(indices).astype(np.uint32)
    # Normals per B-rep face are smooth; faces do not share nodes, so edges stay sharp.
    return Mesh(pos.astype(np.float32), vertex_normals(pos, idx), idx)


def tessellate_file(path: Path, preset: str = "medium", progress: Progress | None = None) -> Model:
    if preset not in PRESETS:
        raise EngineError(f"unknown preset '{preset}'", f"expected one of {', '.join(PRESETS)}")
    report = progress or (lambda pct, msg: None)
    report(5, f"reading {path.name}")
    doc = _read(path)
    tool = XCAFDoc_DocumentTool.ShapeTool_s(doc.Main())
    free = Sequence_TDF_Label()
    tool.GetFreeShapes(free)
    if free.Length() == 0:
        raise EngineError(f"{path.name} contains no shapes")

    box = Bnd_Box()
    for i in range(1, free.Length() + 1):
        BRepBndLib.Add_s(XCAFDoc_ShapeTool.GetShape_s(free.Value(i)), box)
    lo, hi = box.CornerMin(), box.CornerMax()
    diag = float(np.linalg.norm([hi.X() - lo.X(), hi.Y() - lo.Y(), hi.Z() - lo.Z()]))
    rel, ang = PRESETS[preset]
    lin = max(rel * diag, 1e-3)  # mm
    sew_tol = max(1e-5 * diag, 1e-3)  # mm

    # Count parts first so meshing can report progress.
    parts: dict[str, TDF_Label] = {}

    def collect(label: TDF_Label) -> None:
        if XCAFDoc_ShapeTool.IsAssembly_s(label):
            comps = Sequence_TDF_Label()
            XCAFDoc_ShapeTool.GetComponents_s(label, comps)
            for i in range(1, comps.Length() + 1):
                ref = TDF_Label()
                XCAFDoc_ShapeTool.GetReferredShape_s(comps.Value(i), ref)
                collect(ref)
        else:
            parts.setdefault(_entry(label), label)

    for i in range(1, free.Length() + 1):
        collect(free.Value(i))

    # A part that is several solids (typical of IGES, which has no assembly
    # structure) is split into one mesh per solid so each can be hidden.
    meshes: list[Mesh] = []
    mesh_of: dict[str, list[int]] = {}
    for k, (key, label) in enumerate(parts.items()):
        shape = XCAFDoc_ShapeTool.GetShape_s(label).Located(TopLoc_Location())
        pieces = _bodies(shape, sew_tol)
        mesh_of[key] = []
        for piece in pieces:
            mesh = _mesh_shape(piece, lin, ang)
            if mesh is not None:
                mesh.name = _name(label)
                meshes.append(mesh)
                mesh_of[key].append(len(meshes) - 1)
        report(10 + 80 * (k + 1) / len(parts), f"meshed {_name(label) or 'part'} ({k + 1}/{len(parts)})")

    def node_for(label: TDF_Label, name: str, loc: TopLoc_Location) -> Node:
        shape_loc = XCAFDoc_ShapeTool.GetShape_s(label).Location()
        node = Node(name or _name(label) or "Unnamed", _matrix(loc) @ _matrix(shape_loc))
        if XCAFDoc_ShapeTool.IsAssembly_s(label):
            comps = Sequence_TDF_Label()
            XCAFDoc_ShapeTool.GetComponents_s(label, comps)
            for i in range(1, comps.Length() + 1):
                comp = comps.Value(i)
                ref = TDF_Label()
                XCAFDoc_ShapeTool.GetReferredShape_s(comp, ref)
                node.children.append(node_for(ref, _name(comp), XCAFDoc_ShapeTool.GetLocation_s(comp)))
        else:
            ids = mesh_of[_entry(label)]
            if len(ids) == 1:
                node.mesh = ids[0]
            else:
                node.children = [Node(f"Body {i + 1}", mesh=m) for i, m in enumerate(ids)]
        return node

    roots = [node_for(free.Value(i), _name(free.Value(i)), TopLoc_Location()) for i in range(1, free.Length() + 1)]
    return Model(meshes, roots)
