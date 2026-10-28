"""Synthetic Cp0 sweeps with a known answer: for the regression test and the
in-app demo. A wake that spreads and recovers downstream, a body near the
front, ground below, rendered like a STAR-CCM+ scene with a legend."""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from ..job import EngineError
from . import colormap

X0, X1 = 0.0, 2.0  # car length region, m
Y_HALF = 0.6
Z_TOP = 0.7
BODY = (0.4, 0.25, 0.05, 0.15)  # x end, |y| half width, z bottom, z top
WAKE_Y = 0.08  # the wake sits off the centreline so a mirrored axis would show

# How each synthetic view is laid out: world axis to the right and up in the
# frames, the sweep axis, and its range from the plane nearest the camera to
# the farthest. A real camera is right-handed: it looks along -(right x up),
# so with +y right and +z up the planes recede towards -x.
VIEWS = {
    "rear": {"right": "+y", "up": "+z", "sweep": "x", "range": (X1, X0), "h": (-Y_HALF, Y_HALF), "s0": 600.0},
    "front": {"right": "-y", "up": "+z", "sweep": "x", "range": (X0, X1), "h": (-Y_HALF, Y_HALF), "s0": 600.0},
    "side": {"right": "+x", "up": "+z", "sweep": "y", "range": (-Y_HALF, Y_HALF), "h": (X0, X1), "s0": 400.0},
}


def field(x, y, z):
    """Analytic Cp0, NaN inside the body."""
    x, y, z = np.broadcast_arrays(np.asarray(x, float), np.asarray(y, float), np.asarray(z, float))
    amp = 1.7 * (1 - 0.3 * x)
    sy, sz, zc = 0.12 + 0.08 * x, 0.08 + 0.05 * x, 0.25 + 0.05 * x
    v = 1 - amp * np.exp(-(((y - WAKE_Y) / sy) ** 2 + ((z - zc) / sz) ** 2))
    body = (x < BODY[0]) & (np.abs(y) < BODY[1]) & (z > BODY[2]) & (z < BODY[3])
    inside = (x >= X0) & (x <= X1) & (np.abs(y) <= Y_HALF)
    return np.where(body | ~inside, np.nan, v)


def wake_volume(level: float, n: int = 4001) -> float:
    """Exact volume of {Cp0 < level}: elliptical sections pi sy sz ln(amp / (1 - level))."""
    x = np.linspace(X0, X1, n)
    amp = 1.7 * (1 - 0.3 * x)
    sy, sz = 0.12 + 0.08 * x, 0.08 + 0.05 * x
    area = np.pi * sy * sz * np.log(np.maximum(amp / (1 - level), 1))
    return float(np.trapezoid(area, x))


@dataclass
class Camera:
    """u = cu + s h, v = cv - s z, with s fixed or pinhole-shrinking along the sweep."""

    view: str = "front"
    width: int = 960
    height: int = 540
    perspective: bool = False
    distance: float = 1.5  # camera to first plane, m (perspective only)

    @property
    def spec(self) -> dict:
        return VIEWS[self.view]

    def scale(self, t: float) -> float:
        s0, start = self.spec["s0"], self.spec["range"][0]
        return s0 * self.distance / (self.distance + abs(t - start)) if self.perspective else s0

    def centre(self, t: float) -> tuple[float, float]:
        s = self.scale(t)
        h_mid = sum(self.spec["h"]) / 2
        horizon, cam_height = 250.0, 0.3
        s_for_v = s if self.perspective else self.spec["s0"]
        return self.width / 2 - s * h_mid, horizon + s_for_v * cam_height

    def world(self, t: float, h: np.ndarray, v: np.ndarray):
        """World x, y, z of image-plane coordinates on the plane at sweep t."""
        sign = 1 if self.spec["right"][0] == "+" else -1
        right = self.spec["right"][1]
        coords = {self.spec["sweep"]: np.full_like(h, t), right: sign * h, "z": v}
        return coords["x"], coords["y"], coords["z"]


