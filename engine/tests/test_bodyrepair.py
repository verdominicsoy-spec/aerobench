"""STEP repair to one closed body, on B-reps with planted gaps of known size."""

from __future__ import annotations

import pytest
from OCP.BRep import BRep_Builder
from OCP.BRepBuilderAPI import BRepBuilderAPI_Transform
from OCP.BRepGProp import BRepGProp
from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox
from OCP.GProp import GProp_GProps
from OCP.gp import gp_Trsf, gp_Vec
from OCP.TopAbs import TopAbs_FACE
from OCP.TopExp import TopExp_Explorer
from OCP.TopoDS import TopoDS_Compound

from aeroengine.cad.bodyrepair import bridge, fill, find_gaps, find_holes, free_edges, sew_stepped, to_solids

# MakeBox face order: x=0, x=dx, y=0, y=dy, z=0, z=dz.
SIDES = {"left": 0, "right": 1, "front": 2, "back": 3, "bottom": 4, "top": 5}


def faces_of_box(dx, dy, dz, move=None, drop=None) -> TopoDS_Compound:
    """A box's six faces as a loose compound; `move` = (side, gp_Vec)
    translates one face, which plants a gap of that size around it."""
    exp = TopExp_Explorer(BRepPrimAPI_MakeBox(dx, dy, dz).Shape(), TopAbs_FACE)
    faces = []
    while exp.More():
        faces.append(exp.Current())
        exp.Next()
    if move is not None:
        t = gp_Trsf()
        t.SetTranslation(move[1])
        k = SIDES[move[0]]
        faces[k] = BRepBuilderAPI_Transform(faces[k], t, True).Shape()
    if drop is not None:
        faces.pop(SIDES[drop])
    comp = TopoDS_Compound()
    b = BRep_Builder()
    b.MakeCompound(comp)
    for f in faces:
        b.Add(comp, f)
    return comp


def volume(shape) -> float:
    props = GProp_GProps()
    BRepGProp.VolumeProperties_s(shape, props)
    return abs(props.Mass())


def test_closed_solid_is_not_sewn():
    box = BRepPrimAPI_MakeBox(10, 10, 10).Shape()
    out, tol = sew_stepped(box, 0.5)
    assert tol is None and out.IsSame(box)


def test_tiny_gap_sews_at_the_smallest_step():
    shape = faces_of_box(100, 100, 100, move=("top", gp_Vec(0, 0, 0.015)))
    out, tol = sew_stepped(shape, 0.5)
    assert tol == 0.02 and not free_edges(out)
    solids, open_ = to_solids(out)
    assert len(solids) == 1 and not open_
    assert volume(solids[0]) == pytest.approx(1e6, rel=1e-3)


def test_thin_plate_survives():
    shape = faces_of_box(100, 100, 0.3, move=("top", gp_Vec(0, 0, 0.05)))
    out, tol = sew_stepped(shape, 0.5)
    assert tol <= 0.1
    solids, _ = to_solids(out)
    assert len(solids) == 1 and volume(solids[0]) > 100 * 100 * 0.29  # not collapsed


def test_gap_over_the_limit_stays_open():
    out, tol = sew_stepped(faces_of_box(100, 100, 100, move=("top", gp_Vec(0, 0, 5))), 0.5)
    assert tol == 0.5 and free_edges(out)
    solids, open_ = to_solids(out)
    assert solids == [] and len(open_) == 1


def test_a_5mm_gap_is_found_and_bridged():
    shape, _ = sew_stepped(faces_of_box(100, 100, 100, move=("top", gp_Vec(0, 0, 5))), 0.5)
    gaps = find_gaps(shape)
    assert len(gaps) == 4 and all(g.size_mm == pytest.approx(5, abs=0.01) for g in gaps)
    centres = [g.centre_mm for g in gaps]
    for c in centres:  # bridging changes edges, so find each gap again by its centre
        g = next(g for g in find_gaps(shape) if max(abs(a - b) for a, b in zip(g.centre_mm, c)) < 0.01)
        shape = bridge(shape, g)
    assert not free_edges(shape)
    solids, _ = to_solids(shape)
    assert volume(solids[0]) == pytest.approx(100 * 100 * 105, rel=1e-3)


def test_a_missing_face_is_a_hole_and_is_filled():
    shape, _ = sew_stepped(faces_of_box(100, 100, 100, drop="top"), 0.5)
    holes = find_holes(shape, find_gaps(shape))
    assert len(holes) == 1
    filled = fill(shape, holes[0])
    assert filled is not None and not free_edges(filled)
