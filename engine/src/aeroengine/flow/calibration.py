"""Capture calibration: everything needed to turn frames into a volume.

Stored as JSON so one capture setup can be reused on later videos. Pixel
coordinates are in the source frame (origin top left, v down, continuous:
pixel i covers [i, i+1)). World coordinates are metres in the car's frame.
`axes` says which world axis points right and which up in the frames (read
it off STAR's axis triad); the remaining axis is the sweep. Internally the
image-plane coordinates are h (right) and v (up).
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


DETAIL_CAPS = {"low": 8_000_000, "medium": 30_000_000, "high": 100_000_000}  # voxels


def _axis(v: Any, label: str) -> tuple[int, str]:
    if not (isinstance(v, str) and len(v) == 2 and v[0] in "+-" and v[1] in "xyz"):
        raise EngineError(f"axes.{label} must be one of +x, -x, +y, -y, +z, -z")
    return (1 if v[0] == "+" else -1), v[1]


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
        # are empty there). "common": only what every frame sees. "auto":
        # around wherever the flow differs from the free stream or there is
        # geometry, with a margin.
        self.extent = data.get("extent", "all")
        if self.extent not in ("all", "common", "auto"):
            raise EngineError("extent must be 'all', 'common' or 'auto'")
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
        axes = data.get("axes") or {"right": "+y", "up": "+z"}
        self.right = _axis(axes.get("right"), "right")
        self.up = _axis(axes.get("up"), "up")
        if self.right[1] == self.up[1]:
            raise EngineError("axes.right and axes.up must be different axes")
        self.sweep_axis = ({"x", "y", "z"} - {self.right[1], self.up[1]}).pop()
        ground = data.get("ground") or {}
        self.track_ground = bool(ground.get("track", False))
        self.ground_level = float(ground.get("level", 0.0))
        if self.track_ground and self.up != (1, "z"):
            raise EngineError("ground tracking needs +z pointing up in the frames", "for top views, calibrate two frames instead")
        self.ground_fit: tuple[float, float, float, int] | None = None  # (vh, K, a, direction) set by reconstruct
        self.ground_rows: dict[int, float] | None = None  # constant ground (no perspective): frame -> row
        self.frame_size: tuple[int, int] | None = None  # set by reconstruct: the vanishing point, camera planes
        # The vanishing point's column, if the video was cropped off-centre
        # (otherwise the frame's centre).
        self.principal_u = ground.get("principal_u")
        if self.principal_u is not None:
            self.principal_u = float(self.principal_u)
        self.detail = data.get("detail")
        if self.detail is not None and self.detail not in DETAIL_CAPS:
            raise EngineError("detail must be low, medium or high")
        self._spatial(data.get("spatial"))
        self._planes(data.get("planes"))
        # The frame rate and frame count the app used (detected, or typed in
        # because the video reports them wrong): frames are then picked by
        # time, as the app picks them.
        video = data.get("video") or {}
        if not isinstance(video, dict):
            raise EngineError("video must be an object: fps and frames")
        self.video_fps = float(video["fps"]) if video.get("fps") else None
        self.video_frames = int(video["frames"]) if video.get("frames") else None
        if self.video_fps is not None and self.video_fps <= 0:
            raise EngineError("video.fps must be above zero")

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
                signs = np.array([self.right[0], self.up[0]], float)
                wa, wb = wa * signs, wb * signs  # world right/up coordinates to image-plane h, v
                dp, dw = np.linalg.norm(pb - pa), np.linalg.norm(wb - wa)
                if dp < 2 or dw <= 0:
                    raise EngineError(f"{label}: the two points must be apart in the frame and in the world")
                s = dp / dw
                self.scales.append((int(fr.get("frame", 0)), FrameScale(s, s, pa[0] - s * wa[0], pa[1] + s * wa[1])))
            if len(self.scales) == 2 and self.scales[0][0] == self.scales[1][0]:
                raise EngineError("the two perspective calibration frames must be different frames")
            self.scales.sort(key=lambda fs: fs[0])
        elif mode == "size":
            # Pixels are square, so the crop's width sets one scale for both
            # directions. A height that disagrees would stretch the result.
            w = _num(sp, "width", "spatial")
            if w <= 0:
                raise EngineError("spatial width must be positive")
            oy, oz = _pair(sp.get("origin", [0, 0]), "spatial.origin") * [self.right[0], self.up[0]]  # crop bottom-left
            x0, y0, x1, y1 = self.crop
            s = (x1 - x0) / w
            if sp.get("height") is not None:
                h = _num(sp, "height", "spatial")
                implied = (y1 - y0) / s
                if h <= 0 or abs(h - implied) > 0.02 * implied:
                    raise EngineError(
                        f"a crop {x1 - x0} x {y1 - y0} px that is {w * 1000:.0f} mm wide is {implied * 1000:.0f} mm tall, "
                        f"not {h * 1000:.0f} mm", "pixels are square: leave the height out, or redraw the crop")
            self.scales.append((0, FrameScale(s, s, x0 - s * oy, y1 + s * oz)))
        else:
            raise EngineError(f"unknown spatial mode '{mode}'", "expected points or size")

    def ground_row(self, frame: float) -> float:
        if self.ground_rows is not None:
            return float(np.median(list(self.ground_rows.values())))
        vh, k, a, direction = self.ground_fit
        return vh + k / (a + direction * frame)

    def scale_at(self, frame: int) -> FrameScale:
        """Pixel mapping at a frame. With two calibrated frames the pixel
        scale follows a pinhole camera looking along the sweep: 1/scale is
        linear in the plane's distance, and so in frame number. With ground
        tracking the scale comes from the tracked ground line instead (its
        height above the horizon is proportional to the scale) and the ground
        is pinned to its z level in every frame."""
        if self.track_ground and (self.ground_fit is not None or self.ground_rows is not None):
            f0, ref = self.scales[0]
            if self.ground_rows is not None:  # parallel camera: constant scale, measured ground row
                return FrameScale(ref.sx, ref.sy, ref.cu, self.ground_row(frame) + ref.sy * self.ground_level)
            vh = self.ground_fit[0]
            s = ref.sx * (self.ground_row(frame) - vh) / (self.ground_row(f0) - vh)
            cu = ref.cu
            if len(self.scales) == 2:  # a second frame measures the sideways drift
                (_, a), (_, b) = self.scales
                if abs(b.sx - a.sx) > 1e-12:
                    cu = a.cu + (s - a.sx) / (b.sx - a.sx) * (b.cu - a.cu)
            elif self.principal_u is not None or self.frame_size is not None:
                # Everything shrinks towards the vanishing point, which a CFD
                # render puts at the frame's centre column. A camera off the
                # world origin (off the centreline, or partway along the car
                # in a side view) then drifts sideways correctly.
                uc = self.principal_u if self.principal_u is not None else self.frame_size[0] / 2
                h_cam = (uc - ref.cu) / ref.sx  # camera's position along the right axis (image-plane h)
                cu = uc - s * h_cam
            return FrameScale(s, s, cu, self.ground_row(frame) + s * self.ground_level)
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
        elif self.plane_mode == "camera":
            # Positions from the tracked ground: a pinhole camera's scale is
            # focal length / distance, so with the view angle (the focal
            # length in pixels) each frame's scale gives its plane's distance.
            self.x_start = _num(pl, "start", "planes")
            self.view_angle = _num(pl, "view_angle", "planes")
            self.view_angle_axis = pl.get("view_angle_axis", "vertical")
            if not 1 <= self.view_angle <= 170:
                raise EngineError("planes.view_angle must be between 1 and 170 degrees")
            if self.view_angle_axis not in ("vertical", "horizontal"):
                raise EngineError("planes.view_angle_axis must be vertical or horizontal")
            if not self.track_ground:
                raise EngineError("plane positions from the camera need ground tracking")
        elif self.plane_mode == "csv":
            pos = pl.get("positions")
            if not isinstance(pos, list) or len(pos) < 2:
                raise EngineError("planes.positions needs one x per frame")
            self.positions = np.asarray(pos, float)
        else:
            raise EngineError(f"unknown planes mode '{self.plane_mode}'", "expected linear, csv or camera")

    def frames(self, frame_count: int) -> list[int]:
        last = frame_count - 1 if self.last_frame is None else min(int(self.last_frame), frame_count - 1)
        if self.plane_mode == "csv":
            last = min(last, len(self.positions) - 1)
        out = list(range(self.first_frame, last + 1, self.stride))
        if len(out) < 2:
            raise EngineError("fewer than two frames selected", f"first {self.first_frame}, last {last}, stride {self.stride}")
        return out

    @property
    def away(self) -> int:
        """+1 if the sweep coordinate grows away from the camera. The camera
        looks along -(right x up) in a right-handed frame."""
        vec = {"x": np.array([1, 0, 0]), "y": np.array([0, 1, 0]), "z": np.array([0, 0, 1])}
        back = np.cross(self.right[0] * vec[self.right[1]], self.up[0] * vec[self.up[1]])
        return int(-back @ vec[self.sweep_axis])

    def focal_px(self, frame_size: tuple[int, int]) -> float:
        """Focal length in pixels from the camera mode's view angle."""
        w, h = frame_size
        span = h if self.view_angle_axis == "vertical" else w
        return (span / 2) / np.tan(np.radians(self.view_angle) / 2)

    def plane_x(self, frame: int, first: int, last: int) -> float:
        if self.plane_mode == "csv":
            return float(self.positions[frame])
        if self.plane_mode == "camera":
            if self.ground_fit is None:
                raise EngineError("plane positions from the camera need a perspective camera",
                         "the ground line did not move, so the camera is parallel: enter the plane positions")
            f = self.focal_px(self.frame_size)
            return self.x_start + self.away * f * (1 / self.scale_at(frame).sx - 1 / self.scale_at(first).sx)
        return self.x_start + (self.x_end - self.x_start) * (frame - first) / (last - first)

    def implied_camera(self, frames: list[int], positions: np.ndarray, frame_size: tuple[int, int]) -> dict | None:
        """What the plane positions and the tracked scale say about the
        camera: its view angle and distance to the first plane. A check on
        the plane positions, to compare with the view angle set in STAR."""
        if self.ground_fit is None:
            return None
        inv = np.array([1 / self.scale_at(f).sx for f in frames])
        if np.ptp(inv) <= 0 or np.ptp(positions) <= 0:
            return None
        slope = np.polyfit(inv, positions, 1)[0]  # metres of sweep per (metres per pixel) = focal length, signed
        w, h = frame_size
        f = abs(slope)
        return {
            "focal_px": float(f),
            "view_angle_vertical_deg": float(np.degrees(2 * np.arctan(h / 2 / f))),
            "view_angle_horizontal_deg": float(np.degrees(2 * np.arctan(w / 2 / f))),
            "distance_to_first_plane_m": float(f * inv[0]),
            "planes_run_away_from_camera": bool(np.sign(slope) == self.away),
        }
