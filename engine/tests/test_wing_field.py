"""The field view: SU2's solution resampled onto a grid, without SU2 (a
small vtu written here stands in for flow.vtu)."""

from __future__ import annotations

import json

import numpy as np
import pytest

vtk = pytest.importorskip("vtk")


def _write_vtu(path, element):
    """A triangulated square around `element` (a closed outline, left as a
    hole) holding a linear Cp and a uniform flow along x."""
    from scipy.spatial import Delaunay
    from vtk.util.numpy_support import numpy_to_vtk, numpy_to_vtkIdTypeArray
    from matplotlib.path import Path as Outline

    g = np.linspace(-2, 3, 41)
    pts = np.array([[x, y] for x in g for y in np.linspace(-2, 2, 33)])
    pts = pts[~Outline(element).contains_points(pts)]
    pts = np.vstack([pts, element[:-1]])
    tri = Delaunay(pts).simplices
    centres = pts[tri].mean(axis=1)
    tri = tri[~Outline(element).contains_points(centres)]  # no cells inside the element

    grid = vtk.vtkUnstructuredGrid()
    points = vtk.vtkPoints()
    points.SetData(numpy_to_vtk(np.column_stack([pts, np.zeros(len(pts))]), deep=True))
    grid.SetPoints(points)
    cells = vtk.vtkCellArray()
    offsets = np.arange(0, 3 * len(tri) + 1, 3, dtype=np.int64)
    tri = tri.astype(np.int64)
    cells.SetData(numpy_to_vtkIdTypeArray(offsets, deep=True), numpy_to_vtkIdTypeArray(tri.ravel(), deep=True))
    grid.SetCells(vtk.VTK_TRIANGLE, cells)

    def add(name, values):
        a = numpy_to_vtk(np.ascontiguousarray(values), deep=True)
        a.SetName(name)
        grid.GetPointData().AddArray(a)

    add("Pressure_Coefficient", 0.1 * pts[:, 0] - 0.2 * pts[:, 1])
    add("Velocity", np.column_stack([np.full(len(pts), 2.0), np.zeros(len(pts)), np.zeros(len(pts))]))
    add("Eddy_Viscosity", np.full(len(pts), 3e-5))
    add("Laminar_Viscosity", np.full(len(pts), 1e-5))
    w = vtk.vtkXMLUnstructuredGridWriter()
    w.SetFileName(str(path))
    w.SetInputData(grid)
    w.Write()


def test_field_is_resampled_masked_and_traced(tmp_path):
    from aeroengine.wing.field import extract

    square = np.array([[0, 0], [1, 0], [1, 0.3], [0, 0.3], [0, 0]], float)
    _write_vtu(tmp_path / "flow.vtu", square)
    h = extract(tmp_path / "flow.vtu", [square], tmp_path / "out", nx=200)
    assert json.loads((tmp_path / "out" / "field.json").read_text())["nx"] == 200
    keys = [s["key"] for s in h["scalars"]]
    assert keys == ["cp", "speed", "cp0", "nut"]
    raw = np.fromfile(tmp_path / "out" / "field.bin", "<f4").reshape(len(keys), h["ny"], h["nx"])
    x0, y0, x1, y1 = h["window"]
    xs = x0 + (np.arange(h["nx"]) + 0.5) * (x1 - x0) / h["nx"]
    ys = y0 + (np.arange(h["ny"]) + 0.5) * (y1 - y0) / h["ny"]
    gx, gy = np.meshgrid(xs, ys)
    cp = raw[0]
    ok = np.isfinite(cp)
    # Linear data is reproduced exactly by linear interpolation.
    assert np.allclose(cp[ok], (0.1 * gx - 0.2 * gy)[ok], atol=1e-5)
    # Free stream found from the far field; speed is relative to it.
    assert h["v_inf"] == pytest.approx(2.0)
    assert np.allclose(raw[1][ok], 1.0, atol=1e-5)
    # Cp0 = Cp + (V/V_inf)^2 - 1 in incompressible flow; eddy viscosity ratio 3.
    assert np.allclose(raw[2][ok], cp[ok], atol=1e-5) and np.allclose(raw[3][ok], 3.0, atol=1e-4)
    # Nothing inside the element.
    inside = (gx > 0.02) & (gx < 0.98) & (gy > 0.02) & (gy < 0.28)
    assert inside.any() and not np.isfinite(cp[inside]).any()
    # Streamlines in a uniform flow along x stay level.
    assert len(h["streamlines"]) > 10
    for line in h["streamlines"][:5]:
        line = np.array(line)
        assert np.ptp(line[:, 1]) < 1e-6 and line[-1, 0] > line[0, 0]
