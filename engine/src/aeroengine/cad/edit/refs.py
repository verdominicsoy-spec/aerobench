"""Loading the part, numbering its faces and edges, and following them
through the operations that change it.

The imported part never changes, so its faces and edges are referenced by
their place in a fixed order. After a fillet or a fuse a face may be
trimmed or split; references follow it through OpenCascade's history. A
reference that ends up as nothing, or as several pieces, is lost: the user
picks again, nothing is guessed.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

from OCP.OCP.collections import IndexedMap_TopoDS_Shape_TopTools_ShapeMapHasher as ShapeMap
from OCP.TopAbs import TopAbs_EDGE, TopAbs_FACE
from OCP.TopExp import TopExp
from OCP.TopoDS import TopoDS
from OCP.XCAFDoc import XCAFDoc_ShapeTool

from ...job import EngineError
from ..brepcheck import _parts
from ..tessellate import _read

_parts_cache: dict = {}


class RefLost(Exception):
    def __init__(self, ref: dict):
        super().__init__(f"reference lost: {ref}")
        self.ref = ref


class PickPart(EngineError):
    def __init__(self, names: list[str]):
        super().__init__("pick a part", ", ".join(names))
        self.names = names


def fingerprint(path: Path) -> str:
    """Size and content only: copying or touching the file keeps it."""
    return f"{path.stat().st_size}:{hashlib.sha256(path.read_bytes()).hexdigest()[:16]}"


def load_part(path: Path, part: str | None):
    """(shape in the part's own frame, every part name, fingerprint)."""
    st = path.stat()
    key = (str(path), st.st_size, st.st_mtime_ns)
    if key not in _parts_cache:
        doc = _read(path)
        parts = [(name, XCAFDoc_ShapeTool.GetShape_s(label)) for label, name in _parts(doc)]
        _parts_cache.clear()  # one file at a time: the one being edited
        _parts_cache[key] = (parts, fingerprint(path))
    parts, fp = _parts_cache[key]
    names = [n for n, _ in parts]
    if part is None:
        if len(parts) != 1:
            raise PickPart(names)
        return parts[0][1], names, fp
    for n, shape in parts:
        if n == part:
            return shape, names, fp
    raise EngineError(f"no part named '{part}'", ", ".join(names))


def _ordered(shape, kind):
    m = ShapeMap()
    TopExp.MapShapes_s(shape, kind, m)
    cast = TopoDS.Face if kind == TopAbs_FACE else TopoDS.Edge
    return m, [cast(m.FindKey(i)) for i in range(1, m.Extent() + 1)]


class Topology:
    """A shape's faces and edges in a fixed order, looked up by hash."""

    def __init__(self, shape):
        self.shape = shape
        self._faces, self.faces = _ordered(shape, TopAbs_FACE)
        self._edges, self.edges = _ordered(shape, TopAbs_EDGE)

    def of(self, kind: str) -> list:
        return self.faces if kind == "face" else self.edges

    def index(self, sub) -> int | None:
        for m in (self._faces, self._edges):
            i = m.FindIndex(sub)
            if i:
                return i - 1
        return None


class History:
    """Where a sub-shape of a base shape went through later operations."""

    def __init__(self, base):
        self.current = base
        self.steps: list = []  # (maker, shape before)

    def copy(self) -> "History":
        h = History(self.current)
        h.steps = list(self.steps)
        return h

    def apply(self, maker, before) -> None:
        self.current = maker.Shape()
        self.steps.append((maker, Topology(self.current)))

    def forward(self, sub, start: int = 0) -> list:
        # IsDeleted is unreliable here (a fillet reports untouched edges as
        # deleted), so a piece is gone when it was not modified and is not
        # in that step's result.
        pieces = [sub]
        for maker, result in self.steps[start:]:
            nxt = []
            for p in pieces:
                if result.index(p) is not None:  # untouched: skip the slow Modified() call
                    nxt.append(p)
                else:
                    nxt += list(maker.Modified(p))
            pieces = nxt
        return pieces


def resolve(ref: dict, ctx) -> object:
    """The one shape a reference points at now, or RefLost."""
    found = ctx.lookup(ref)
    if len(found) != 1:
        raise RefLost(ref)
    return found[0]
