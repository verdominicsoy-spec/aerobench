"""Frames to a 3D volume.

Each selected frame is resampled onto one common grid in the image plane
(h right, v up, in metres), then colour-inverted. Resampling first means a
perspective video, where every frame has its own pixel scale, stacks into a
consistent volume. The result is then laid out in world x, y, z using the
calibration's view axes.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator

import cv2
import numpy as np
from scipy.ndimage import distance_transform_edt, median_filter

from ..job import EngineError
from . import colormap
from .calibration import Calibration

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp"}


class FrameSource:
    """A video file or a folder of images, read as RGB uint8."""

    def __init__(self, path: Path | str) -> None:
        path = Path(path)
        self.path = path
        if path.is_dir():
            self.images = sorted(p for p in path.iterdir() if p.suffix.lower() in IMAGE_EXTS)
            if not self.images:
                raise EngineError(f"no images in {path}")
            self.count = len(self.images)
            first = self._image(0)
            self.size = (first.shape[1], first.shape[0])
        elif path.is_file():
            self.images = None
            cap = cv2.VideoCapture(str(path))
            if not cap.isOpened():
                raise EngineError(f"could not open video {path.name}")
            self.count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
            self.size = (int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)))
            cap.release()
            if self.count < 2:
                raise EngineError(f"{path.name} has fewer than two frames")
        else:
            raise EngineError(f"not found: {path}")

    def _image(self, i: int) -> np.ndarray:
        img = cv2.imread(str(self.images[i]), cv2.IMREAD_COLOR)
        if img is None:
            raise EngineError(f"could not read {self.images[i].name}")
        return img[:, :, ::-1]

    def frames(self, indices: list[int]) -> Iterator[tuple[int, np.ndarray]]:
        if self.images is not None:
            for i in indices:
                yield i, self._image(i)
            return
        wanted = set(indices)
        cap = cv2.VideoCapture(str(self.path))
        i = 0
        last = max(indices)
        while i <= last:
            if i in wanted:
                ok, frame = cap.read()
                if not ok:
                    break
                yield i, frame[:, :, ::-1]
            elif not cap.grab():
                break
            i += 1
        cap.release()

    def frame(self, index: int) -> np.ndarray:
        for _, f in self.frames([index]):
            return f
        raise EngineError(f"could not read frame {index}")


@dataclass
class Volume:
    values: np.ndarray  # (nx, ny, nz) float32 in world x, y, z order, NaN where empty
    x: np.ndarray  # coordinates along each axis, increasing (the sweep axis may be uneven)
    y: np.ndarray
    z: np.ndarray
    frames: list[int]  # source frame of each plane along the sweep axis
    vmin: float
    vmax: float
    colormap_rgb: np.ndarray  # (n, 3) 0..1, low to high
    solid: np.ndarray | None = None  # same shape, uint8, 1 where a mask colour (geometry) was seen
    sweep_axis: str = "x"
    right: str = "+y"  # world axis pointing right in the frames
    up: str = "+z"  # world axis pointing up in the frames

    def save(self, folder: Path, calibration: dict, source: str) -> dict:
        extra = {} if self.solid is None else {"solid": self.solid.astype(np.uint8)}
        np.savez_compressed(folder / "volume.npz", values=self.values, x=self.x, y=self.y, z=self.z,
                            frames=np.asarray(self.frames), value_range=np.array([self.vmin, self.vmax]),
                            colormap=self.colormap_rgb, calibration=json.dumps(calibration), source=source,
                            axes=np.array([self.sweep_axis, self.right, self.up]), **extra)
        self.values.astype("<f4").tofile(folder / "volume.bin")
        meta = {
            "shape": list(self.values.shape),
            "order": "x, y, z; z fastest; little-endian float32; NaN is empty",
            "x": self.x.tolist(),
            "y": self.y.tolist(),
            "z": self.z.tolist(),
            # Kept for readers of the first format (sweep along x, even y and z).
            "y0": float(self.y[0]), "dy": float(self.y[1] - self.y[0]),
            "z0": float(self.z[0]), "dz": float(self.z[1] - self.z[0]),
            "sweep_axis": self.sweep_axis,
            "right": self.right,
            "up": self.up,
            "frames": self.frames,
            "value_range": [self.vmin, self.vmax],
            "colormap": np.round(self.colormap_rgb[:: max(len(self.colormap_rgb) // 64, 1)], 4).tolist(),
            "units": "m",
            "has_solid": self.solid is not None,
        }
        (folder / "volume.json").write_text(json.dumps(meta))
        return meta

    @classmethod
    def load(cls, npz: Path) -> "Volume":
        d = np.load(npz, allow_pickle=False)
        vr = d["value_range"]
        solid = d["solid"] if "solid" in d.files else None
        sweep, right, up = (str(a) for a in d["axes"]) if "axes" in d.files else ("x", "+y", "+z")
        return cls(d["values"], d["x"], d["y"], d["z"], d["frames"].tolist(), float(vr[0]), float(vr[1]),
                   d["colormap"], solid, sweep, right, up)


def build_lut(cal: Calibration, source: FrameSource) -> colormap.ColorLUT:
    cm = cal.colormap
    if "legend" in cm:
        leg = cm["legend"]
        frame = source.frame(int(leg.get("frame", 0)))
        rgb = colormap.sample_legend(frame, leg["p0"], leg["p1"], int(leg.get("half_width", 3)), float(leg.get("smooth", 0.03)))
    else:
        rgb = colormap.preset(cm["preset"])
    return colormap.ColorLUT(rgb, cal.vmin, cal.vmax)


def world_grid(cal: Calibration, frames: list[int], width: int) -> tuple[np.ndarray, np.ndarray]:
    """The h (right), v (up) grid: the crop's extent over the selected frames
    (everything seen, or only what every frame sees, or the given window).
    Spacing follows `detail` (about 1.5 pixels of the sharpest frame, capped
    by a voxel budget) or else `width` samples across."""
    x0, y0, x1, y1 = cal.crop
    boxes, scales = [], []
    for f in frames:
        s = cal.scale_at(f)
        scales.append(s.sx)
        boxes.append(((x0 - s.cu) / s.sx, (x1 - s.cu) / s.sx, (s.cv - y1) / s.sy, (s.cv - y0) / s.sy))
    b = np.array(boxes)
    if cal.window is not None:
        r0, r1, u0, u1 = cal.window  # world right / up coordinates
        h = sorted((cal.right[0] * r0, cal.right[0] * r1))
        v = sorted((cal.up[0] * u0, cal.up[0] * u1))
        ylo, yhi, zlo, zhi = h[0], h[1], v[0], v[1]
    elif cal.extent == "all":
        ylo, yhi, zlo, zhi = b[:, 0].min(), b[:, 1].max(), b[:, 2].min(), b[:, 3].max()
    else:
        ylo, yhi, zlo, zhi = b[:, 0].max(), b[:, 1].min(), b[:, 2].max(), b[:, 3].min()
    if not (yhi > ylo and zhi > zlo):
        raise EngineError("the crop region does not overlap between the first and last frame",
                          "check the spatial calibration points")
    if cal.detail is not None:
        from .calibration import DETAIL_CAPS

        finest = 1.5 / max(scales)  # metres per cell at about 1.5 px of the sharpest frame
        budget = (yhi - ylo) * (zhi - zlo) * len(frames) / DETAIL_CAPS[cal.detail]
        cell = max(finest, float(np.sqrt(budget)))
        width = max(int(round((yhi - ylo) / cell)) + 1, 16)
    y = np.linspace(ylo, yhi, width)
    dy = y[1] - y[0]
    if cal.track_ground and cal.window is None:
        # The crop reaches below the ground so it can be tracked; nothing
        # there is fluid, so do not spend cells on it.
        zlo = max(zlo, cal.ground_level - 4 * dy)
    z = np.arange(zlo, zhi + dy / 2, dy)
    return y, z


# --- Ground tracking --------------------------------------------------------

def detect_ground_row(frame: np.ndarray, cal: Calibration) -> float:
    """Where the ground (a mask colour, white by default) starts, scanning up
    from the bottom of the crop: the median over columns that have ground at
    the bottom, in continuous pixel rows. NaN if too few columns do."""
    x0, y0, x1, y1 = cal.crop
    h, w = frame.shape[:2]
    y0, y1 = max(y0, 0), min(y1, h)
    cols = np.arange(max(x0, 0), min(x1, w), 4)
    for ex0, ey0, ex1, ey1 in cal.exclude:  # columns crossing an exclusion box are unreliable
        cols = cols[~((cols >= ex0) & (cols < ex1) & (ey1 > y0) & (ey0 < y1))]
    if len(cols) < 8:
        return float("nan")
    strip = frame[y0:y1][:, cols]
    mask = np.zeros(strip.shape[:2], bool)
    for c in cal.mask_colors:
        mask |= colormap.lab_distance(strip, c) < cal.mask_tolerance
    valid = mask[-1]
    above = ~mask[::-1]  # from the bottom up
    first = np.where(above.any(axis=0), above.argmax(axis=0), mask.shape[0])
    ok = valid & (first < mask.shape[0])
    if ok.sum() < 0.15 * len(cols):
        return float("nan")
    return float(y0 + mask.shape[0] - np.median(first[ok]))


def fit_ground(frames: np.ndarray, rows: np.ndarray):
    """Fits row = vh + K / (a + d * frame), a pinhole camera with the plane
    moving at constant speed (d = +1 away from the camera, -1 towards it).
    Returns ("constant", median row), or ("pinhole", (vh, K, a, d), residuals)."""
    from scipy.optimize import least_squares

    ok = np.isfinite(rows)
    f, r = frames[ok].astype(float), rows[ok]
    if len(f) < 4:
        raise EngineError("the ground line was found in too few frames to track it",
                          "extend the crop a little below the ground, or turn ground tracking off and calibrate two frames")
    if r.max() - r.min() < 1.5:
        return "constant", float(np.median(r)), r - np.median(r)
    d = 1.0 if r[np.argmax(f)] < r[np.argmin(f)] else -1.0
    span = f.max() - f.min()
    best = None
    for a0 in span * np.array([0.1, 0.3, 1, 3, 10]) - d * (f.min() if d > 0 else f.max()):
        g = 1.0 / (a0 + d * f)
        if np.any(a0 + d * f <= 0):
            continue
        A = np.stack([np.ones_like(g), g], 1)
        (vh0, k0), *_ = np.linalg.lstsq(A, r, rcond=None)
        res = least_squares(lambda p: p[0] + p[1] / (p[2] + d * f) - r, [vh0, k0, a0], loss="soft_l1", f_scale=2.0)
        if np.all(res.x[2] + d * f > 0) and (best is None or res.cost < best.cost):
            best = res
    if best is None:
        raise EngineError("could not fit a perspective camera to the ground line")
    vh, k, a = best.x
    return "pinhole", (float(vh), float(k), float(a), int(d)), r - (vh + k / (a + d * f))


def track_ground(source: "FrameSource", cal: Calibration, frames: list[int], samples: int = 60) -> dict:
    """Detects the ground in up to `samples` evenly spread frames, fits the
    camera and stores the result on the calibration."""
    pick = sorted(set(np.linspace(0, len(frames) - 1, min(samples, len(frames))).round().astype(int)))
    chosen = [frames[i] for i in pick]
    found = {i: detect_ground_row(fr, cal) for i, fr in source.frames(chosen)}
    f = np.array(chosen)
    r = np.array([found.get(i, np.nan) for i in chosen])
    kind, fit, resid = fit_ground(f, r)
    if kind == "constant":
        cal.ground_rows = {int(i): fit for i in chosen}
        cal.ground_fit = None
    else:
        cal.ground_fit = fit
        cal.ground_rows = None
    worst = float(np.abs(resid).max())
    if np.median(np.abs(resid)) > 3:
        raise EngineError("the ground line does not follow a steady camera",
                          f"median misfit {np.median(np.abs(resid)):.1f} px; check the crop includes ground in most frames")
    return {"camera": kind, "frames_used": int(np.isfinite(r).sum()), "residual_median_px": float(np.median(np.abs(resid))),
            "residual_max_px": worst}


def _invert_slice(frame: np.ndarray, cal: Calibration, s, y: np.ndarray, z: np.ndarray,
                  lut: colormap.ColorLUT, excl: np.ndarray) -> tuple[np.ndarray, np.ndarray, dict]:
    # Pre-shrink so the grid samples about one pixel per cell (no aliasing).
    dy = y[1] - y[0]
    k = max(int(np.floor(s.sx * dy)), 1)
    if k > 1:
        small = cv2.resize(frame, (frame.shape[1] // k, frame.shape[0] // k), interpolation=cv2.INTER_AREA)
        small_ex = cv2.resize(excl, (frame.shape[1] // k, frame.shape[0] // k), interpolation=cv2.INTER_AREA)
    else:
        small, small_ex = frame, excl
    # Calibration pixels are continuous (pixel i covers [i, i+1)); remap
    # addresses pixel centres, and a k-times shrunk pixel j is centred on
    # full-size coordinate j*k + k/2.
    Y, Z = np.meshgrid(y, z, indexing="ij")
    mu = ((s.cu + s.sx * Y) / k - 0.5).astype(np.float32)
    mv = ((s.cv - s.sy * Z) / k - 0.5).astype(np.float32)
    rgb = cv2.remap(small, mu, mv, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=(255, 255, 255))
    ex = cv2.remap(small_ex, mu, mv, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=1.0) > 0.01
    values, dist = lut.invert(rgb)
    # Mask colours are geometry: no fluid there. Kept separately from other
    # empty cells (excluded, outside the frame, unrecognised colour) so the
    # object can be shown.
    solid = np.zeros(rgb.shape[:2], bool)
    for c in cal.mask_colors:
        solid |= colormap.lab_distance(rgb, c) < cal.mask_tolerance
    solid &= ~ex
    empty = ex | (dist > cal.threshold) | solid
    values = values.astype(np.float32)
    if cal.median > 1 and (~empty).any():
        # NaN-aware median: fill empty cells from their nearest neighbour,
        # filter, then empty them again.
        idx = distance_transform_edt(empty, return_distances=False, return_indices=True)
        values = median_filter(values[tuple(idx)], size=cal.median)
    values[empty] = np.nan
    stats = {"median_dE": float(np.median(dist[~empty])) if (~empty).any() else None,
             "empty_fraction": float(empty.mean())}
    return values, solid, stats


def reconstruct(source_path: Path, cal: Calibration, progress: Callable[[float, str], None] | None = None) -> tuple[Volume, dict]:
    report = progress or (lambda pct, msg: None)
    source = FrameSource(source_path)
    frames = cal.frames(source.count)
    lut = build_lut(cal, source)
    ground = None
    cal.frame_size = source.size
    if cal.track_ground:
        report(2, "tracking the ground line")
        ground = track_ground(source, cal, frames)
    h, v = world_grid(cal, frames, cal.working_width)
    excl = _exclusion_mask(cal, source.size)
    values = np.full((len(frames), len(h), len(v)), np.nan, np.float32)
    solid = np.zeros(values.shape, bool)
    pos = np.array([cal.plane_x(f, frames[0], frames[-1]) for f in frames])
    if ground is not None and cal.plane_mode != "camera":
        ground["implied_camera"] = cal.implied_camera(frames, pos, source.size)
    stats = []
    for n, (i, frame) in enumerate(source.frames(frames)):
        k = frames.index(i)
        values[k], solid[k], st = _invert_slice(frame, cal, cal.scale_at(i), h, v, lut, excl)
        stats.append(st)
        if n % 5 == 0 or n == len(frames) - 1:
            report(8 + 87 * (n + 1) / len(frames), f"plane {n + 1}/{len(frames)}")
    if len(stats) < len(frames):
        raise EngineError(f"the video ended early: read {len(stats)} of {len(frames)} frames")
    if pos[0] > pos[-1]:  # keep the sweep increasing
        values, solid, pos, frames = values[::-1].copy(), solid[::-1].copy(), pos[::-1].copy(), frames[::-1]
    if cal.window is None:
        values, solid, h, v = _trim(values, solid, h, v)
    dEs = [s["median_dE"] for s in stats if s["median_dE"] is not None]
    summary = {
        "planes": len(frames),
        "median_dE": float(np.median(dEs)) if dEs else None,
        "empty_fraction": float(np.mean([s["empty_fraction"] for s in stats])),
        "cell_mm": float((h[1] - h[0]) * 1000),
        "ground": ground,
    }
    return _to_world(cal, values, solid.astype(np.uint8), pos, h, v, frames, lut.rgb), summary


def _to_world(cal: Calibration, values, solid, pos, h, v, frames, rgb) -> Volume:
    """(sweep, h, v) arrays to world (x, y, z) with every axis increasing."""
    (rs, ra), (us, ua) = cal.right, cal.up
    if rs < 0:  # h runs against the world axis: flip so coordinates increase
        values, solid, h = values[:, ::-1], solid[:, ::-1], -h[::-1]
    else:
        h = h.copy()
    if us < 0:
        values, solid, v = values[:, :, ::-1], solid[:, :, ::-1], -v[::-1]
    else:
        v = v.copy()
    dim = {cal.sweep_axis: 0, ra: 1, ua: 2}
    order = [dim["x"], dim["y"], dim["z"]]
    coords = {cal.sweep_axis: pos, ra: h, ua: v}
    return Volume(np.ascontiguousarray(values.transpose(order)), coords["x"], coords["y"], coords["z"], list(frames),
                  cal.vmin, cal.vmax, rgb, np.ascontiguousarray(solid.transpose(order)),
                  cal.sweep_axis, f"{'+' if rs > 0 else '-'}{ra}", f"{'+' if us > 0 else '-'}{ua}")


def _trim(values: np.ndarray, solid: np.ndarray, y: np.ndarray, z: np.ndarray, margin: int = 2):
    """Drops rows and columns that are empty in every plane (below ground,
    outside every frame)."""
    seen = np.isfinite(values).any(axis=0)
    if not seen.any():
        return values, solid, y, z
    jy = np.where(seen.any(axis=1))[0]
    jz = np.where(seen.any(axis=0))[0]
    a, b = max(jy[0] - margin, 0), min(jy[-1] + margin + 1, len(y))
    c, d = max(jz[0] - margin, 0), min(jz[-1] + margin + 1, len(z))
    return values[:, a:b, c:d].copy(), solid[:, a:b, c:d].copy(), y[a:b], z[c:d]


def preview(source_path: Path, cal: Calibration, frame_index: int) -> tuple[np.ndarray, np.ndarray, np.ndarray, dict, np.ndarray]:
    """One plane, for checking a calibration before a full run."""
    source = FrameSource(source_path)
    frames = cal.frames(source.count)
    lut = build_lut(cal, source)
    cal.frame_size = source.size
    if cal.track_ground:
        stats_ground = track_ground(source, cal, frames, samples=25)
        if cal.plane_mode != "camera":
            pos = np.array([cal.plane_x(f, frames[0], frames[-1]) for f in frames])
            stats_ground["implied_camera"] = cal.implied_camera(frames, pos, source.size)
    y, z = world_grid(cal, frames, cal.working_width)
    excl = _exclusion_mask(cal, source.size)
    values, _, stats = _invert_slice(source.frame(frame_index), cal, cal.scale_at(frame_index), y, z, lut, excl)
    if cal.track_ground:
        stats["ground"] = stats_ground
    return values, y, z, stats, lut.rgb


def _exclusion_mask(cal: Calibration, size: tuple[int, int]) -> np.ndarray:
    w, h = size
    m = np.ones((h, w), np.float32)  # outside the crop counts as excluded
    x0, y0, x1, y1 = cal.crop
    m[max(y0, 0):min(y1, h), max(x0, 0):min(x1, w)] = 0
    for ex0, ey0, ex1, ey1 in cal.exclude:
        m[max(ey0, 0):min(ey1, h), max(ex0, 0):min(ex1, w)] = 1
    return m


def colorize(values: np.ndarray, vmin: float, vmax: float, rgb: np.ndarray) -> np.ndarray:
    """Slice values (ny, nz) to an RGBA image with z up, empty transparent."""
    t = np.clip((values - vmin) / (vmax - vmin), 0, 1)
    idx = np.nan_to_num(t * (len(rgb) - 1)).round().astype(int)
    img = np.zeros(values.shape + (4,), np.uint8)
    img[..., :3] = (rgb[idx] * 255).round().astype(np.uint8)
    img[..., 3] = np.where(np.isnan(values), 0, 255)
    return np.transpose(img, (1, 0, 2))[::-1]  # rows = z from top, cols = y
