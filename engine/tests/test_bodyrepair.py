"""STEP repair to one closed body, on B-reps with planted gaps of known size."""

from __future__ import annotations

import json

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

from aeroengine.cad import bodyrepair
from stepfixtures import write_parts
from aeroengine.cad.bodyrepair import (bridge, fill, find_gaps, find_holes, free_edges, item_id, match_decision, sew_stepped,
                                       to_solids)

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
    assert tol == 0.01 and free_edges(out)  # nothing closes past the first step, so no wider sewing
    solids, open_ = to_solids(out)
    assert solids == [] and len(open_) == 2  # the five sewn faces, and the loose top on its own


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


SAVED = [{"kind": "gap", "part": "Floor", "centre_mm": [100, 0, 5], "size_mm": 2.0, "decision": "skip"}]


def test_a_decision_matches_within_3mm():
    assert match_decision("gap", "Floor", (101.5, 1.0, 5.0), SAVED) == "skip"


def test_a_moved_or_renamed_part_does_not_match():
    assert match_decision("gap", "Floor", (104.0, 0, 5), SAVED) is None
    assert match_decision("gap", "Diffuser", (100, 0, 5), SAVED) is None
    assert match_decision("hole", "Floor", (100, 0, 5), SAVED) is None


def test_item_ids_are_stable():
    assert item_id("gap", "Floor", (1.04, 2, 3)) == item_id("gap", "Floor", (1.01, 2, 3)) == "gap:Floor:1.0,2.0,3.0"


# The whole pipeline, on STEP files ------------------------------------------


def read_back(path):
    from OCP.STEPControl import STEPControl_Reader

    r = STEPControl_Reader()
    r.ReadFile(str(path))
    r.TransferRoots()
    return r.OneShape()


def box_at(x, dx=100.0):
    t = gp_Trsf()
    t.SetTranslation(gp_Vec(x, 0, 0))
    return BRepBuilderAPI_Transform(BRepPrimAPI_MakeBox(dx, 100, 100).Shape(), t, True).Shape()


def gapped(mm):
    return faces_of_box(100, 100, 100, move=("top", gp_Vec(0, 0, mm)))


def test_overlapping_boxes_fuse_into_one_closed_body(tmp_path):
    step = write_parts(tmp_path / "o.stp", {"A": box_at(0), "B": box_at(95)})
    r = bodyrepair.repair_body(step, tmp_path / "out.step")
    assert r["items"] == [] and r["result"]["solids"] == 1 and r["result"]["closed"]
    assert volume(read_back(tmp_path / "out.step")) == pytest.approx(100 * 100 * 195, rel=1e-3)


def test_parts_10mm_apart_stay_separate(tmp_path):
    step = write_parts(tmp_path / "s.stp", {"Main Plane": box_at(0), "Flap": box_at(110)})
    r = bodyrepair.repair_body(step, tmp_path / "out.step")
    assert r["items"] == [] and r["result"]["solids"] == 2 and r["result"]["closed"]


def test_plan_then_apply(tmp_path):
    step = write_parts(tmp_path / "g.stp", {"Box": gapped(5)})
    out = tmp_path / "out.step"
    plan = bodyrepair.repair_body(step, out)
    assert {i["kind"] for i in plan["items"]} == {"gap"} and not plan["result"]["closed"]
    assert all(i["decision"] is None for i in plan["items"]) and plan["result"]["open_shells"] == 2
    assert out.exists()
    done = bodyrepair.repair_body(step, out, accept={i["id"] for i in plan["items"]})
    assert done["result"]["closed"] and done["result"]["solids"] == 1


def test_saved_decisions_apply_on_a_new_run(tmp_path):
    step = write_parts(tmp_path / "g.stp", {"Box": gapped(5)})
    plan = bodyrepair.repair_body(step, tmp_path / "out.step")
    saved = tmp_path / "g.repair.json"
    saved.write_text(json.dumps({"version": 1, "decisions": [
        {"kind": i["kind"], "part": i["part"], "centre_mm": i["centre_mm"], "size_mm": i["size_mm"], "decision": "accept"}
        for i in plan["items"]]}))
    r = bodyrepair.repair_body(step, tmp_path / "out.step", decisions=saved)
    assert r["result"]["closed"] and all(i["decision"] == "accept" for i in r["items"])