# Kept for callers of the first version (rear view).
def render(t: float, cam: Camera, rgb: np.ndarray, vmin: float, vmax: float) -> np.ndarray:
    s = cam.scale(t)
    cu, cv = cam.centre(t)
    u = np.arange(cam.width) + 0.5
    v = np.arange(cam.height) + 0.5
    H = (u[None, :] - cu) / s + 0 * v[:, None]
    V = (cv - v[:, None]) / s + 0 * u[None, :]
    X, Y, Z = cam.world(t, H, V)
    h_lo, h_hi = cam.spec["h"]
    val = field(X, Y, Z)
    inside = (H >= h_lo) & (H <= h_hi) & (V >= 0) & (V <= Z_TOP) & ~np.isnan(val)
    tt = np.clip((np.nan_to_num(val) - vmin) / (vmax - vmin), 0, 1)
    img = np.full((cam.height, cam.width, 3), 255, np.uint8)
    img[inside] = (rgb[(tt[inside] * (len(rgb) - 1)).round().astype(int)] * 255).round().astype(np.uint8)
    _triad(img, cam)
    # A banded legend, as STAR draws it, in the bottom right.
    lx0, lx1, ly0, ly1 = cam.width - 330, cam.width - 30, cam.height - 40, cam.height - 18
    bands = 32
    for b in range(bands):
        c = (rgb[int(round((b + 0.5) / bands * (len(rgb) - 1)))] * 255).round().astype(np.uint8)
        img[ly0:ly1, lx0 + (lx1 - lx0) * b // bands: lx0 + (lx1 - lx0) * (b + 1) // bands] = c
    return img


def _triad(img: np.ndarray, cam: "Camera") -> None:
    """STAR's axis triad in the bottom left: x red, y green, z blue, the
    axis along the sweep seen end-on as a dot."""
    import cv2

    colours = {"x": (220, 30, 30), "y": (30, 190, 30), "z": (30, 30, 220)}
    ox, oy = 60, cam.height - 40
    spec = cam.spec
    for key, (dx, dy) in (("right", (1, 0)), ("up", (0, -1))):
        sign = 1 if spec[key][0] == "+" else -1
        cv2.arrowedLine(img, (ox, oy), (ox + sign * dx * 45, oy + sign * dy * 45), colours[spec[key][1]], 3,
                        tipLength=0.35)
    cv2.circle(img, (ox, oy), 5, colours[spec["sweep"]], -1)


def make_sweep(out: Path, frames: int = 121, perspective: bool = False, cmap: str = "star_blue_yellow_red",
               crf: int = 18, fps: int = 30, view: str = "front") -> dict:
    """Writes an H.264 mp4 and returns a calibration that is correct for it."""
    try:
        import imageio_ffmpeg
    except ImportError as exc:  # pragma: no cover
        raise EngineError("imageio-ffmpeg is needed to encode the demo video") from exc
    cam = Camera(view=view, perspective=perspective)
    spec = cam.spec
    rgb = colormap.preset(cmap)
    vmin, vmax = -1.0, 1.0
    ts = np.linspace(*spec["range"], frames)
    cmd = [imageio_ffmpeg.get_ffmpeg_exe(), "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
           "-s", f"{cam.width}x{cam.height}", "-r", str(fps), "-i", "-", "-c:v", "libx264", "-crf", str(crf),
           "-pix_fmt", "yuv420p", str(out)]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        for t in ts:
            proc.stdin.write(render(t, cam, rgb, vmin, vmax).tobytes())
        proc.stdin.close()
        err = proc.stderr.read().decode(errors="replace")
        if proc.wait() != 0:
            raise EngineError("ffmpeg could not encode the demo video", err)
    finally:
        if proc.poll() is None:
            proc.kill()

    sign = 1 if spec["right"][0] == "+" else -1
    h_lo, h_hi = spec["h"]

    def points(frame: int) -> dict:
        t = ts[frame]
        s = cam.scale(t)
        cu, cv = cam.centre(t)
        return {"frame": frame, "points": [
            {"px": [cu + s * h_lo, cv], "world": [sign * h_lo, 0.0]},
            {"px": [cu + s * h_hi, cv - s * Z_TOP], "world": [sign * h_hi, Z_TOP]},
        ]}

    s0 = cam.scale(ts[0])
    cu0, cv0 = cam.centre(ts[0])
    return {
        "version": 1,
        "source_size": [cam.width, cam.height],
        # A strip of ground below the plot so the ground line can be tracked.
        "crop": [cu0 + s0 * h_lo, cv0 - s0 * Z_TOP, cu0 + s0 * h_hi, cv0 + 20],
        "exclude": [[cam.width - 340, cam.height - 50, cam.width - 20, cam.height - 8]],
        "colormap": {"preset": cmap},
        "value_range": [vmin, vmax],
        "axes": {"right": spec["right"], "up": spec["up"]},
        "spatial": {"mode": "points", "frames": [points(0), points(frames - 1)] if perspective else [points(0)]},
        "planes": {"mode": "linear", "start": float(ts[0]), "end": float(ts[-1]), "first_frame": 0,
                   "last_frame": frames - 1, "stride": 1},
        "mask_colors": [[255, 255, 255]],
        "mask_tolerance": 10,
        "threshold": 12,
        "median": 3,
        "working_width": 256,
        "extent": "common",
    }
