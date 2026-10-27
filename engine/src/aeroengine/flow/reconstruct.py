"""Frames to a 3D volume.

Each selected frame is resampled onto one common world grid (y, z), then
colour-inverted. Resampling first means a perspective video, where every
frame has its own pixel scale, stacks into a consistent volume.
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
    values: np.ndarray  # (nx, ny, nz) float32, NaN where empty
    x: np.ndarray
    y: np.ndarray
    z: np.ndarray
    frames: list[int]
    vmin: float
    vmax: float
    colormap_rgb: np.ndarray  # (n, 3) 0..1, low to high

    def save(self, folder: Path, calibration: dict, source: str) -> dict:
        np.savez_compressed(folder / "volume.npz", values=self.values, x=self.x, y=self.y, z=self.z,
                            frames=np.asarray(self.frames), value_range=np.array([self.vmin, self.vmax]),
                            colormap=self.colormap_rgb, calibration=json.dumps(calibration), source=source)
        self.values.astype("<f4").tofile(folder / "volume.bin")
        meta = {
            "shape": list(self.values.shape),
            "order": "x, y, z; z fastest; little-endian float32; NaN is empty",
            "x": self.x.tolist(),
            "y0": float(self.y[0]), "dy": float(self.y[1] - self.y[0]),
            "z0": float(self.z[0]), "dz": float(self.z[1] - self.z[0]),
            "frames": self.frames,
            "value_range": [self.vmin, self.vmax],
            "colormap": np.round(self.colormap_rgb[:: max(len(self.colormap_rgb) // 64, 1)], 4).tolist(),
            "units": "m",
        }
        (folder / "volume.json").write_text(json.dumps(meta))
        return meta

    @classmethod
    def load(cls, npz: Path) -> "Volume":
        d = np.load(npz, allow_pickle=False)
        vr = d["value_range"]
        return cls(d["values"], d["x"], d["y"], d["z"], d["frames"].tolist(), float(vr[0]), float(vr[1]), d["colormap"])


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
    """The y, z extent of the crop across the selected frames (all of it, or
    only the part every frame sees), at `width` samples across. With a
    perspective calibration the first and last frames are the extremes."""
    x0, y0, x1, y1 = cal.crop
    boxes = []
    for f in (frames[0], frames[-1]) if len(cal.scales) == 2 else frames[:1]:
        s = cal.scale_at(f)
        boxes.append(((x0 - s.cu) / s.sx, (x1 - s.cu) / s.sx, (s.cv - y1) / s.sy, (s.cv - y0) / s.sy))
    b = np.array(boxes)
    if cal.window is not None:
        ylo, yhi, zlo, zhi = cal.window
    elif cal.extent == "all":
        ylo, yhi, zlo, zhi = b[:, 0].min(), b[:, 1].max(), b[:, 2].min(), b[:, 3].max()
    else:
        ylo, yhi, zlo, zhi = b[:, 0].max(), b[:, 1].min(), b[:, 2].max(), b[:, 3].min()
    if not (yhi > ylo and zhi > zlo):
        raise EngineError("the crop region does not overlap between the first and last frame",
                          "check the spatial calibration points")
    y = np.linspace(ylo, yhi, width)
    dy = y[1] - y[0]
    z = np.arange(zlo, zhi + dy / 2, dy)
    return y, z


def _invert_slice(frame: np.ndarray, cal: Calibration, s, y: np.ndarray, z: np.ndarray,
                  lut: colormap.ColorLUT, excl: np.ndarray) -> tuple[np.ndarray, dict]:
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
    empty = ex | (dist > cal.threshold)
    for c in cal.mask_colors:
        empty |= colormap.lab_distance(rgb, c) < cal.mask_tolerance
    values = values.astype(np.float32)
    if cal.median > 1 and (~empty).any():
        # NaN-aware median: fill empty cells from their nearest neighbour,
        # filter, then empty them again.
        idx = distance_transform_edt(empty, return_distances=False, return_indices=True)
        values = median_filter(values[tuple(idx)], size=cal.median)
    values[empty] = np.nan
    stats = {"median_dE": float(np.median(dist[~empty])) if (~empty).any() else None,
             "empty_fraction": float(empty.mean())}
    return values, stats


def reconstruct(source_path: Path, cal: Calibration, progress: Callable[[float, str], None] | None = None) -> tuple[Volume, dict]:
    report = progress or (lambda pct, msg: None)
    source = FrameSource(source_path)
    frames = cal.frames(source.count)
    lut = build_lut(cal, source)
    y, z = world_grid(cal, frames, cal.working_width)
    excl = _exclusion_mask(cal, source.size)
    values = np.full((len(frames), len(y), len(z)), np.nan, np.float32)
    x = np.array([cal.plane_x(f, frames[0], frames[-1]) for f in frames])
    stats = []
    for n, (i, frame) in enumerate(source.frames(frames)):
        k = frames.index(i)
        values[k], st = _invert_slice(frame, cal, cal.scale_at(i), y, z, lut, excl)
        stats.append(st)
        if n % 5 == 0 or n == len(frames) - 1:
            report(5 + 90 * (n + 1) / len(frames), f"plane {n + 1}/{len(frames)}")
    if len(stats) < len(frames):
        raise EngineError(f"the video ended early: read {len(stats)} of {len(frames)} frames")
    if x[0] > x[-1]:  # keep x increasing
        values, x, frames = values[::-1].copy(), x[::-1].copy(), frames[::-1]
    if cal.window is None:
        values, y, z = _trim(values, y, z)
    dEs = [s["median_dE"] for s in stats if s["median_dE"] is not None]
    summary = {
        "planes": len(frames),
        "median_dE": float(np.median(dEs)) if dEs else None,
        "empty_fraction": float(np.mean([s["empty_fraction"] for s in stats])),
    }
    return Volume(values, x, y, z, frames, cal.vmin, cal.vmax, lut.rgb), summary


def _trim(values: np.ndarray, y: np.ndarray, z: np.ndarray, margin: int = 2):
    """Drops rows and columns that are empty in every plane (below ground,
    outside every frame)."""
    seen = np.isfinite(values).any(axis=0)
    if not seen.any():
        return values, y, z
    jy = np.where(seen.any(axis=1))[0]
    jz = np.where(seen.any(axis=0))[0]
    a, b = max(jy[0] - margin, 0), min(jy[-1] + margin + 1, len(y))
    c, d = max(jz[0] - margin, 0), min(jz[-1] + margin + 1, len(z))
    return values[:, a:b, c:d].copy(), y[a:b], z[c:d]


def preview(source_path: Path, cal: Calibration, frame_index: int) -> tuple[np.ndarray, np.ndarray, np.ndarray, dict, np.ndarray]:
    """One plane, for checking a calibration before a full run."""
    source = FrameSource(source_path)
    frames = cal.frames(source.count)
    lut = build_lut(cal, source)
    y, z = world_grid(cal, frames, cal.working_width)
    excl = _exclusion_mask(cal, source.size)
    values, stats = _invert_slice(source.frame(frame_index), cal, cal.scale_at(frame_index), y, z, lut, excl)
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
