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


# --- Reading STL and OBJ (for the geometry checks) -----------------------------

def read_stl(path: Path, scale: float = 1.0) -> Model:
    data = Path(path).read_bytes()
    n = int.from_bytes(data[80:84], "little") if len(data) >= 84 else -1
    if n >= 0 and len(data) == 84 + 50 * n:
        rec = np.frombuffer(data, dtype=[("n", "<f4", 3), ("v", "<f4", (3, 3)), ("a", "<u2")], count=n, offset=84)
        tris = rec["v"].astype(np.float64)
    else:
        nums = [line.split()[1:4] for line in data.decode(errors="replace").splitlines() if line.strip().startswith("vertex")]
        tris = np.asarray(nums, float).reshape(-1, 3, 3)
    tris = tris * scale
    pos = tris.reshape(-1, 3).astype(np.float32)
    idx = np.arange(len(pos), dtype=np.uint32).reshape(-1, 3)
    mesh = Mesh(pos, vertex_normals(pos, idx), idx, Path(path).stem)
    return Model([mesh], [Node(Path(path).stem, mesh=0)])


def read_obj(path: Path, scale: float = 1.0) -> Model:
    verts: list[list[float]] = []
    groups: list[tuple[str, list[list[int]]]] = [(Path(path).stem, [])]
    for line in Path(path).read_text(errors="replace").splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "v":
            verts.append([float(a) for a in parts[1:4]])
        elif parts[0] in ("o", "g"):
            groups.append((" ".join(parts[1:]) or f"Group {len(groups)}", []))
        elif parts[0] == "f":
            ids = [int(t.split("/")[0]) for t in parts[1:]]
            ids = [i - 1 if i > 0 else len(verts) + i for i in ids]
            groups[-1][1].extend([ids[0], ids[k], ids[k + 1]] for k in range(1, len(ids) - 1))
    v = np.asarray(verts, float) * scale
    meshes, nodes = [], []
    for name, faces in groups:
        if not faces:
            continue
        f = np.asarray(faces, np.int64)
        used, inv = np.unique(f, return_inverse=True)
        pos = v[used].astype(np.float32)
        idx = inv.reshape(-1, 3).astype(np.uint32)
        meshes.append(Mesh(pos, vertex_normals(pos, idx), idx, name))
        nodes.append(Node(name, mesh=len(meshes) - 1))
    return Model(meshes, [Node(Path(path).stem, children=nodes)])


# --- STEP export (a triangle mesh as a B-rep, for CAD) -----------------------

def simplify(model: Model, max_triangles: int) -> Model:
    """The model in world coordinates with at most about `max_triangles`
    triangles, shared between its meshes; closed surfaces stay closed."""
    import vtk
    from vtk.util.numpy_support import numpy_to_vtk, numpy_to_vtkIdTypeArray, vtk_to_numpy

    total = model.triangle_count
    meshes = []
    for _, world, mesh in model.instances():
        p = mesh.positions.astype(np.float64) @ world[:3, :3].T + world[:3, 3]
        if total > max_triangles:
            poly = vtk.vtkPolyData()
            points = vtk.vtkPoints()
            points.SetData(numpy_to_vtk(p, deep=True))
            poly.SetPoints(points)
            cells = np.hstack([np.full((len(mesh.indices), 1), 3), mesh.indices]).astype(np.int64).ravel()
            polys = vtk.vtkCellArray()
            polys.ImportLegacyFormat(numpy_to_vtkIdTypeArray(cells, deep=True))
            poly.SetPolys(polys)
            clean = vtk.vtkCleanPolyData()  # weld, so the decimator sees one surface
            clean.SetInputData(poly)
            # Not vtkQuadricDecimation: it tears closed surfaces (free and
            # non-manifold edges), so the body could no longer be a solid.
            decimate = vtk.vtkDecimatePro()
            decimate.SetInputConnection(clean.GetOutputPort())
            decimate.SetTargetReduction(1 - max_triangles / total)
            decimate.PreserveTopologyOn()
            decimate.SplittingOff()
            decimate.BoundaryVertexDeletionOff()
            decimate.SetFeatureAngle(45)  # the default 15 stalls far above the target
            decimate.Update()
            out = decimate.GetOutput()
            p = vtk_to_numpy(out.GetPoints().GetData()).astype(np.float64)
            idx = vtk_to_numpy(out.GetPolys().GetConnectivityArray()).reshape(-1, 3)
        else:
            idx = mesh.indices
        pos, idx = p.astype(np.float32), idx.astype(np.uint32)
        meshes.append(Mesh(pos, vertex_normals(pos, idx), idx, mesh.name))
    return Model(meshes, [Node(m.name, mesh=i) for i, m in enumerate(meshes)])


