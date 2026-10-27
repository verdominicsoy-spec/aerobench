"""Mesh health checks and safe repairs, in plain NumPy.

Checks: duplicate vertices, degenerate faces, duplicate faces (including
back-to-back pairs), open edges and holes, non-manifold edges, inconsistent
winding, and pierced (self-intersecting) faces, split into intersections
within one body and between bodies.

Repairs are limited to what is safe to automate: weld vertices, drop
degenerate and duplicate faces, make winding consistent and outward, close
small holes. Pierced faces and non-manifold edges are reported only.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np


@dataclass
class Soup:
    """A triangle mesh in world coordinates (metres) with a body id per face."""

    vertices: np.ndarray  # (n, 3) float64
    faces: np.ndarray  # (m, 3) int64
    body: np.ndarray  # (m,) int64, which part/instance each face came from
    body_names: list[str] = field(default_factory=list)


MAX_POINTS = 2000  # markers per issue sent back to the app


def _sample(points: np.ndarray) -> list[list[float]]:
    if len(points) > MAX_POINTS:
        points = points[np.linspace(0, len(points) - 1, MAX_POINTS).round().astype(int)]
    return np.round(points, 6).tolist()


def unique_rows(a: np.ndarray):
    """np.unique(a, axis=0, return_index, return_inverse, return_counts),
    several times faster: lexsort plus a diff instead of a structured sort."""
    order = np.lexsort(a.T[::-1])
    s = a[order]
    new = np.r_[True, np.any(s[1:] != s[:-1], axis=1)]
    group = np.cumsum(new) - 1
    inverse = np.empty(len(a), np.int64)
    inverse[order] = group
    first = order[new]
    counts = np.diff(np.r_[np.flatnonzero(new), len(a)])
    return s[new], first, inverse, counts


def weld(vertices: np.ndarray, faces: np.ndarray, tol: float) -> tuple[np.ndarray, np.ndarray, int]:
    """Merges vertices closer than about `tol`. Returns new vertices, remapped faces, merged count."""
    if len(vertices) == 0:
        return vertices, faces, 0
    key = np.round(vertices / tol).astype(np.int64)
    _, first, inverse, _ = unique_rows(key)
    return vertices[first], inverse[faces], len(vertices) - len(first)


def _areas(v: np.ndarray, f: np.ndarray) -> np.ndarray:
    t = v[f]
    return 0.5 * np.linalg.norm(np.cross(t[:, 1] - t[:, 0], t[:, 2] - t[:, 0]), axis=1)


def _edges(f: np.ndarray):
    """Directed edges (a, b), the face of each, and undirected keys."""
    e = np.concatenate([f[:, [0, 1]], f[:, [1, 2]], f[:, [2, 0]]])
    face = np.tile(np.arange(len(f)), 3)
    key = np.sort(e, axis=1)
    return e, face, key


def components(n_vertices: int, f: np.ndarray) -> np.ndarray:
    """Connected component id per face (faces sharing a vertex are connected)."""
    from scipy.sparse import coo_matrix
    from scipy.sparse.csgraph import connected_components

    e = np.concatenate([f[:, [0, 1]], f[:, [1, 2]]])
    graph = coo_matrix((np.ones(len(e)), (e[:, 0], e[:, 1])), shape=(n_vertices, n_vertices))
    _, labels = connected_components(graph, directed=False)
    _, comp = np.unique(labels[f[:, 0]], return_inverse=True)
    return comp.reshape(-1)


# --- Pierced faces --------------------------------------------------------------

def _segment_hits(p0, p1, a, b, c, eps):
    """Vectorised segment-triangle test (Moller-Trumbore)."""
    d = p1 - p0
    e1, e2 = b - a, c - a
    h = np.cross(d, e2)
    det = np.einsum("ij,ij->i", e1, h)
    ok = np.abs(det) > eps
    inv = np.where(ok, 1.0 / np.where(ok, det, 1.0), 0.0)
    s = p0 - a
    u = inv * np.einsum("ij,ij->i", s, h)
    q = np.cross(s, e1)
    v = inv * np.einsum("ij,ij->i", d, q)
    t = inv * np.einsum("ij,ij->i", e2, q)
    # Crossing the triangle anywhere including its edges counts; the segment
    # must pass through, not just end on the surface (touching is not piercing).
    tol = 1e-9
    hit = ok & (u >= -tol) & (v >= -tol) & (u + v <= 1 + tol) & (t > tol) & (t < 1 - tol)
    return hit, p0 + t[:, None] * d


def intersecting_pairs(v: np.ndarray, f: np.ndarray, chunk: int = 400_000) -> tuple[np.ndarray, np.ndarray, bool]:
    """Face pairs that pierce each other (not merely touching or sharing a
    vertex), with one intersection point per pair. Candidate pairs come from
    a uniform grid and are tested chunk by chunk as they are generated, so
    memory stays bounded however many there are. The third value is always
    True; it is kept so callers can report partial checks if a limit is ever
    reintroduced."""
    m = len(f)
    empty = (np.zeros((0, 2), np.int64), np.zeros((0, 3)), True)
    if m < 2:
        return empty
    tri = v[f]
    lo, hi = tri.min(1), tri.max(1)
    diag = float(np.linalg.norm(v.max(0) - v.min(0))) or 1.0
    cell = max(float(np.median((hi - lo).max(1))), diag * 1e-6)
    c0 = np.floor(lo / cell).astype(np.int64)
    span = np.floor(hi / cell).astype(np.int64) - c0 + 1
    counts = span.prod(1)
    big = counts > 512

    found, points = [], []

    def test(pairs: np.ndarray) -> None:
        if len(pairs) == 0:
            return
        a, b = pairs[:, 0], pairs[:, 1]
        pairs = pairs[np.all((lo[a] <= hi[b]) & (lo[b] <= hi[a]), axis=1)]
        fa, fb = f[pairs[:, 0]], f[pairs[:, 1]]
        pairs = pairs[~(fa[:, :, None] == fb[:, None, :]).any(axis=(1, 2))]
        if len(pairs) == 0:
            return
        A, B = tri[pairs[:, 0]], tri[pairs[:, 1]]
        hit = np.zeros(len(pairs), bool)
        where = np.zeros((len(pairs), 3))
        for X, Y in ((A, B), (B, A)):
            for i, j in ((0, 1), (1, 2), (2, 0)):
                h, pt = _segment_hits(X[:, i], X[:, j], Y[:, 0], Y[:, 1], Y[:, 2], 1e-12 * diag)
                new = h & ~hit
                where[new] = pt[new]
                hit |= h
        found.append(pairs[hit])
        points.append(where[hit])

    small_counts = counts[~big]
    idx = np.repeat(np.arange(m)[~big], small_counts)
    offs = np.arange(len(idx)) - np.repeat(np.cumsum(small_counts) - small_counts, small_counts)
    sp = span[~big][np.repeat(np.arange((~big).sum()), small_counts)]
    cells = c0[idx] + np.stack([offs % sp[:, 0], (offs // sp[:, 0]) % sp[:, 1], offs // (sp[:, 0] * sp[:, 1])], 1)
    del offs, sp
    keys = cells[:, 0] * 73856093 ^ cells[:, 1] * 19349663 ^ cells[:, 2] * 83492791
    del cells
    order = np.argsort(keys, kind="stable")
    keys, idx = keys[order], idx[order]
    starts = np.flatnonzero(np.r_[True, keys[1:] != keys[:-1]])
    sizes = np.diff(np.r_[starts, len(keys)])
    for size in np.unique(sizes[sizes > 1]):
        groups = starts[sizes == size]
        iu, ju = np.triu_indices(size, 1)
        per = max(1, chunk // len(iu))
        for g in range(0, len(groups), per):
            gs = groups[g:g + per]
            a = idx[gs[:, None] + iu[None, :]].reshape(-1)
            b = idx[gs[:, None] + ju[None, :]].reshape(-1)
            test(np.stack([np.minimum(a, b), np.maximum(a, b)], 1))
    for i in np.flatnonzero(big):  # very large faces: against every overlapping box
        others = np.flatnonzero(np.all((lo <= hi[i]) & (lo[i] <= hi), axis=1))
        test(np.stack([np.minimum(i, others), np.maximum(i, others)], 1))
    if not found or not sum(len(x) for x in found):
        return empty
    pairs = np.concatenate(found)
    pts = np.concatenate(points)
    pairs, keep, _, _ = unique_rows(pairs)  # a pair can share several cells
    return pairs, pts[keep], True


# --- Report -----------------------------------------------------------------------

def check(soup: Soup, weld_tol: float | None = None, intersections: bool = True) -> dict:
    v0, f0 = soup.vertices.astype(np.float64), soup.faces.astype(np.int64)
    diag = float(np.linalg.norm(v0.max(0) - v0.min(0))) if len(v0) else 1.0
    tol = weld_tol if weld_tol else max(diag * 1e-7, 1e-9)
    v, f, merged = weld(v0, f0, tol)
    issues = []

    def add(kind, title, severity, count, points, detail, fixable):
        issues.append({"kind": kind, "title": title, "severity": severity, "count": int(count),
                       "detail": detail, "fixable": fixable, "points": _sample(np.asarray(points).reshape(-1, 3))})

    centroids = v[f].mean(1)
    repeated = (f[:, 0] == f[:, 1]) | (f[:, 1] == f[:, 2]) | (f[:, 2] == f[:, 0])
    degenerate = repeated | (_areas(v, f) < (tol * tol))
    add("degenerate", "Degenerate faces", "warning", degenerate.sum(), centroids[degenerate],
        "Zero-area slivers or faces that collapse to a line.", True)

    good = ~degenerate
    fg, body = f[good], soup.body[good]
    srt = np.sort(fg, axis=1)
    _, first, inv, cnt = unique_rows(srt)
    dup_faces = cnt[inv] > 1
    n_dups = int((cnt - 1)[cnt > 1].sum())
    add("duplicate_faces", "Duplicate faces", "error", n_dups, v[fg[dup_faces]].mean(1),
        "Faces using the same three vertices, including back-to-back double walls.", True)

    # Edge topology on unique faces.
    keep = np.zeros(len(fg), bool)
    keep[first] = True
    fu = fg[keep]
    e, ef, key = _edges(fu)
    ukey, _, einv, ecnt = unique_rows(key)
    mid = v[ukey].mean(1)
    open_edges = ecnt == 1
    add("open_edges", "Open edges (holes, gaps)", "warning", open_edges.sum(), mid[open_edges],
        "Edges with a face on one side only: the surface is not closed there.", True)
    nonmanifold = ecnt > 2
    add("non_manifold_edges", "Non-manifold edges", "error", nonmanifold.sum(), mid[nonmanifold],
        "Three or more faces meet on one edge. Not repaired automatically: decide which faces belong.", False)

    # Winding: on an edge shared by two faces, they must run it in opposite directions.
    two = ecnt[einv] == 2
    same_dir = np.zeros(len(ukey), bool)
    order = np.argsort(einv, kind="stable")
    ek, ed = einv[order], e[order]
    pair_start = np.flatnonzero(np.r_[True, ek[1:] != ek[:-1]])
    for_two = two[order][pair_start]
    p = pair_start[for_two]
    same_dir[ek[p]] = (ed[p, 0] == ed[p + 1, 0])
    add("flipped", "Inconsistent normals (flipped faces)", "warning", same_dir.sum(), mid[same_dir],
        "Neighbouring faces wound in opposite directions: some normals point inward.", True)

    complete = True
    if intersections:
        pairs, pts, complete = intersecting_pairs(v, fu)
        bu = body[keep]
        within = bu[pairs[:, 0]] == bu[pairs[:, 1]] if len(pairs) else np.zeros(0, bool)
        add("self_intersections", "Pierced faces (self-intersections)", "error", within.sum(), pts[within],
            "Faces of the same body passing through each other. Not repaired automatically: needs remeshing or a boolean union.", False)
        add("interference", "Interference between parts", "info", (~within).sum(), pts[~within],
            "Faces of different parts passing through each other. Often intended (press fits, bolts), check it is.", False)

    add("duplicate_vertices", "Duplicate vertices", "info", merged, np.zeros((0, 3)),
        f"Vertices within {tol * 1000:.3g} mm of another, merged for these checks.", True)

    comp = components(len(v), fu) if len(fu) else np.zeros(0, np.int64)
    closed = not open_edges.any() and not nonmanifold.any()
    return {
        "triangles": int(len(f0)),
        "vertices": int(len(v0)),
        "bodies": int(comp.max() + 1) if len(comp) else 0,
        "closed": bool(closed),
        "weld_tolerance_mm": tol * 1000,
        "issues": issues,
        "problems": int(sum(i["count"] for i in issues if i["severity"] in ("error", "warning"))),
        "intersections_checked": bool(intersections),
        "intersections_complete": bool(complete),
    }


# --- Repair -------------------------------------------------------------------

def repair(soup: Soup, weld_tol: float | None = None, max_hole_edges: int = 64) -> tuple[Soup, dict]:
    """Safe fixes only. Returns the repaired soup and what was done."""
    v0, f0 = soup.vertices.astype(np.float64), soup.faces.astype(np.int64)
    diag = float(np.linalg.norm(v0.max(0) - v0.min(0))) if len(v0) else 1.0
    tol = weld_tol if weld_tol else max(diag * 1e-7, 1e-9)
    done = {}
    v, f, done["vertices_merged"] = weld(v0, f0, tol)
    body = soup.body.copy()

    bad = (f[:, 0] == f[:, 1]) | (f[:, 1] == f[:, 2]) | (f[:, 2] == f[:, 0]) | (_areas(v, f) < tol * tol)
    done["degenerate_removed"] = int(bad.sum())
    f, body = f[~bad], body[~bad]

    _, first, _, _ = unique_rows(np.sort(f, axis=1))
    first = np.sort(first)
    done["duplicates_removed"] = int(len(f) - len(first))
    f, body = f[first], body[first]

    f, done["faces_flipped"] = _orient(v, f)
    v, f, body, done["holes_closed"] = _close_holes(v, f, body, max_hole_edges)

    used = np.unique(f)
    remap = np.full(len(v), -1)
    remap[used] = np.arange(len(used))
    return Soup(v[used], remap[f], body, soup.body_names), done


def _orient(v: np.ndarray, f: np.ndarray) -> tuple[np.ndarray, int]:
    """Consistent winding across shared edges, then outward for closed parts."""
    f = f.copy()
    m = len(f)
    if m == 0:
        return f, 0
    e, ef, key = _edges(f)
    ukey, _, inv, _ = unique_rows(key)
    order = np.argsort(inv, kind="stable")
    by_edge = np.split(ef[order], np.flatnonzero(np.diff(inv[order])) + 1)
    neighbours: list[list[int]] = [[] for _ in range(m)]
    for faces in by_edge:
        if len(faces) == 2:
            a, b = faces
            neighbours[a].append(b)
            neighbours[b].append(a)
    flipped = np.zeros(m, bool)
    seen = np.zeros(m, bool)

    def directed(face):
        a, b, c = f[face]
        return {(a, b), (b, c), (c, a)}

    comp_of = np.full(m, -1)
    comp = 0
    for start in range(m):
        if seen[start]:
            continue
        seen[start] = True
        comp_of[start] = comp
        stack = [start]
        while stack:
            x = stack.pop()
            dx = directed(x)
            for y in neighbours[x]:
                if seen[y]:
                    continue
                seen[y] = True
                comp_of[y] = comp
                if directed(y) & dx:  # shares a directed edge: wound the same way, flip it
                    f[y] = f[y][::-1]
                    flipped[y] = ~flipped[y]
                stack.append(y)
        comp += 1
    # Outward: a closed part with negative signed volume is inside out.
    t = v[f]
    signed = np.einsum("ij,ij->i", t[:, 0], np.cross(t[:, 1], t[:, 2])) / 6
    for c in range(comp):
        sel = comp_of == c
        if signed[sel].sum() < 0:
            f[sel] = f[sel][:, ::-1]
            flipped[sel] = ~flipped[sel]
    return f, int(flipped.sum())


def _close_holes(v, f, body, max_edges):
    e, ef, key = _edges(f)
    ukey, _, inv, cnt = unique_rows(key)
    boundary = cnt[inv] == 1
    nxt = {int(a): int(b) for a, b in e[boundary]}  # boundary edges run the opposite way round the hole
    owner = {int(a): int(body[fi]) for (a, _), fi in zip(e[boundary], ef[boundary])}
    new_v, new_f, new_b, closed = [v], [f], [body], 0
    seen = set()
    n = len(v)
    for start in list(nxt):
        if start in seen:
            continue
        loop, x = [], start
        while x in nxt and x not in seen:
            seen.add(x)
            loop.append(x)
            x = nxt[x]
        if x != start or len(loop) < 3 or len(loop) > max_edges:
            continue
        centre = v[loop].mean(0)
        new_v.append(centre[None])
        k = len(loop)
        # Wind the cap opposite to the boundary edges so normals stay consistent.
        tris = np.array([[loop[(i + 1) % k], loop[i], n] for i in range(k)])
        new_f.append(tris)
        new_b.append(np.full(k, owner[loop[0]]))
        n += 1
        closed += 1
    return np.concatenate(new_v), np.concatenate(new_f), np.concatenate(new_b), closed
