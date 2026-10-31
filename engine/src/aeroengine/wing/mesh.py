"""2D meshes of multi-element wings for SU2, with gmsh.

Zones, by what the flow does there:

* Wall layers on every element: structured quads, first cell height for
  y+ about 1 at the run's Reynolds number, geometric growth, thick enough to
  hold the boundary layer but never more than a fraction of the narrowest
  slot (layers from neighbouring elements must not collide).
* Laminar zones (leading edge to the transition point on each surface,
  from the quick viscous solver or typed): the surface is resolved several
  times finer, so the wall quads there are short and flow-aligned. This is
  where a transition model needs resolution.
* Turbulent zones and wakes: unstructured triangles, refined along each
  element's wake, coarsening out to a far field circle about 50 chords away.

SU2 reads triangles and quads in 2D, not polygons: the unstructured zones
are triangles. (STAR-CCM+'s trimmed and polyhedral meshers would be the
backend for true polyhedra.)
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from ..job import EngineError


@dataclass
class Settings:
    re: float  # on the reference chord
    ref_chord: float
    y_plus: float = 1.0
    growth: float = 1.15  # wall-normal growth of the wall layers
    surface_fine: float = 0.0025  # surface spacing in laminar zones, fraction of each element's chord
    surface_coarse: float = 0.008  # elsewhere on the surface
    edge: float = 0.0015  # at leading and trailing edges
    wake_size: float = 0.01  # cell size along the wakes, fraction of the reference chord
    wake_length: float = 3.0  # wake refinement length, reference chords
    farfield: float = 50.0  # far field radius, reference chords
    farfield_size: float = 5.0  # cell size at the far field, reference chords
    max_layer_fraction_of_gap: float = 0.4
    alpha_deg: float = 0.0  # wakes follow the freestream
    ground: float | None = None  # y of a ground line under the wing (flow along x): the domain stops there
    # Transition x/c per element and surface: [(suction, pressure), ...];
    # 0 means turbulent from the leading edge (no laminar zone).
    transition: list[tuple[float, float]] = field(default_factory=list)


def first_cell_height(re: float, chord: float, y_plus: float = 1.0) -> float:
    """Wall distance for a target y+ from a flat-plate skin friction estimate
    (Schlichting, Cf = 0.026 Re^-1/7): y = y+ * c / (Re * sqrt(Cf / 2))."""
    cf = 0.026 / re ** (1 / 7)
    return y_plus * chord / (re * np.sqrt(cf / 2))


def boundary_layer_thickness(re: float, chord: float) -> float:
    """Turbulent flat plate at the trailing edge: 0.37 x Re_x^-0.2."""
    return 0.37 * chord * re**-0.2


def layers_for(first: float, growth: float, thickness: float) -> int:
    return int(np.ceil(np.log(1 + thickness * (growth - 1) / first) / np.log(growth)))


def _curvature_radius(side: np.ndarray) -> np.ndarray:
    """Radius of the circle through each point and its neighbours."""
    p0, p1, p2 = side[:-2], side[1:-1], side[2:]
    a = np.linalg.norm(p1 - p0, axis=1)
    b = np.linalg.norm(p2 - p1, axis=1)
    c = np.linalg.norm(p2 - p0, axis=1)
    cross = np.abs((p1 - p0)[:, 0] * (p2 - p0)[:, 1] - (p1 - p0)[:, 1] * (p2 - p0)[:, 0])
    r = np.where(cross > 1e-15, a * b * c / (2 * np.maximum(cross, 1e-300)), np.inf)
    return np.concatenate([[r[0]], r, [r[-1]]])


def _surface_nodes(xy: np.ndarray, chord: float, xtr_suction: float, xtr_pressure: float, s: Settings) -> np.ndarray:
    """Re-places the element's surface nodes: fine in the laminar zones and
    at the edges, coarser elsewhere, never turning more than about 6 degrees
    per segment (spacing at most a tenth of the local radius of curvature),
    and with neighbouring segments within 15% of each other, so the zone
    boundaries blend rather than jump. The suction-side transition goes
    with the first half of the Selig order; the caller swaps them for an
    inverted element."""
    half = (len(xy) - 1) // 2
    le, te = xy[half], 0.5 * (xy[0] + xy[-1])
    axis = (te - le) / np.linalg.norm(te - le)

    def resample(side: np.ndarray, xtr: float) -> np.ndarray:
        # side runs leading edge to trailing edge
        seg = np.linalg.norm(np.diff(side, axis=0), axis=1)
        arc = np.concatenate([[0], np.cumsum(seg)])
        total = arc[-1]
        xc = np.clip(((side - le) @ axis) / chord, 0, 1)
        radius = _curvature_radius(side)
        # Target spacing on a fine sampling of arc length.
        u = np.linspace(0, total, 4000)
        x = np.interp(u, arc, xc)
        h = np.where(x <= xtr, s.surface_fine, s.surface_coarse) * chord
        h = np.minimum(h, 0.1 * np.interp(u, arc, radius))
        h = np.minimum(h, (s.edge + (s.surface_coarse - s.edge) * np.clip(np.minimum(x, 1 - x) / 0.02, 0, 1)) * chord)
        h = np.maximum(h, 0.25 * s.edge * chord)
        # Grade: neighbours within 15% per segment, both ways.
        du = u[1] - u[0]
        for _ in range(2):
            for k in range(1, len(h)):
                h[k] = min(h[k], h[k - 1] + 0.15 * du)  # dh/ds <= 0.15: 15% per segment
            for k in range(len(h) - 2, -1, -1):
                h[k] = min(h[k], h[k + 1] + 0.15 * du)
        # Nodes where the integral of 1/h passes each whole number.
        n_int = np.concatenate([[0], np.cumsum(du / h[:-1])])
        count = max(int(np.ceil(n_int[-1])), 4)
        targets = np.linspace(0, n_int[-1], count + 1)
        pos = np.interp(targets, n_int, u)
        return np.column_stack([np.interp(pos, arc, side[:, 0]), np.interp(pos, arc, side[:, 1])])

    upper = resample(xy[:half + 1][::-1], xtr_suction)  # LE to TE
    lower = resample(xy[half:], xtr_pressure)
    return np.vstack([upper[::-1], lower[1:]])


CORNER_DEG = 60.0  # a turn sharper than this between neighbouring segments is a corner


def _convex_corners(nodes: np.ndarray, closed: bool) -> list[int]:
    """Indices of nodes where a counter-clockwise outline turns left (outward,
    convex) by more than CORNER_DEG."""
    pts = np.vstack([nodes[-1:], nodes, nodes[:1]]) if closed else nodes
    d = np.diff(pts, axis=0)
    cross = d[:-1, 0] * d[1:, 1] - d[:-1, 1] * d[1:, 0]
    turn = np.degrees(np.arctan2(cross, np.einsum("ij,ij->i", d[:-1], d[1:])))
    idx = np.where(turn > CORNER_DEG)[0]
    return [int(k) for k in idx] if closed else [int(k) + 1 for k in idx]


def build(elements: list[np.ndarray], s: Settings, out: Path, inverted: list[bool] | None = None) -> dict:
    """Meshes the wing and writes `out` (.su2) with markers wall_0, wall_1,
    ... and farfield. Returns statistics."""
    import gmsh

    if not elements:
        raise EngineError("no elements to mesh")
    inverted = inverted or [False] * len(elements)
    if not 1.02 <= s.growth <= 1.2:
        raise EngineError("wall layer growth must be between 1.02 and 1.2",
                          "faster growth gave meshes SU2 diverged on")
    chords = []
    for xy in elements:
        half = (len(xy) - 1) // 2
        chords.append(float(np.linalg.norm(0.5 * (xy[0] + xy[-1]) - xy[half])))
    trans = s.transition or [(0.0, 0.0)] * len(elements)

    # Wall layers: y+ about 1, thick enough for the boundary layer, thinner
    # than a fraction of the narrowest slot.
    first = first_cell_height(s.re, s.ref_chord, s.y_plus)
    thickness = 1.2 * boundary_layer_thickness(s.re, s.ref_chord)
    gaps = []
    for i in range(len(elements)):
        for j in range(i + 1, len(elements)):
            a, b = elements[i], elements[j]
            d = np.min(np.linalg.norm(a[:, None, :] - b[None, :, :], axis=2))
            gaps.append(float(d))
    min_gap = min(gaps) if gaps else np.inf
    thickness = min(thickness, s.max_layer_fraction_of_gap * min_gap)
    n_layers = layers_for(first, s.growth, thickness)
    if n_layers < 10:  # fewer and the boundary layer in the slot is not resolved
        raise EngineError(f"the slot is too narrow for wall layers ({min_gap * 1000:.2f} mm leaves room for {n_layers})",
                          "open the gap")

    gmsh.initialize(interruptible=False)
    try:
        gmsh.option.setNumber("General.Terminal", 0)
        gmsh.model.add("wing")
        geo = gmsh.model.geo
        loops, wall_curves, te_points, surface_counts = [], [], [], []
        for e, xy in enumerate(elements):
            suction, pressure = trans[e]
            if inverted[e]:  # the suction side of an inverted element is its second (lower) half
                suction, pressure = pressure, suction
            nodes = _surface_nodes(xy, chords[e], suction, pressure, s)
            gap = np.linalg.norm(nodes[0] - nodes[-1])
            sharp = gap < 1e-4 * chords[e]
            if sharp:
                nodes = nodes[:-1]
            tags = [geo.addPoint(x, y, 0) for x, y in nodes]
            curves = [geo.addLine(tags[k], tags[k + 1]) for k in range(len(tags) - 1)]
            curves.append(geo.addLine(tags[-1], tags[0]))  # the trailing edge face, or closing a sharp edge
            loops.append(geo.addCurveLoop(curves))
            wall_curves.append(curves)
            te_points += [tags[0]] if sharp else [tags[0], tags[-1]]
            # Other sharp convex corners (a slat cusp, the lip of a cove) need
            # a fan too, or the wall layers leave a hole gmsh cannot close.
            te_points += [tags[k] for k in _convex_corners(nodes, closed=sharp) if k != 0 and k != len(nodes) - 1]
            surface_counts.append(len(nodes))
        centre = np.mean(np.vstack(elements), axis=0)
        r = s.farfield * s.ref_chord
        c0 = geo.addPoint(centre[0], centre[1], 0)
        floor = []
        if s.ground is None:
            ring = [geo.addPoint(centre[0] + r * np.cos(t), centre[1] + r * np.sin(t), 0) for t in (0, np.pi / 2, np.pi, 1.5 * np.pi)]
            arcs = [geo.addCircleArc(ring[k], c0, ring[(k + 1) % 4]) for k in range(4)]
            outer = geo.addCurveLoop(arcs)
        else:
            # The circle cut by the ground: arcs over the top, a flat floor under the wing.
            depth = s.ground - centre[1]
            half = float(np.sqrt(r * r - depth * depth))
            right = geo.addPoint(centre[0] + half, s.ground, 0)
            top = geo.addPoint(centre[0], centre[1] + r, 0)
            left = geo.addPoint(centre[0] - half, s.ground, 0)
            arcs = [geo.addCircleArc(right, c0, top), geo.addCircleArc(top, c0, left)]
            floor = [geo.addLine(left, right)]
            outer = geo.addCurveLoop(arcs + floor)
        surface = geo.addPlaneSurface([outer] + loops)
        geo.synchronize()
        # Each wall segment gets exactly one cell along it: the spacing is ours.
        for curves in wall_curves:
            for cv in curves:
                gmsh.model.mesh.setTransfiniteCurve(cv, 2)
        for e, curves in enumerate(wall_curves):
            gmsh.model.addPhysicalGroup(1, curves, name=f"wall_{e}")
        gmsh.model.addPhysicalGroup(1, arcs, name="farfield")
        if floor:
            gmsh.model.addPhysicalGroup(1, floor, name="ground")
        gmsh.model.addPhysicalGroup(2, [surface], name="fluid")

        fld = gmsh.model.mesh.field
        bl = fld.add("BoundaryLayer")
        fld.setNumbers(bl, "CurvesList", [c for cs in wall_curves for c in cs])
        fld.setNumber(bl, "Size", first)
        fld.setNumber(bl, "Ratio", s.growth)
        fld.setNumber(bl, "Thickness", thickness)
        fld.setNumber(bl, "Quads", 1)
        fld.setNumbers(bl, "FanPointsList", te_points)
        fld.setAsBoundaryLayer(bl)

        # Size away from the walls: surface spacing near the body, growing
        # with distance; finer along each wake.
        dist = fld.add("Distance")
        fld.setNumbers(dist, "CurvesList", [c for cs in wall_curves for c in cs])
        near = fld.add("Threshold")
        fld.setNumber(near, "InField", dist)
        fld.setNumber(near, "SizeMin", s.surface_coarse * min(chords))
        fld.setNumber(near, "SizeMax", s.farfield_size * s.ref_chord)
        fld.setNumber(near, "DistMin", thickness * 1.5)
        fld.setNumber(near, "DistMax", 0.5 * s.farfield * s.ref_chord)
        fld.setNumber(near, "Sigmoid", 0)
        wakes = []
        al = np.radians(s.alpha_deg)
        direction = np.array([np.cos(al), np.sin(al)])
        for xy in elements:
            te = 0.5 * (xy[0] + xy[-1])
            pts = [te + direction * s.ref_chord * s.wake_length * t for t in np.linspace(0, 1, 40)]
            ptags = [geo.addPoint(p[0], p[1], 0) for p in pts]
            gmsh.model.geo.synchronize()
            w = fld.add("Distance")
            fld.setNumbers(w, "PointsList", ptags)
            th = fld.add("Threshold")
            fld.setNumber(th, "InField", w)
            fld.setNumber(th, "SizeMin", s.wake_size * s.ref_chord)
            fld.setNumber(th, "SizeMax", s.farfield_size * s.ref_chord)
            fld.setNumber(th, "DistMin", 0.05 * s.ref_chord)
            fld.setNumber(th, "DistMax", 2.0 * s.ref_chord)
            wakes.append(th)
        mins = fld.add("Min")
        fld.setNumbers(mins, "FieldsList", [near] + wakes)
        fld.setAsBackgroundMesh(mins)
        gmsh.option.setNumber("Mesh.MeshSizeExtendFromBoundary", 0)
        gmsh.option.setNumber("Mesh.MeshSizeFromPoints", 0)
        gmsh.option.setNumber("Mesh.MeshSizeFromCurvature", 0)
        gmsh.option.setNumber("Mesh.Algorithm", 6)  # Frontal-Delaunay triangles outside the layers
        gmsh.model.mesh.generate(2)
        # (no removeDuplicateNodes: it collapses the trailing edge fan into zero-area cells)
        # The extra wake points are not part of the geometry's boundaries: drop them.
        types, tags, _ = gmsh.model.mesh.getElements(2)
        counts = {gmsh.model.mesh.getElementProperties(t)[0]: len(tg) for t, tg in zip(types, tags)}
        out.parent.mkdir(parents=True, exist_ok=True)
        gmsh.option.setNumber("Mesh.SaveAll", 0)
        gmsh.write(str(out))
        q = gmsh.model.mesh.getElementQualities(np.concatenate(tags).astype(np.int64).tolist(), "minSICN")
    finally:
        gmsh.finalize()
    tri = sum(v for k, v in counts.items() if "Triangle" in k)
    quad = sum(v for k, v in counts.items() if "Quadrilateral" in k)
    if tri + quad == 0:
        raise EngineError("gmsh produced no cells")
    return {
        "file": out.name, "cells": int(tri + quad), "triangles": int(tri), "quads": int(quad),
        "first_cell_height_m": float(first), "layer_thickness_m": float(thickness), "layers": int(n_layers),
        "min_gap_m": float(min_gap) if np.isfinite(min_gap) else None, "surface_nodes": surface_counts,
        "min_quality": float(np.min(q)), "bad_cells": int(np.sum(np.asarray(q) <= 0)),
    }
