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


def _flat_run(prof: np.ndarray, start: int, tol: float = 0.016) -> int:
    """End (exclusive) of the stretch from `start` whose colour stays within
    `tol` of its first pixel."""
    i = start + 1
    while i < len(prof) and np.linalg.norm(prof[i] - prof[start]) < tol:
        i += 1
    return i


def _end_band(prof: np.ndarray) -> tuple[float, np.ndarray] | None:
    """If the legend is banded at prof[0]'s end, where its colour map really
    ends: a banded legend shows each band's centre colour, so the map's end
    is half a band beyond the first band's centre. None for a smooth end."""
    n = len(prof)
    a1 = _flat_run(prof, 0)
    # Skip a blurred boundary of a pixel or two before the next band.
    b0 = a1
    while b0 < min(a1 + 3, n - 1) and np.linalg.norm(prof[b0 + 1] - prof[b0]) > 0.008:
        b0 += 1
    b1 = _flat_run(prof, b0)
    w0, w1 = a1, b1 - b0
    if w1 < 3 or w0 < 2 or w1 > 0.2 * n:
        return None
    c0, c1 = np.median(prof[:a1], axis=0), np.median(prof[b0:b1], axis=0)
    if np.linalg.norm(c1 - c0) < 0.04:  # no real step: a smooth end
        return None
    # The first band may be cut short by where the line starts; the second
    # is whole, so it gives the band width.
    centre0, centre1 = a1 - w1 / 2, (b0 + b1) / 2
    if centre0 < 0 or not 0.5 * w1 <= w0 <= 1.5 * w1:
        return None
    end = c0 + (c0 - c1) * (centre0 + 0.5) / (centre1 - centre0)
    return centre0, np.clip(end, 0, 1)


def sample_legend(frame_rgb: np.ndarray, p0, p1, half_width: int = 3, smooth: float = 0.03) -> np.ndarray:
    """Colours along a line drawn on a legend, p0 at the low end. Averaged
    across the bar and smoothed along it, which turns a stepped (banded)
    legend into the continuous map the field is drawn with. A banded legend
    shows each band's centre colour, never the map's end colours (where
    clipped values are drawn), so at a banded end the colour carries on half
    a band beyond the last band's centre."""
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
    # Video compression blurs colour over a couple of pixels, so the last
    # pixels at each end mix with whatever is beyond the bar (and a line drawn
    # a little long reaches into it). Carry the colour's trend from just
    # inside out to each end instead.
    edge = min(max(3, int(round(0.01 * n))), n // 10)
    if edge > 0 and n > edge + 4:
        for ramp in (prof, prof[::-1]):  # views: writes go to prof
            base = ramp[edge]
            slope = (ramp[edge] - ramp[edge + 3]) / 3
            ramp[:edge] = np.clip(base + slope * np.arange(edge, 0, -1)[:, None], 0, 1)
    ends = [_end_band(prof), _end_band(prof[::-1])]
    window = max(int(round(smooth * n)), 1)
    # Pad each end with the profile's own trend (odd reflection) so the
    # smoothing does not pull the end colours towards the middle.
    pad = min(window, n - 1)
    padded = np.vstack([2 * prof[0] - prof[pad:0:-1], prof, 2 * prof[-1] - prof[-2:-pad - 2:-1]])
    out = uniform_filter1d(padded, size=window, axis=0, mode="nearest")[pad:pad + n]
    out = np.clip(out, 0, 1)
    for side, found in enumerate(ends):
        if found is None:
            continue
        centre, colour = found
        k = int(round(centre))
        ramp = out if side == 0 else out[::-1]  # a view: writes go to out
        if k >= 1:
            w = np.linspace(0, 1, k + 1)[:, None]
            ramp[: k + 1] = (1 - w) * colour + w * ramp[k]
    return out


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
