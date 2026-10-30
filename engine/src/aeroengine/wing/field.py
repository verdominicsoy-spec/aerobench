"""The flow around the wing for the app's field view: SU2's solution
resampled onto a regular grid (linear on SU2's own cells, so nothing is
interpolated across an element or a slot), a few scalars, and streamlines.

Written as field.json (sizes, window, scalars with their ranges and
colormaps, streamlines) and field.bin (float32, little-endian, one nx * ny
block per scalar in the order listed, rows from the bottom; NaN inside the
elements and outside the mesh)."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np

SCALARS = [  # key, name, colormap
    ("cp", "Pressure coefficient Cp", "diverging"),
    ("speed", "Speed V/V∞", "sequential"),
    ("cp0", "Total pressure Cp0", "sequential"),
    ("nut", "Eddy viscosity ratio μt/μ", "sequential"),
]


def _colormap(kind: str, n: int = 64) -> list[list[float]]:
    """Blue-white-red for Cp (zero in the middle when the range allows it),
    and a dark-to-bright ramp for the rest."""
    t = np.linspace(0, 1, n)
    if kind == "diverging":
        blue, white, red = np.array([0.23, 0.30, 0.75]), np.array([0.95, 0.95, 0.95]), np.array([0.71, 0.02, 0.15])
        rgb = [blue + (white - blue) * (2 * s) if s < 0.5 else white + (red - white) * (2 * s - 1) for s in t]
    else:  # viridis-like, from its endpoints and midpoints
        stops = np.array([[0.27, 0.00, 0.33], [0.23, 0.32, 0.55], [0.13, 0.57, 0.55], [0.37, 0.79, 0.38], [0.99, 0.91, 0.14]])
        pos = np.linspace(0, 1, len(stops))
        rgb = np.column_stack([np.interp(t, pos, stops[:, k]) for k in range(3)])
    return np.round(np.asarray(rgb), 4).tolist()


def _read_vtu(path: Path):
    import vtk
    from vtk.util.numpy_support import vtk_to_numpy

    reader = vtk.vtkXMLUnstructuredGridReader()
    reader.SetFileName(str(path))
    reader.Update()
    grid = reader.GetOutput()
    if grid.GetNumberOfPoints() == 0:
        raise ValueError(f"{path.name} holds no points")
    pts = vtk_to_numpy(grid.GetPoints().GetData())[:, :2].astype(float)
    conn = vtk_to_numpy(grid.GetCells().GetConnectivityArray())
    offsets = vtk_to_numpy(grid.GetCells().GetOffsetsArray())
    tris = []
    for a, b in zip(offsets[:-1], offsets[1:]):
        c = conn[a:b]
        if len(c) == 3:
            tris.append(c)
        elif len(c) == 4:  # a quad as two triangles
            tris += [c[[0, 1, 2]], c[[0, 2, 3]]]
    data = grid.GetPointData()
    arrays = {data.GetArrayName(i): vtk_to_numpy(data.GetArray(i)) for i in range(data.GetNumberOfArrays())}
    return pts, np.array(tris, dtype=np.int64), arrays


def extract(vtu: Path, placed: list[np.ndarray], out_dir: Path, nx: int = 640) -> dict:
    """Resamples the solution in vtu around the elements (placed outlines,
    m) and writes field.json and field.bin in out_dir. Returns the header."""
    import matplotlib.tri as mtri

    pts, tris, arrays = _read_vtu(vtu)
    # Free-stream speed: the velocity far from the wing (SU2's far field holds it).
    vel = arrays["Velocity"][:, :2].astype(float)
    centre = np.mean(np.vstack(placed), axis=0)
    far = np.linalg.norm(pts - centre, axis=1)
    v_inf = float(np.median(np.linalg.norm(vel[far > 0.9 * far.max()], axis=1)))

    allp = np.vstack(placed)
    lo, hi = allp.min(axis=0), allp.max(axis=0)
    span = float(max(hi[0] - lo[0], hi[1] - lo[1]))
    x0, x1 = lo[0] - 0.3 * span, hi[0] + 0.8 * span
    y0, y1 = lo[1] - 0.4 * span, hi[1] + 0.4 * span
    ny = max(int(round(nx * (y1 - y0) / (x1 - x0))), 8)
    xs = x0 + (np.arange(nx) + 0.5) * (x1 - x0) / nx
    ys = y0 + (np.arange(ny) + 0.5) * (y1 - y0) / ny
    gx, gy = np.meshgrid(xs, ys)

    tri = mtri.Triangulation(pts[:, 0], pts[:, 1], tris)
    finder = tri.get_trifinder()

    def sample(values: np.ndarray) -> np.ndarray:
        z = mtri.LinearTriInterpolator(tri, values.astype(float), trifinder=finder)(gx, gy)
        return np.ma.filled(z.astype(float), np.nan)

    # Blank the elements themselves, whatever the cells say.
    from matplotlib.path import Path as Outline

    solid = np.zeros(gx.shape, bool)
    flat = np.column_stack([gx.ravel(), gy.ravel()])
    for xy in placed:
        solid |= Outline(xy).contains_points(flat).reshape(gx.shape)

    cp = sample(arrays["Pressure_Coefficient"]) if "Pressure_Coefficient" in arrays else 2 * sample(arrays["Pressure"])
    u, v = sample(vel[:, 0]) / v_inf, sample(vel[:, 1]) / v_inf
    speed = np.hypot(u, v)
    fields = {"cp": cp, "speed": speed, "cp0": cp + speed**2 - 1}  # total pressure, incompressible
    if "Eddy_Viscosity" in arrays and "Laminar_Viscosity" in arrays:
        fields["nut"] = sample(arrays["Eddy_Viscosity"] / np.maximum(arrays["Laminar_Viscosity"], 1e-30))
    for f in fields.values():
        f[solid] = np.nan
    u[solid] = np.nan
    v[solid] = np.nan

    scalars = []
    blocks = []
    for key, name, kind in SCALARS:
        if key not in fields:
            continue
        f = fields[key]
        finite = f[np.isfinite(f)]
        lo_v, hi_v = (float(np.percentile(finite, 1)), float(np.percentile(finite, 99))) if finite.size else (0.0, 1.0)
        if key == "cp":  # keep Cp's zero in the middle of its colormap
            m = max(abs(lo_v), abs(hi_v))
            lo_v, hi_v = -m, m
        if key == "cp0":  # losses only: free stream is 0, wakes are negative
            hi_v = 0.0
        scalars.append({"key": key, "name": name, "min": float(np.nanmin(f)) if finite.size else 0.0,
                        "max": float(np.nanmax(f)) if finite.size else 0.0, "range": [lo_v, hi_v],
                        "colormap": _colormap(kind)})
        blocks.append(f.astype("<f4"))

    lines = _streamlines(xs, ys, u, v, placed, span)
    header = {"nx": nx, "ny": ny, "window": [float(x0), float(y0), float(x1), float(y1)], "v_inf": v_inf,
              "scalars": scalars, "streamlines": [np.round(np.vstack([l[::4], l[-1:]]), 4).tolist() for l in lines]}
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "field.bin").write_bytes(b"".join(b.tobytes() for b in blocks))
    (out_dir / "field.json").write_text(json.dumps(header))
    return header


def _streamlines(xs: np.ndarray, ys: np.ndarray, u: np.ndarray, v: np.ndarray, placed: list[np.ndarray],
                 span: float) -> list[np.ndarray]:
    """Streamlines from evenly spaced seeds upstream, plus seeds just behind
    each trailing edge traced both ways, so slot flow and any recirculation
    behind an element show up."""
    dx, dy = xs[1] - xs[0], ys[1] - ys[0]
    h = 0.5 * min(dx, dy)

    def velocity(p: np.ndarray) -> np.ndarray | None:
        fx, fy = (p[0] - xs[0]) / dx, (p[1] - ys[0]) / dy
        i, j = int(np.floor(fx)), int(np.floor(fy))
        if not (0 <= i < len(xs) - 1 and 0 <= j < len(ys) - 1):
            return None
        tx, ty = fx - i, fy - j
        w = np.array([(1 - tx) * (1 - ty), tx * (1 - ty), (1 - tx) * ty, tx * ty])
        uu = np.array([u[j, i], u[j, i + 1], u[j + 1, i], u[j + 1, i + 1]])
        vv = np.array([v[j, i], v[j, i + 1], v[j + 1, i], v[j + 1, i + 1]])
        if not (np.all(np.isfinite(uu)) and np.all(np.isfinite(vv))):
            return None
        vec = np.array([w @ uu, w @ vv])
        n = np.linalg.norm(vec)
        return vec / n if n > 1e-6 else None

    def trace(seed: np.ndarray, sign: float, steps: int) -> list[np.ndarray]:
        p, out = seed.copy(), [seed.copy()]
        for _ in range(steps):
            k1 = velocity(p)
            if k1 is None:
                break
            k2 = velocity(p + sign * 0.5 * h * k1)
            if k2 is None:
                break
            p = p + sign * h * k2
            out.append(p.copy())
        return out

    steps = int(4 * (xs[-1] - xs[0]) / h)
    lines = []
    for y in np.linspace(ys[0] + 0.03 * (ys[-1] - ys[0]), ys[-1] - 0.03 * (ys[-1] - ys[0]), 36):
        line = trace(np.array([xs[1], y]), 1.0, steps)
        if len(line) > 4:
            lines.append(np.array(line))
    for xy in placed:
        te = 0.5 * (xy[0] + xy[-1])
        for off in np.linspace(-0.04, 0.04, 5) * span:
            seed = te + np.array([0.01 * span, off])
            back = trace(seed, -1.0, steps // 4)[::-1]
            fwd = trace(seed, 1.0, steps)
            line = back + fwd[1:]
            if len(line) > 4:
                lines.append(np.array(line))
    return lines