def test_wide_gap_is_reported_and_left_open(tmp_path):
    step = write_parts(tmp_path / "w.stp", {"Box": gapped(12)})
    out = tmp_path / "out.step"
    r = bodyrepair.repair_body(step, out)
    assert {i["kind"] for i in r["items"]} == {"wide_gap"} and r["result"]["open_parts"] == ["Box"]
    assert not r["result"]["closed"] and out.exists()


def test_clean_file_needs_nothing(tmp_path):
    step = write_parts(tmp_path / "c.stp", {"Box": box_at(0)})
    r = bodyrepair.repair_body(step, tmp_path / "out.step")
    assert r["items"] == [] and r["result"]["closed"] and r["auto"]["parts_sewn"] == 0


def test_a_part_placed_twice_has_one_item_per_gap(tmp_path):
    step = write_parts(tmp_path / "p.stp", {"Box": gapped(5)}, {"Box": [gp_Vec(0, 0, 0), gp_Vec(500, 0, 0)]})
    r = bodyrepair.repair_body(step, tmp_path / "out.step")
    assert len([i for i in r["items"] if i["kind"] == "gap"]) == 4
    assert all(len(i["lines"]) == 4 for i in r["items"])  # two edges x two placements


def test_fuse_failure_still_writes(tmp_path, monkeypatch):
    step = write_parts(tmp_path / "o.stp", {"A": box_at(0), "B": box_at(95)})
    monkeypatch.setattr(bodyrepair, "_fuse", lambda solids: None)
    out = tmp_path / "out.step"
    r = bodyrepair.repair_body(step, out)
    assert r["result"]["fused"] is False and not r["result"]["closed"] and out.exists()


def test_sample_car_through_the_engine(engine, car_files, tmp_path):
    code, events, err = engine.run("cad-repair-body", {"params": {"path": str(car_files[0])}}, tmp_path / "w", timeout=180)
    assert code == 0, (events, err)
    r = json.loads((tmp_path / "w" / "result.json").read_text())["data"]
    assert r["result"]["closed"] and r["result"]["solids"] < 8  # wing elements overlap and fuse; wheels stay apart
    assert (tmp_path / "w" / r["output"]).exists()


# Final review fixes ------------------------------------------------------------


def test_a_closed_cone_needs_nothing(tmp_path):
    from OCP.BRepPrimAPI import BRepPrimAPI_MakeCone, BRepPrimAPI_MakeSphere

    cone = BRepPrimAPI_MakeCone(50, 0, 100).Shape()
    assert not free_edges(cone)  # the apex is a degenerated edge, not an open one
    assert not free_edges(BRepPrimAPI_MakeSphere(50).Shape())
    r = bodyrepair.repair_body(write_parts(tmp_path / "c.stp", {"Nose": cone}), tmp_path / "out.step")
    assert r["items"] == [] and r["result"]["closed"] and r["auto"]["parts_sewn"] == 0


def faces_in(shape) -> int:
    exp, n = TopExp_Explorer(shape, TopAbs_FACE), 0
    while exp.More():
        n += 1
        exp.Next()
    return n


def test_loose_faces_are_kept_as_open_shells(tmp_path):
    for mm in (5, 12):
        out = tmp_path / f"out{mm}.step"
        r = bodyrepair.repair_body(write_parts(tmp_path / f"g{mm}.stp", {"Box": gapped(mm)}), out)
        assert faces_in(read_back(out)) == 6, mm
        assert r["result"]["open_parts"] == ["Box"]


def test_a_failed_bridge_is_reported_not_raised(tmp_path, monkeypatch):
    step = write_parts(tmp_path / "g.stp", {"Box": gapped(5)})
    plan = bodyrepair.repair_body(step, tmp_path / "out.step")
    monkeypatch.setattr(bodyrepair, "bridge", lambda shape, gap: None)
    r = bodyrepair.repair_body(step, tmp_path / "out.step", accept={i["id"] for i in plan["items"]})
    assert all(i["fix"] == "failed" for i in r["items"] if i["kind"] == "gap")
    assert not r["result"]["closed"] and (tmp_path / "out.step").exists()


def test_a_saved_decision_needs_a_similar_size():
    saved = [{"kind": "gap", "part": "Floor", "centre_mm": [100, 0, 5], "size_mm": 2.0, "decision": "accept"}]
    assert match_decision("gap", "Floor", (100, 0, 5), saved, size_mm=2.3) == "accept"
    assert match_decision("gap", "Floor", (100, 0, 5), saved, size_mm=9.0) is None