def _edge_pairs(idx: np.ndarray):
    """Start and end vertex of every triangle side (side 3f+k is face f's k-th),
    its undirected edge id, and how many sides use each edge."""
    a, b = idx.ravel().astype(np.int64), idx[:, [1, 2, 0]].ravel().astype(np.int64)
    _, edge, uses = np.unique(np.minimum(a, b) * (int(idx.max()) + 1) + np.maximum(a, b),
                              return_inverse=True, return_counts=True)
    return a, b, edge.ravel(), uses


def _split_pinches(pos: np.ndarray, idx: np.ndarray):
    """Give each fan of triangles round a vertex its own copy of it, so where
    two sheets touch (an edge with four faces, as decimation leaves) each
    sheet keeps its own edge and stays a closed, consistently wound surface."""
    from scipy.sparse import coo_matrix
    from scipy.sparse.csgraph import connected_components

    a, b, edge, uses = _edge_pairs(idx)
    side = np.flatnonzero(uses[edge] == 2)
    side = side[np.argsort(edge[side], kind="stable")].reshape(-1, 2)  # the two sides of each edge
    h, g = side[:, 0], side[:, 1]
    corner = lambda s, k: 3 * (s // 3) + (s % 3 + k) % 3  # noqa: E731 (corner k along side s)
    same = a[h] == a[g]
    join = np.concatenate([[corner(h, 0), np.where(same, corner(g, 0), corner(g, 1))],
                           [corner(h, 1), np.where(same, corner(g, 1), corner(g, 0))]], axis=1)
    n = idx.size
    graph = coo_matrix((np.ones(join.shape[1]), (join[0], join[1])), shape=(n, n))
    _, label = connected_components(graph, directed=False)
    _, first, new = np.unique(label, return_index=True, return_inverse=True)
    return pos[idx.ravel()[first]], new.reshape(-1, 3)


def write_step_mesh(model: Model, path: Path, scale: float = 1.0) -> dict:
    """Write every triangle as a planar face. Faces share the mesh's own
    vertices and edges (no sewing tolerance to pair the wrong sheets); each
    connected surface is a shell, and a closed one becomes a solid. Returns
    counts of faces, shells and solids."""
    from OCP.BRep import BRep_Builder, BRep_Tool
    from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeEdge, BRepBuilderAPI_MakeFace, BRepBuilderAPI_MakeVertex
    from OCP.BRepCheck import BRepCheck_Analyzer
    from OCP.BRepGProp import BRepGProp
    from OCP.gp import gp_Dir, gp_Pln, gp_Pnt
    from OCP.GProp import GProp_GProps
    from OCP.IFSelect import IFSelect_RetDone
    from OCP.ShapeFix import ShapeFix_Solid
    from OCP.STEPControl import STEPControl_AsIs, STEPControl_Writer
    from OCP.TopoDS import TopoDS_Compound, TopoDS_Shell, TopoDS_Wire
    from scipy.sparse import coo_matrix
    from scipy.sparse.csgraph import connected_components
    from scipy.spatial import cKDTree

    parts = []
    for _, world, mesh in model.instances():
        p = (mesh.positions.astype(np.float64) @ world[:3, :3].T + world[:3, 3]) * scale
        parts.append((p, mesh.indices.astype(np.int64)))
    if not sum(len(i) for _, i in parts):
        raise ValueError("the mesh has no triangles")
    offsets = np.cumsum([0] + [len(p) for p, _ in parts])
    pos = np.concatenate([p for p, _ in parts])
    idx = np.concatenate([i + o for (_, i), o in zip(parts, offsets)])
    # Weld corners closer than float32 noise (a glb stores float32), else
    # they make edges too short for OpenCascade and sliver faces.
    tol = 1e-6 * max(float(np.ptp(pos, axis=0).max()), 1e-12)
    pairs = cKDTree(pos).query_pairs(tol, output_type="ndarray")
    _, weld = connected_components(coo_matrix((np.ones(len(pairs)), (pairs[:, 0], pairs[:, 1])),
                                              shape=(len(pos), len(pos))), directed=False)
    _, first, weld = np.unique(weld, return_index=True, return_inverse=True)
    pos, idx = pos[first], weld.ravel()[idx]
    idx = idx[(idx[:, 0] != idx[:, 1]) & (idx[:, 1] != idx[:, 2]) & (idx[:, 2] != idx[:, 0])]
    # A triangle folded onto a reversed twin (decimation, or the weld) goes with it.
    _, inv, n = np.unique(np.sort(idx, axis=1), axis=0, return_inverse=True, return_counts=True)
    idx = idx[n[inv.ravel()] == 1]
    pos, idx = _split_pinches(pos, idx)
    normal = np.cross(pos[idx[:, 1]] - pos[idx[:, 0]], pos[idx[:, 2]] - pos[idx[:, 0]])
    flat = np.linalg.norm(normal, axis=1) < 1e-12 * max(1.0, float(np.abs(pos).max())) ** 2
    if flat.any():
        # Marching cubes and decimation leave zero-area slivers; dropping one
        # would open a hole, so it gets any plane through its line instead.
        side = pos[idx[flat, 1]] - pos[idx[flat, 0]]
        side = np.where(np.linalg.norm(side, axis=1, keepdims=True) > 0, side, pos[idx[flat, 2]] - pos[idx[flat, 0]])
        normal[flat] = np.cross(side, np.eye(3)[np.argmin(np.abs(side), axis=1)])
    normal /= np.linalg.norm(normal, axis=1, keepdims=True)

    a, b, edge, uses = _edge_pairs(idx)
    nf = len(idx)
    side = np.flatnonzero(uses[edge] == 2)
    side = side[np.argsort(edge[side], kind="stable")].reshape(-1, 2) // 3
    _, surface = connected_components(coo_matrix((np.ones(len(side)), (side[:, 0], side[:, 1])), shape=(nf, nf)),
                                      directed=False)

    builder = BRep_Builder()
    vertex = [BRepBuilderAPI_MakeVertex(gp_Pnt(*q)).Vertex() for q in pos]
    edges = {}
    shells: dict[int, TopoDS_Shell] = {}
    for f in range(nf):
        wire = TopoDS_Wire()
        builder.MakeWire(wire)
        for k in range(3):
            u, v = int(a[3 * f + k]), int(b[3 * f + k])
            e = int(edge[3 * f + k])
            if e not in edges:
                lo, hi = min(u, v), max(u, v)
                edges[e] = BRepBuilderAPI_MakeEdge(vertex[lo], vertex[hi]).Edge()
            builder.Add(wire, edges[e] if u < v else edges[e].Reversed())
        wire.Closed(True)
        plane = gp_Pln(gp_Pnt(*pos[idx[f, 0]]), gp_Dir(*normal[f]))
        shell = shells.get(surface[f])
        if shell is None:
            shell = shells[surface[f]] = TopoDS_Shell()
            builder.MakeShell(shell)
        builder.Add(shell, BRepBuilderAPI_MakeFace(plane, wire, True).Face())

    out = TopoDS_Compound()
    builder.MakeCompound(out)
    solids = 0
    for shell in shells.values():
        closed = BRep_Tool.IsClosed_s(shell)  # every edge shared by two faces
        shell.Closed(closed)
        if closed:
            solid = ShapeFix_Solid().SolidFromShell(shell)  # also orients the shell outward
            props = GProp_GProps()
            BRepGProp.VolumeProperties_s(solid, props)
            if BRepCheck_Analyzer(solid).IsValid() and props.Mass() > 0:
                builder.Add(out, solid)
                solids += 1
                continue
        builder.Add(out, shell)

    writer = STEPControl_Writer()
    writer.Transfer(out, STEPControl_AsIs)
    if writer.Write(str(path)) != IFSelect_RetDone:
        raise ValueError(f"could not write {path}")
    return {"faces": int(nf), "shells": len(shells), "solids": solids}
