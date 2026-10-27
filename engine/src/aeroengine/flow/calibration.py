"""Capture calibration: everything needed to turn frames into a volume.

Stored as JSON so one capture setup can be reused on later videos. Pixel
coordinates are in the source frame (origin top left, v down). World
coordinates are metres: y to the right, z up, x along the sweep.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import numpy as np

from ..job import EngineError


@dataclass
class FrameScale:
    """Pixel mapping for one frame: u = cu + sx*y, v = cv - sy*z."""

    sx: float
    sy: float
    cu: float
    cv: float


def _num(d: dict, key: str, label: str) -> float:
    v = d.get(key)
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        raise EngineError(f"{label}.{key} must be a number")
    return float(v)


def _pair(v: Any, label: str) -> np.ndarray:
    if not (isinstance(v, (list, tuple)) and len(v) == 2 and all(isinstance(a, (int, float)) for a in v)):
        raise EngineError(f"{label} must be a pair of numbers")
    return np.asarray(v, float)


def _rect(v: Any, label: str) -> tuple[int, int, int, int]:
    if not (isinstance(v, (list, tuple)) and len(v) == 4):
        raise EngineError(f"{label} must be [x0, y0, x1, y1] in pixels")
    x0, y0, x1, y1 = (int(round(float(a))) for a in v)
    x0, x1 = sorted((x0, x1))
    y0, y1 = sorted((y0, y1))
    if x1 - x0 < 4 or y1 - y0 < 4:
        raise EngineError(f"{label} is too small")
    return x0, y0, x1, y1


class Calibration:
    def __init__(self, data: Any) -> None:
        if not isinstance(data, dict):
            raise EngineError("calibration must be a JSON object")
        self.raw = data
        self.crop = _rect(data.get("crop"), "crop")
        self.exclude = [_rect(r, f"exclude[{i}]") for i, r in enumerate(data.get("exclude", []))]
        cm = data.get("colormap") or {"preset": "star_blue_yellow_red"}
        if not isinstance(cm, dict) or not ("preset" in cm or "legend" in cm):
            raise EngineError("colormap needs a 'preset' name or a 'legend' line")
        self.colormap = cm
        vr = data.get("value_range", [-1, 1])
        self.vmin, self.vmax = (float(a) for a in _pair(vr, "value_range"))
        if not self.vmax > self.vmin:
            raise EngineError("value_range must be [min, max] with max > min")
        self.mask_colors = [list(map(float, c)) for c in data.get("mask_colors", [[255, 255, 255]])]
        self.mask_tolerance = float(data.get("mask_tolerance", 10.0))
        self.threshold = float(data.get("threshold", 12.0))
        self.median = int(data.get("median", 3))
        self.working_width = int(data.get("working_width", 256))
        # "all": the region any frame sees (planes that do not see part of it
        # are empty there). "common": only what every frame sees.
        self.extent = data.get("extent", "all")
        if self.extent not in ("all", "common"):
            raise EngineError("extent must be 'all' or 'common'")
        # Optional world window [ymin, ymax, zmin, zmax] in metres: spend the
        # working resolution on just this region.
        self.window = data.get("window")
        if self.window is not None:
            if not (isinstance(self.window, list) and len(self.window) == 4):
                raise EngineError("window must be [ymin, ymax, zmin, zmax] in metres")
            self.window = [float(a) for a in self.window]
            if not (self.window[1] > self.window[0] and self.window[3] > self.window[2]):
                raise EngineError("window must have ymax > ymin and zmax > zmin")
        if self.working_width < 16:
            raise EngineError("working_width must be at least 16")
        self._spatial(data.get("spatial"))
        self._planes(data.get("planes"))

    # Spatial scale ----------------------------------------------------------

    def _spatial(self, sp: Any) -> None:
        if not isinstance(sp, dict):
            raise EngineError("spatial calibration is missing")
        mode = sp.get("mode", "points")
        self.scales: list[tuple[int, FrameScale]] = []
        if mode == "points":
            frames = sp.get("frames") or []
            if not 1 <= len(frames) <= 2:
                raise EngineError("spatial.frames needs one frame (fixed camera) or two (perspective)")
            for k, fr in enumerate(frames):
                label = f"spatial.frames[{k}]"
                pts = fr.get("points") or []
                if len(pts) != 2:
                    raise EngineError(f"{label} needs exactly two points")
                (pa, wa), (pb, wb) = ((_pair(p.get("px"), f"{label} px"), _pair(p.get("world"), f"{label} world")) for p in pts)
                dp, dw = np.linalg.norm(pb - pa), np.linalg.norm(wb - wa)
                if dp < 2 or dw <= 0:
                    raise EngineError(f"{label}: the two points must be apart in the frame and in the world")
                s = dp / dw
                self.scales.append((int(fr.get("frame", 0)), FrameScale(s, s, pa[0] - s * wa[0], pa[1] + s * wa[1])))
            if len(self.scales) == 2 and self.scales[0][0] == self.scales[1][0]:
                raise EngineError("the two perspective calibration frames must be different frames")
            self.scales.sort(key=lambda fs: fs[0])
        elif mode == "size":
            w, h = _num(sp, "width", "spatial"), _num(sp, "height", "spatial")
            if w <= 0 or h <= 0:
                raise EngineError("spatial width and height must be positive")
            oy, oz = _pair(sp.get("origin", [0, 0]), "spatial.origin")  # world of crop bottom-left
            x0, y0, x1, y1 = self.crop
            sx, sy = (x1 - x0) / w, (y1 - y0) / h
            self.scales.append((0, FrameScale(sx, sy, x0 - sx * oy, y1 + sy * oz)))
        else:
            raise EngineError(f"unknown spatial mode '{mode}'", "expected points or size")

    def scale_at(self, frame: int) -> FrameScale:
        """Pixel mapping at a frame. With two calibrated frames the pixel
        scale follows a pinhole camera looking along the sweep: 1/scale is
        linear in the plane's distance, and so in frame number."""
        if len(self.scales) == 1:
            return self.scales[0][1]
        (f1, a), (f2, b) = self.scales
        t = (frame - f1) / (f2 - f1)
        inv = (1 - t) / a.sx + t / b.sx
        s = 1 / inv
        k = (s - a.sx) / (b.sx - a.sx) if abs(b.sx - a.sx) > 1e-12 else t
        return FrameScale(s, s, a.cu + k * (b.cu - a.cu), a.cv + k * (b.cv - a.cv))

    # Plane positions --------------------------------------------------------

    def _planes(self, pl: Any) -> None:
        if not isinstance(pl, dict):
            raise EngineError("planes calibration is missing")
        self.first_frame = int(pl.get("first_frame", 0))
        self.last_frame = pl.get("last_frame")
        self.stride = int(pl.get("stride", 1))
        if self.stride < 1 or self.first_frame < 0:
            raise EngineError("planes.stride must be >= 1 and first_frame >= 0")
        self.plane_mode = pl.get("mode", "linear")
        if self.plane_mode == "linear":
            self.x_start, self.x_end = _num(pl, "start", "planes"), _num(pl, "end", "planes")
            if self.x_start == self.x_end:
                raise EngineError("planes.start and planes.end must differ")
        elif self.plane_mode == "csv":
            pos = pl.get("positions")
            if not isinstance(pos, list) or len(pos) < 2:
                raise EngineError("planes.positions needs one x per frame")
            self.positions = np.asarray(pos, float)
        else:
            raise EngineError(f"unknown planes mode '{self.plane_mode}'", "expected linear or csv")

    def frames(self, frame_count: int) -> list[int]:
        last = frame_count - 1 if self.last_frame is None else min(int(self.last_frame), frame_count - 1)
        if self.plane_mode == "csv":
            last = min(last, len(self.positions) - 1)
        out = list(range(self.first_frame, last + 1, self.stride))
        if len(out) < 2:
            raise EngineError("fewer than two frames selected", f"first {self.first_frame}, last {last}, stride {self.stride}")
        return out

    def plane_x(self, frame: int, first: int, last: int) -> float:
        if self.plane_mode == "csv":
            return float(self.positions[frame])
        return self.x_start + (self.x_end - self.x_start) * (frame - first) / (last - first)
