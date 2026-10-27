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

X0, X1 = 0.0, 2.0  # sweep, m
Y_HALF = 0.6
Z_TOP = 0.7
BODY = (0.4, 0.25, 0.05, 0.15)  # x end, |y| half width, z bottom, z top


def field(x, y, z):
    """Analytic Cp0, NaN inside the body."""
    x, y, z = np.broadcast_arrays(np.asarray(x, float), np.asarray(y, float), np.asarray(z, float))
    amp = 1.7 * (1 - 0.3 * x)
    sy, sz, zc = 0.12 + 0.08 * x, 0.08 + 0.05 * x, 0.25 + 0.05 * x
    v = 1 - amp * np.exp(-((y / sy) ** 2 + ((z - zc) / sz) ** 2))
    body = (x < BODY[0]) & (np.abs(y) < BODY[1]) & (z > BODY[2]) & (z < BODY[3])
    return np.where(body, np.nan, v)


def wake_volume(level: float, n: int = 4001) -> float:
    """Exact volume of {Cp0 < level}: elliptical sections pi sy sz ln(amp / (1 - level))."""
    x = np.linspace(X0, X1, n)
    amp = 1.7 * (1 - 0.3 * x)
    sy, sz = 0.12 + 0.08 * x, 0.08 + 0.05 * x
    area = np.pi * sy * sz * np.log(np.maximum(amp / (1 - level), 1))
    return float(np.trapezoid(area, x))


@dataclass
class Camera:
    """u = cu + s y, v = cv - s z, with s fixed or pinhole-shrinking along x."""

    width: int = 960
    height: int = 540
    perspective: bool = False
    s0: float = 600.0  # px per m at the first plane
    distance: float = 1.5  # camera to first plane, m (perspective only)

    def scale(self, x: float) -> float:
        return self.s0 * self.distance / (self.distance + x - X0) if self.perspective else self.s0

    def centre(self, x: float) -> tuple[float, float]:
        s = self.scale(x)
        horizon, cam_height = 250.0, 0.3
        if self.perspective:
            return self.width / 2, horizon + s * cam_height
        return self.width / 2, horizon + self.s0 * cam_height


def render(x: float, cam: Camera, rgb: np.ndarray, vmin: float, vmax: float) -> np.ndarray:
    s = cam.scale(x)
    cu, cv = cam.centre(x)
    u = np.arange(cam.width) + 0.5
    v = np.arange(cam.height) + 0.5
    Y = (u[None, :] - cu) / s
    Z = (cv - v[:, None]) / s
    val = field(x, Y, Z)
    inside = (np.abs(Y) <= Y_HALF) & (Z >= 0) & (Z <= Z_TOP) & ~np.isnan(val)
    t = np.clip((np.nan_to_num(val) - vmin) / (vmax - vmin), 0, 1)
    img = np.full((cam.height, cam.width, 3), 255, np.uint8)
    img[inside] = (rgb[(t[inside] * (len(rgb) - 1)).round().astype(int)] * 255).round().astype(np.uint8)
    # A banded legend, as STAR draws it, in the bottom right.
    lx0, lx1, ly0, ly1 = cam.width - 330, cam.width - 30, cam.height - 40, cam.height - 18
    bands = 32
    for b in range(bands):
        c = (rgb[int(round((b + 0.5) / bands * (len(rgb) - 1)))] * 255).round().astype(np.uint8)
        img[ly0:ly1, lx0 + (lx1 - lx0) * b // bands: lx0 + (lx1 - lx0) * (b + 1) // bands] = c
    return img


def make_sweep(out: Path, frames: int = 121, perspective: bool = False, cmap: str = "star_blue_yellow_red",
               crf: int = 18, fps: int = 30) -> dict:
    """Writes an H.264 mp4 and returns a calibration that is correct for it."""
    try:
        import imageio_ffmpeg
    except ImportError as exc:  # pragma: no cover
        raise EngineError("imageio-ffmpeg is needed to encode the demo video") from exc
    cam = Camera(perspective=perspective)
    rgb = colormap.preset(cmap)
    vmin, vmax = -1.0, 1.0
    xs = np.linspace(X0, X1, frames)
    cmd = [imageio_ffmpeg.get_ffmpeg_exe(), "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
           "-s", f"{cam.width}x{cam.height}", "-r", str(fps), "-i", "-", "-c:v", "libx264", "-crf", str(crf),
           "-pix_fmt", "yuv420p", str(out)]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        for x in xs:
            proc.stdin.write(render(x, cam, rgb, vmin, vmax).tobytes())
        proc.stdin.close()
        err = proc.stderr.read().decode(errors="replace")
        if proc.wait() != 0:
            raise EngineError("ffmpeg could not encode the demo video", err)
    finally:
        if proc.poll() is None:
            proc.kill()

    def points(frame: int) -> dict:
        x = xs[frame]
        s = cam.scale(x)
        cu, cv = cam.centre(x)
        return {"frame": frame, "points": [
            {"px": [cu - s * Y_HALF, cv], "world": [-Y_HALF, 0.0]},
            {"px": [cu + s * Y_HALF, cv - s * Z_TOP], "world": [Y_HALF, Z_TOP]},
        ]}

    s0 = cam.scale(xs[0])
    cu0, cv0 = cam.centre(xs[0])
    return {
        "version": 1,
        "source_size": [cam.width, cam.height],
        "crop": [cu0 - s0 * Y_HALF, cv0 - s0 * Z_TOP, cu0 + s0 * Y_HALF, cv0],
        "exclude": [[cam.width - 340, cam.height - 50, cam.width - 20, cam.height - 8]],
        "colormap": {"preset": cmap},
        "value_range": [vmin, vmax],
        "spatial": {"mode": "points", "frames": [points(0), points(frames - 1)] if perspective else [points(0)]},
        "planes": {"mode": "linear", "start": X0, "end": X1, "first_frame": 0, "last_frame": frames - 1, "stride": 1},
        "mask_colors": [[255, 255, 255]],
        "mask_tolerance": 10,
        "threshold": 12,
        "median": 3,
        "working_width": 256,
        "extent": "common",
    }
