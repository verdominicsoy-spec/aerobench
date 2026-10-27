"""Mesh model shared by the CAD commands, and its file formats.

A model is a tree of named nodes with 4x4 transforms; leaf nodes point at a
mesh. Meshes are stored once and shared between instances (four wheels, one
wheel mesh). Coordinates are metres, in the CAD frame (z up).

.glb is glTF 2.0 binary: positions and normals as float32, indices as uint32,
node transforms as column-major matrices. AeroBench keeps the CAD frame
rather than rotating to glTF's y-up convention (see docs/DECISIONS.md).
"""

from __future__ import annotations

import json
import struct
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np


@dataclass
class Mesh:
    positions: np.ndarray  # (n, 3) float32, metres
    normals: np.ndarray  # (n, 3) float32
    indices: np.ndarray  # (m, 3) uint32
    name: str = ""

    @property
    def triangle_count(self) -> int:
        return len(self.indices)


@dataclass
class Node:
    name: str
    matrix: np.ndarray = field(default_factory=lambda: np.eye(4))  # local transform
    mesh: int | None = None
    children: list["Node"] = field(default_factory=list)


@dataclass
class Model:
    meshes: list[Mesh]
    roots: list[Node]

    def instances(self):
        """(node path, world matrix, mesh) for every leaf with a mesh."""
        out = []

        def walk(node: Node, parent: np.ndarray, path: tuple[str, ...]):
            world = parent @ node.matrix
            p = path + (node.name,)
            if node.mesh is not None:
                out.append((p, world, self.meshes[node.mesh]))
            for c in node.children:
                walk(c, world, p)

        for r in self.roots:
            walk(r, np.eye(4), ())
        return out

    def bounds(self) -> tuple[np.ndarray, np.ndarray]:
        lo, hi = np.full(3, np.inf), np.full(3, -np.inf)
        for _, world, mesh in self.instances():
            pts = mesh.positions.astype(np.float64) @ world[:3, :3].T + world[:3, 3]
            lo, hi = np.minimum(lo, pts.min(0)), np.maximum(hi, pts.max(0))
        return lo, hi

    @property
    def triangle_count(self) -> int:
        return sum(m.triangle_count for _, _, m in self.instances())


def vertex_normals(positions: np.ndarray, indices: np.ndarray) -> np.ndarray:
    """Area-weighted vertex normals."""
    p = positions.astype(np.float64)
    tri = p[indices]
    fn = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
    n = np.zeros_like(p)
    for k in range(3):
        np.add.at(n, indices[:, k], fn)
    length = np.linalg.norm(n, axis=1, keepdims=True)
    n = np.divide(n, length, out=np.zeros_like(n), where=length > 0)
    return n.astype(np.float32)


# --- glb ---------------------------------------------------------------------

_FLOAT, _UINT = 5126, 5125


def write_glb(model: Model, path: Path) -> None:
    blob = bytearray()
    views: list[dict] = []
    accessors: list[dict] = []

    def add(arr: np.ndarray, comp: int, kind: str, target: int, minmax: bool = False) -> int:
        while len(blob) % 4:
            blob.append(0)
        data = arr.tobytes()
        views.append({"buffer": 0, "byteOffset": len(blob), "byteLength": len(data), "target": target})
        blob.extend(data)
        acc = {"bufferView": len(views) - 1, "componentType": comp, "count": int(arr.shape[0]), "type": kind}
        if minmax:
            acc["min"] = arr.min(0).astype(float).tolist()
            acc["max"] = arr.max(0).astype(float).tolist()
        accessors.append(acc)
        return len(accessors) - 1

    meshes = []
    for m in model.meshes:
        pos = add(np.ascontiguousarray(m.positions, np.float32), _FLOAT, "VEC3", 34962, minmax=True)
        nrm = add(np.ascontiguousarray(m.normals, np.float32), _FLOAT, "VEC3", 34962)
        idx = add(np.ascontiguousarray(m.indices, np.uint32).reshape(-1), _UINT, "SCALAR", 34963)
        meshes.append({"name": m.name, "primitives": [{"attributes": {"POSITION": pos, "NORMAL": nrm}, "indices": idx, "mode": 4}]})

    nodes: list[dict] = []

    def emit(node: Node) -> int:
        i = len(nodes)
        nodes.append({"name": node.name})
        if not np.allclose(node.matrix, np.eye(4)):
            nodes[i]["matrix"] = np.asarray(node.matrix, float).T.reshape(-1).tolist()  # column-major
        if node.mesh is not None:
            nodes[i]["mesh"] = node.mesh
        kids = [emit(c) for c in node.children]
        if kids:
            nodes[i]["children"] = kids
        return i

    roots = [emit(r) for r in model.roots]
    gltf = {
        "asset": {"version": "2.0", "generator": "AeroBench aeroengine"},
        "extras": {"up_axis": "z", "units": "m"},
        "scene": 0,
        "scenes": [{"nodes": roots}],
        "nodes": nodes,
        "meshes": meshes,
        "accessors": accessors,
        "bufferViews": views,
        "buffers": [{"byteLength": len(blob)}],
    }
    js = json.dumps(gltf, separators=(",", ":")).encode()
    js += b" " * (-len(js) % 4)
    blob += b"\0" * (-len(blob) % 4)
    total = 12 + 8 + len(js) + 8 + len(blob)
    with open(path, "wb") as f:
        f.write(struct.pack("<4sII", b"glTF", 2, total))
        f.write(struct.pack("<I4s", len(js), b"JSON"))
        f.write(js)
        f.write(struct.pack("<I4s", len(blob), b"BIN\0"))
        f.write(blob)


