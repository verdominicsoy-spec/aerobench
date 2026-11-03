"""Rebuilding the edited part from its feature list.

The features run in order on top of the imported part. Points, splines,
planes and surfaces are side geometry kept per feature; add, fillet,
chamfer and push/pull change the solid and are recorded in its history.
The state after each feature is cached, so an edit to feature N reuses
the work for features before it.
"""

from __future__ import annotations

import json
import uuid
from collections import OrderedDict
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from OCP.Bnd import Bnd_Box
from OCP.BRepAdaptor import BRepAdaptor_Curve
from OCP.BRepBndLib import BRepBndLib
from OCP.BRepCheck import BRepCheck_Analyzer
from OCP.gp import gp_Pnt
from OCP.OCP.collections import IndexedMap_TopoDS_Shape_TopTools_ShapeMapHasher as ShapeMap
from OCP.TopAbs import TopAbs_SOLID

from ...job import EngineError
from .. import meshio
from ..bodyrepair import _compound, _subshapes, free_edges
from ..tessellate import MM, PRESETS, _mesh_shape
from . import ops
from .refs import History, PickPart, RefLost, Topology, load_part, resolve

CHANGES_SOLID = {"add", "fillet", "chamfer", "pushpull"}
CACHE_SIZE = 64
EDGE_SAMPLES = 24
_cache: OrderedDict = OrderedDict()


@dataclass
class State:
    solid: object
    hist: History  # the solid's history since import
    side: dict = field(default_factory=dict)  # feature id: {"point" | "curve" | "plane" | "surface": geometry}
    made: dict = field(default_factory=dict)  # feature id: ({"face": [...], "edge": [...]}, history step it was made at)
    used: set = field(default_factory=set)  # surface features consumed by an add

    def copy(self) -> "State":
        return State(self.solid, self.hist.copy(), dict(self.side), dict(self.made), set(self.used))


class _Context:
    def __init__(self, part_topo: Topology, state: State, part_ok: bool):
        self.part, self.state, self.part_ok = part_topo, state, part_ok

    def lookup(self, ref: dict) -> list:
        src, kind, i = ref.get("src"), ref.get("kind"), ref.get("i")
        s = self.state
        if src == "std":
            return [ops.STD[ref["name"]]] if ref.get("name") in ops.STD else []
        if src == "part":
            if not self.part_ok or kind not in ("face", "edge") or not 0 <= (i or 0) < len(self.part.of(kind)):
                return []
            return s.hist.forward(self.part.of(kind)[i])
        if src in s.made:
            subs, step = s.made[src]
            if kind not in subs or not 0 <= (i or 0) < len(subs[kind]):
                return []
            return s.hist.forward(subs[kind][i], step)
        geom = s.side.get(src)
        if geom is None:
            return []
        if kind in geom:
            return [geom[kind]]
        if kind in ("face", "edge") and "surface" in geom:
            seq = Topology(geom["surface"]).of(kind)
            return [seq[i]] if 0 <= (i or 0) < len(seq) else []
        if kind == "edge" and "curve" in geom:
            return [geom["curve"]] if (i or 0) == 0 else []
        return []


def _new(before: Topology, maker, after: Topology) -> dict:
    """Faces and edges of `after` that no sub-shape of `before` became."""
    out = {}
    for kind in ("face", "edge"):
        old = ShapeMap()
        for sub in before.of(kind):
            for o in [sub] if after.index(sub) is not None else list(maker.Modified(sub)):
                old.Add(o)
        out[kind] = [x for x in after.of(kind) if not old.Contains(x)]
    return out


