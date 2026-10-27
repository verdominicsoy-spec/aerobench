"""Isosurfaces by marching cubes, and volume export to VTK."""

from __future__ import annotations

from pathlib import Path

import numpy as np
from scipy.ndimage import gaussian_filter
from skimage.measure import marching_cubes

from ..cad.meshio import Mesh, vertex_normals
from .reconstruct import Volume


def isosurface(vol: Volume, level: float, fill: float | None = None) -> Mesh:
    """Surface where the field equals `level`. Empty voxels (geometry,
    background) are filled with `fill`, by default the top of the range, so
    surfaces close around bodies instead of stopping at holes."""
    fill = vol.vmax if fill is None else fill
    v = np.where(np.isnan(vol.values), fill, vol.values).astype(np.float32)
    if not (v.min() < level < v.max()):
        return Mesh(np.zeros((0, 3), np.float32), np.zeros((0, 3), np.float32), np.zeros((0, 3), np.uint32), f"Cp0 = {level:g}")
    # Pad with the fill value so surfaces close at the edges of the volume.
    # The pad layer maps onto the boundary coordinate, so caps lie exactly on
    # the first and last plane.
    v = np.pad(v, 1, constant_values=fill)
    verts, faces, _, _ = marching_cubes(v, level)
    pos = np.empty_like(verts, dtype=np.float64)
    for axis, coords in enumerate((vol.x, vol.y, vol.z)):
        padded = np.concatenate([[coords[0]], coords, [coords[-1]]])
        pos[:, axis] = np.interp(verts[:, axis], np.arange(len(padded)), padded)
    idx = faces.astype(np.uint32)
    return Mesh(pos.astype(np.float32), vertex_normals(pos, idx), idx, f"Cp0 = {level:g}")


def _mesh_from_field(field: np.ndarray, level: float, pad: float, vol: Volume, name: str) -> Mesh:
    field = np.pad(field.astype(np.float32), 1, constant_values=pad)
    verts, faces, _, _ = marching_cubes(field, level)
    pos = np.empty_like(verts, dtype=np.float64)
    for axis, coords in enumerate((vol.x, vol.y, vol.z)):
        padded = np.concatenate([[coords[0]], coords, [coords[-1]]])
        pos[:, axis] = np.interp(verts[:, axis], np.arange(len(padded)), padded)
    idx = faces.astype(np.uint32)
    return Mesh(pos.astype(np.float32), vertex_normals(pos, idx), idx, name)


def object_surface(vol: Volume, ground_z: float | None = 0.0, smooth: float = 1.0) -> Mesh:
    """The no-fluid region (where the video showed geometry colours) as a
    closed surface. Everything at or below `ground_z` is ignored so the white
    below the ground plane does not show up as a slab; None keeps it."""
    if vol.solid is None:
        from ..job import EngineError

        raise EngineError("this volume has no geometry mask", "reconstruct it again to show the object")
    occ = vol.solid.astype(np.float32)
    # The outermost layer in y and z samples the crop boundary, which can
    # catch white margins around the plot; it is never trustworthy geometry.
    occ[:, [0, -1], :] = 0
    occ[:, :, [0, -1]] = 0
    if ground_z is not None:
        occ[:, :, vol.z <= ground_z + 0.5 * (vol.z[1] - vol.z[0])] = 0
    if smooth > 0:
        occ = gaussian_filter(occ, smooth)
    if occ.max() <= 0.5:
        return Mesh(np.zeros((0, 3), np.float32), np.zeros((0, 3), np.float32), np.zeros((0, 3), np.uint32), "Object")
    return _mesh_from_field(occ, 0.5, 0.0, vol, "Object")


def enclosed_volume(mesh: Mesh) -> float:
    """Volume inside a closed mesh, by the divergence theorem."""
    p = mesh.positions.astype(np.float64)[mesh.indices]
    return float(abs(np.einsum("ij,ij->i", p[:, 0], np.cross(p[:, 1], p[:, 2])).sum()) / 6)


def write_vti(vol: Volume, path: Path, name: str = "Cp0") -> None:
    """VTK ImageData with raw appended float32 data. ImageData needs even
    spacing, so uneven plane positions are resampled along x first."""
    x = vol.x
    values = vol.values
    if not np.allclose(np.diff(x), x[1] - x[0], rtol=1e-6):
        xu = np.linspace(x[0], x[-1], len(x))
        values = np.stack([[np.interp(xu, x, values[:, j, k]) for k in range(values.shape[2])]
                           for j in range(values.shape[1])]).transpose(2, 0, 1)
        x = xu
    nx, ny, nz = values.shape
    data = np.ascontiguousarray(values.transpose(2, 1, 0), dtype="<f4").tobytes()  # x fastest
    dx, dy, dz = x[1] - x[0], vol.y[1] - vol.y[0], vol.z[1] - vol.z[0]
    head = (
        '<?xml version="1.0"?>\n'
        '<VTKFile type="ImageData" version="1.0" byte_order="LittleEndian" header_type="UInt64">\n'
        f'  <ImageData WholeExtent="0 {nx - 1} 0 {ny - 1} 0 {nz - 1}" '
        f'Origin="{x[0]:.9g} {vol.y[0]:.9g} {vol.z[0]:.9g}" Spacing="{dx:.9g} {dy:.9g} {dz:.9g}">\n'
        f'    <Piece Extent="0 {nx - 1} 0 {ny - 1} 0 {nz - 1}">\n'
        f'      <PointData Scalars="{name}">\n'
        f'        <DataArray type="Float32" Name="{name}" format="appended" offset="0"/>\n'
        "      </PointData>\n    </Piece>\n  </ImageData>\n"
        '  <AppendedData encoding="raw">\n   _'
    ).encode()
    with open(path, "wb") as f:
        f.write(head)
        f.write(np.uint64(len(data)).tobytes())
        f.write(data)
        f.write(b"\n  </AppendedData>\n</VTKFile>\n")
