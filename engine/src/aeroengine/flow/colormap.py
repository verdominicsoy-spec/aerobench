"""Colour maps and their inversion: colour back to value, in CIELAB."""

from __future__ import annotations

import numpy as np
from scipy.ndimage import uniform_filter1d
from scipy.spatial import cKDTree
from skimage.color import rgb2lab

from ..job import EngineError

# STAR-CCM+ blue-yellow-red, as shown on a STAR legend. Sampled from a real
# legend through H.264, so approximate; sampling the legend in the video
# itself is the more accurate option.
_STAR_BYR = [
    [0.116, 0.123, 0.421], [0.094, 0.167, 0.525], [0.081, 0.221, 0.521], [0.074, 0.273, 0.532],
    [0.104, 0.351, 0.622], [0.13, 0.41, 0.701], [0.176, 0.477, 0.762], [0.298, 0.6, 0.792],
    [0.39, 0.7, 0.82], [0.625, 0.809, 0.524], [0.946, 0.963, 0.351], [0.983, 0.92, 0.326],
    [0.988, 0.838, 0.306], [0.99, 0.748, 0.29], [0.993, 0.643, 0.276], [0.991, 0.525, 0.256],
    [0.978, 0.44, 0.226], [0.957, 0.355, 0.195], [0.932, 0.246, 0.148], [0.755, 0.201, 0.108],
    [0.459, 0.192, 0.108],
]


def _viridis(t: np.ndarray) -> np.ndarray:
    # Polynomial fit to matplotlib's viridis, within about 1/255.
    c = np.array([
        [0.2777273272234177, 0.005407344544966578, 0.3340998053353061],
        [0.1050930431085774, 1.404613529898575, 1.384590162594685],
        [-0.3308618287255563, 0.214847559468213, 0.09509516302823659],
        [-4.634230498983486, -5.799100973351585, -19.33244095627987],
        [6.228269936347081, 14.17993336680509, 56.69055260068105],
        [4.776384997670288, -13.74514537774601, -65.35303263337234],
        [-5.435455855934631, 4.645852612178535, 26.3124352495832],
    ])
    t = t[:, None]
    out = c[6]
    for k in range(5, -1, -1):
        out = c[k] + t * out
    return np.clip(out, 0, 1)


def _jet(t: np.ndarray) -> np.ndarray:
    return np.clip(np.stack([1.5 - np.abs(4 * t - 3), 1.5 - np.abs(4 * t - 2), 1.5 - np.abs(4 * t - 1)], 1), 0, 1)


def _rainbow(t: np.ndarray) -> np.ndarray:
    # Hue from blue (240 degrees) to red (0), full saturation and value.
    h = (1 - t) * 4  # 0..4 sextants: red, yellow, green, cyan, blue
    x = 1 - np.abs(h % 2 - 1)
    rgb = np.zeros((len(t), 3))
    for i, hi in enumerate(h):
        s = int(min(hi, 3.999))
        rgb[i] = [(1, x[i], 0), (x[i], 1, 0), (0, 1, x[i]), (0, x[i], 1)][s]
    return rgb


def _interp(points: list[list[float]], t: np.ndarray) -> np.ndarray:
    p = np.asarray(points, float)
    s = np.linspace(0, 1, len(p))
    return np.stack([np.interp(t, s, p[:, k]) for k in range(3)], 1)


PRESETS = {
    "star_blue_yellow_red": lambda t: _interp(_STAR_BYR, t),
    "viridis": _viridis,
    "jet": _jet,
    "rainbow": _rainbow,
}


def preset(name: str, n: int = 256) -> np.ndarray:
    if name not in PRESETS:
        raise EngineError(f"unknown colormap '{name}'", f"expected one of {', '.join(PRESETS)}")
    return PRESETS[name](np.linspace(0, 1, n))


def sample_legend(frame_rgb: np.ndarray, p0, p1, half_width: int = 3, smooth: float = 0.03) -> np.ndarray:
    """Colours along a line drawn on a legend, p0 at the low end. Averaged
    across the bar and smoothed along it, which turns a stepped (banded)
    legend into the continuous map the field is drawn with."""
    h, w = frame_rgb.shape[:2]
    p0, p1 = np.asarray(p0, float), np.asarray(p1, float)
    length = float(np.linalg.norm(p1 - p0))
    if length < 10:
        raise EngineError("the legend line is too short", "draw it along the colour bar, from the low end to the high end")
    n = int(round(length))
    along = (p1 - p0) / length
    across = np.array([-along[1], along[0]])
    t = np.linspace(0, 1, n)
    samples = []
    for k in range(-half_width, half_width + 1):
        pts = p0 + np.outer(t, p1 - p0) + k * across
        xi = np.clip(np.round(pts[:, 0]).astype(int), 0, w - 1)
        yi = np.clip(np.round(pts[:, 1]).astype(int), 0, h - 1)
        samples.append(frame_rgb[yi, xi].astype(float) / 255)
    prof = np.mean(samples, axis=0)
    window = max(int(round(smooth * n)), 1)
    return uniform_filter1d(prof, size=window, axis=0, mode="nearest")


class ColorLUT:
    """Nearest-colour lookup in CIELAB."""

    def __init__(self, rgb: np.ndarray, vmin: float, vmax: float, n: int = 512) -> None:
        if not vmax > vmin:
            raise EngineError("the value range must have max greater than min")
        rgb = np.asarray(rgb, float)
        src = np.linspace(0, 1, len(rgb))
        t = np.linspace(0, 1, n)
        self.rgb = np.stack([np.interp(t, src, rgb[:, k]) for k in range(3)], 1)
        self.values = vmin + (vmax - vmin) * t
        self.lab = rgb2lab(self.rgb[None])[0]
        self.tree = cKDTree(self.lab)
        self.vmin, self.vmax = vmin, vmax

    def invert(self, rgb_u8: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """Values and colour distances (ΔE) for an (..., 3) uint8 RGB array."""
        shape = rgb_u8.shape[:-1]
        lab = rgb2lab(rgb_u8.reshape(1, -1, 3).astype(float) / 255)[0]
        dist, idx = self.tree.query(lab)
        return self.values[idx].reshape(shape), dist.reshape(shape)


def lab_distance(rgb_u8: np.ndarray, colour_rgb) -> np.ndarray:
    lab = rgb2lab(rgb_u8.reshape(1, -1, 3).astype(float) / 255)[0]
    ref = rgb2lab((np.asarray(colour_rgb, float) / 255).reshape(1, 1, 3))[0, 0]
    return np.linalg.norm(lab - ref, axis=1).reshape(rgb_u8.shape[:-1])