def _apply(feature: dict, ctx: _Context) -> None:
    kind, v, s = feature["kind"], feature.get("values", {}), ctx.state
    refs = feature.get("refs", [])
    get = lambda r: resolve(r, ctx)  # noqa: E731
    fid = feature["id"]
    if kind == "point":
        host = refs[0]
        sub = get(host)
        if "x" in v:  # a click: projected onto the host each rebuild, so it stays on it
            p = ops.point_near(sub, gp_Pnt(v["x"], v.get("y", 0.0), v.get("z", 0.0)))
        elif host["kind"] == "edge":
            p = ops.point_on_edge(sub, v.get("t", 0.5))
        else:
            p = ops.point_on_face(sub, v.get("u", 0.5), v.get("v", 0.5))
        s.side[fid] = {"point": p}
    elif kind == "spline":
        s.side[fid] = {"curve": ops.spline([get(r) for r in refs])}
    elif kind == "plane":
        ref = get(refs[0])
        base = ref if refs[0]["src"] == "std" else ops.face_plane(ref)
        s.side[fid] = {"plane": ops.plane_through(base, get(refs[1]))}
    elif kind == "extrude":
        s.side[fid] = {"surface": ops.extrude(get(refs[0]), get(refs[1]), v.get("distance", 10.0), bool(v.get("symmetric", 0)))}
    elif kind == "fill":
        s.side[fid] = {"surface": ops.fill([(get(r), get(r["tangent"]) if r.get("tangent") else None) for r in refs])}
    elif kind in CHANGES_SOLID:
        before = Topology(s.solid)
        if kind == "add":
            shape, maker = ops.add(s.solid, [get(r) for r in refs])
            s.used.update(r["src"] for r in refs)
        elif kind == "fillet":
            shape, maker = ops.fillet(s.solid, [get(r) for r in refs], v.get("radius", 1.0))
        elif kind == "chamfer":
            shape, maker = ops.chamfer(s.solid, [get(r) for r in refs], v.get("distance", 1.0))
        else:
            shape, maker = ops.pushpull(s.solid, get(refs[0]), v.get("distance", 1.0))
        s.hist.apply(maker, s.solid)
        s.solid = shape
        s.made[fid] = (_new(before, maker, Topology(shape)), len(s.hist.steps))
    else:
        raise EngineError(f"unknown feature '{kind}'")


def _key(path: Path, part, fp, features, k) -> str:
    return json.dumps([str(path), part, fp, features[: k + 1]], sort_keys=True)


def _run(path: Path, part: str | None, features: list[dict], fingerprint: str | None):
    shape, names, fp = load_part(path, part)
    part_topo = Topology(shape)
    part_ok = fingerprint is None or fingerprint == fp
    state = State(shape, History(shape))
    status = []
    start = 0
    for k in range(len(features) - 1, -1, -1):  # the longest cached prefix
        hit = _cache.get(_key(path, part, (fp, part_ok), features, k))
        if hit is not None:
            state, status = hit[0].copy(), list(hit[1])
            start = k + 1
            break
    stopped = start > 0 and status[-1]["status"] != "ok"
    for k in range(start, len(features)):
        f = features[k]
        if stopped:
            status.append({"id": f["id"], "status": "skipped"})
            continue
        try:
            _apply(f, _Context(part_topo, state, part_ok))
            status.append({"id": f["id"], "status": "ok"})
        except RefLost:
            status.append({"id": f["id"], "status": "lost", "message": "a picked edge or face is gone: pick again"})
            stopped = True
        except EngineError as e:
            status.append({"id": f["id"], "status": "failed", "message": e.msg + (f": {e.detail}" if e.detail else "")})
            stopped = True
        except Exception as e:  # noqa: BLE001 - one bad feature must not end the rebuild
            status.append({"id": f["id"], "status": "failed", "message": f"{type(e).__name__}: {e}"})
            stopped = True
        _cache[_key(path, part, (fp, part_ok), features, k)] = (state.copy(), list(status))
        _cache.move_to_end(_key(path, part, (fp, part_ok), features, k))
        while len(_cache) > CACHE_SIZE:
            _cache.popitem(last=False)
    return state, status, names, fp, shape, part_topo


def final_shape(path: Path, part: str | None, features: list[dict], fingerprint: str | None):
    """The edited solid; EngineError when a feature is not ok."""
    state, status, *_ = _run(path, part, features, fingerprint)
    for s in status:
        if s["status"] != "ok":
            raise EngineError(f"fix or remove '{s['id']}' before saving", s.get("message"))
    return state.solid


def _m(p) -> list[float]:
    return [round(p.X() * MM, 7), round(p.Y() * MM, 7), round(p.Z() * MM, 7)]


def _polyline(edge) -> list[list[float]]:
    c = BRepAdaptor_Curve(edge)
    t0, t1 = c.FirstParameter(), c.LastParameter()
    return [_m(c.Value(t0 + (t1 - t0) * k / (EDGE_SAMPLES - 1))) for k in range(EDGE_SAMPLES)]