def read_glb(path: Path) -> Model:
    """Reads back what write_glb writes. For tests and round trips."""
    data = Path(path).read_bytes()
    magic, version, _ = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF" or version != 2:
        raise ValueError("not a glTF 2.0 binary")
    jlen, _ = struct.unpack_from("<I4s", data, 12)
    gltf = json.loads(data[20 : 20 + jlen])
    blen, _ = struct.unpack_from("<I4s", data, 20 + jlen)
    blob = data[28 + jlen : 28 + jlen + blen]

    def accessor(i: int) -> np.ndarray:
        a = gltf["accessors"][i]
        v = gltf["bufferViews"][a["bufferView"]]
        dtype = np.float32 if a["componentType"] == _FLOAT else np.uint32
        width = {"SCALAR": 1, "VEC3": 3}[a["type"]]
        arr = np.frombuffer(blob, dtype, a["count"] * width, v.get("byteOffset", 0) + a.get("byteOffset", 0))
        return arr.reshape(-1, width) if width > 1 else arr

    meshes = []
    for m in gltf["meshes"]:
        prim = m["primitives"][0]
        meshes.append(Mesh(accessor(prim["attributes"]["POSITION"]), accessor(prim["attributes"]["NORMAL"]),
                           accessor(prim["indices"]).reshape(-1, 3), m.get("name", "")))

    def build(i: int) -> Node:
        n = gltf["nodes"][i]
        mat = np.array(n["matrix"], float).reshape(4, 4).T if "matrix" in n else np.eye(4)
        return Node(n.get("name", ""), mat, n.get("mesh"), [build(c) for c in n.get("children", [])])

    return Model(meshes, [build(i) for i in gltf["scenes"][gltf.get("scene", 0)]["nodes"]])


# --- STL and OBJ export (used for the samples) -------------------------------

def _world_triangles(model: Model, scale: float):
    for path, world, mesh in model.instances():
        p = mesh.positions.astype(np.float64) @ world[:3, :3].T + world[:3, 3]
        yield path, (p * scale)[mesh.indices]


def write_stl(model: Model, path: Path, scale: float = 1.0) -> None:
    tris = np.concatenate([t for _, t in _world_triangles(model, scale)])
    n = np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0])
    n /= np.linalg.norm(n, axis=1, keepdims=True) + 1e-30
    rec = np.zeros(len(tris), dtype=[("n", "<f4", 3), ("v", "<f4", (3, 3)), ("a", "<u2")])
    rec["n"], rec["v"] = n, tris
    with open(path, "wb") as f:
        f.write(b"AeroBench sample".ljust(80, b" "))
        f.write(struct.pack("<I", len(tris)))
        f.write(rec.tobytes())


def write_obj(model: Model, path: Path, scale: float = 1.0) -> None:
    lines = ["# AeroBench sample, one object per part instance"]
    base = 1
    for path_names, tris in _world_triangles(model, scale):
        lines.append("o " + "/".join(path_names[1:] or path_names))
        flat = tris.reshape(-1, 3)
        lines += [f"v {x:.4f} {y:.4f} {z:.4f}" for x, y, z in flat]
        lines += [f"f {base + 3*i} {base + 3*i + 1} {base + 3*i + 2}" for i in range(len(tris))]
        base += len(flat)
    Path(path).write_text("\n".join(lines) + "\n")