def build(path: Path, part: str | None, features: list[dict], fingerprint: str | None, out_dir: Path,
          preset: str = "medium") -> dict:
    try:
        state, status, names, fp, imported, part_topo = _run(path, part, features, fingerprint)
    except PickPart as e:  # nothing to show until a part is chosen
        return {"parts": e.names, "part": "", "fingerprint": "", "part_valid": True, "glb": "", "faces": [], "edges": [],
                "points": [], "planes": [], "features": [], "valid": True, "closed": True}
    ok = {s["id"] for s in status if s["status"] == "ok"}

    # Where each face and edge of the result came from. Part faces are
    # labelled even when the file changed, so lost picks can be made again.
    def owners(kind):
        shapes, refs = ShapeMap(), []
        def own(sub, ref):
            if not shapes.Contains(sub):
                shapes.Add(sub)
                refs.append(ref)
        for i, sub in enumerate(part_topo.of(kind)):
            now = state.hist.forward(sub)
            if len(now) == 1:
                own(now[0], {"src": "part", "kind": kind, "i": i})
        for fid, (subs, step) in state.made.items():
            for i, sub in enumerate(subs[kind]):
                now = state.hist.forward(sub, step)
                if len(now) == 1:
                    own(now[0], {"src": fid, "kind": kind, "i": i})
        return shapes, refs

    def ref_of(sub, table):
        shapes, refs = table
        i = shapes.FindIndex(sub)
        return refs[i - 1] if i else None

    face_owners, edge_owners = owners("face"), owners("edge")
    surfaces = [(fid, g["surface"]) for fid, g in state.side.items() if "surface" in g and fid not in state.used and fid in ok]
    shown = _compound([state.solid] + [f for _, f in surfaces])
    box = Bnd_Box()
    BRepBndLib.Add_s(shown, box)
    lo, hi = box.CornerMin(), box.CornerMax()
    rel, ang = PRESETS[preset]
    lin = max(rel * float(np.linalg.norm([hi.X() - lo.X(), hi.Y() - lo.Y(), hi.Z() - lo.Z()])), 1e-3)
    ranges: list = []
    mesh = _mesh_shape(shown, lin, ang, ranges)
    out_dir.mkdir(parents=True, exist_ok=True)
    glb = out_dir / f"{uuid.uuid4().hex}.glb"
    meshio.write_glb(meshio.Model([mesh] if mesh else [], [meshio.Node("Part", mesh=0 if mesh else None)]), glb)

    faces = []
    for face, start, count in ranges:
        ref = ref_of(face, face_owners)
        if ref is None:
            fid = next((fid for fid, f in surfaces if f.IsSame(face)), None)
            ref = {"src": fid, "kind": "surface"} if fid else None
        faces.append({"ref": ref, "start": int(start), "count": int(count)})
    edges = [{"ref": ref_of(e, edge_owners), "points": _polyline(e)} for e in Topology(state.solid).edges]
    for fid, f in surfaces:
        edges += [{"ref": {"src": fid, "kind": "edge", "i": i}, "points": _polyline(e)} for i, e in enumerate(Topology(f).edges)]
    for fid, g in state.side.items():
        if "curve" in g and fid in ok:
            edges.append({"ref": {"src": fid, "kind": "curve"}, "points": _polyline(g["curve"])})
    points = [{"id": fid, "position": _m(g["point"])} for fid, g in state.side.items() if "point" in g and fid in ok]
    planes = [{"id": fid, "origin": _m(g["plane"].Location()),
               "normal": [round(c, 7) for c in (g["plane"].Axis().Direction().X(), g["plane"].Axis().Direction().Y(),
                                                g["plane"].Axis().Direction().Z())]}
              for fid, g in state.side.items() if "plane" in g and fid in ok]
    solid_ok = any(True for _ in _subshapes(imported, TopAbs_SOLID)) and BRepCheck_Analyzer(imported).IsValid()
    return {"parts": names, "part": part if part is not None else names[0], "fingerprint": fp, "part_valid": bool(solid_ok),
            "glb": str(glb), "faces": faces, "edges": edges, "points": points, "planes": planes, "features": status,
            "valid": bool(BRepCheck_Analyzer(state.solid).IsValid()), "closed": not free_edges(state.solid)}
