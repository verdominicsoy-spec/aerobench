"""Track centrelines resampled to even spacing, with curvature.

A track holds n+1 nodes at s = 0 .. length. On a closed track the last node
is the start again, so segment i always runs from node i to node i+1.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
from scipy.interpolate import splev, splprep

from ..job import EngineError

DEFAULT_DS = 0.5
SKIDPAD_RADIUS = 9.125  # 15.25 m inner circle plus a 3 m lane, centreline radius
ACCEL_LENGTH = 75.0


@dataclass
class Track:
    name: str
    x: np.ndarray
    y: np.ndarray
    kappa: np.ndarray  # signed curvature, 1/m
    closed: bool
    length: float  # exact arc length, m

    @property
    def ds(self) -> float:
        return self.length / (len(self.x) - 1)

    @property
    def s(self) -> np.ndarray:
        return np.linspace(0.0, self.length, len(self.x))


def _nodes(length: float, ds: float) -> np.ndarray:
    if not ds > 0:
        raise EngineError("ds must be greater than 0")
    n = max(int(round(length / ds)), 8)
    return np.linspace(0.0, length, n + 1)


def _make(name: str, x, y, kappa, closed: bool, length: float) -> Track:
    return Track(name, np.asarray(x, float), np.asarray(y, float), np.asarray(kappa, float), closed, float(length))


def skidpad(radius: float = SKIDPAD_RADIUS, ds: float = DEFAULT_DS) -> Track:
    if not radius > 0:
        raise EngineError("skidpad radius must be greater than 0")
    length = 2 * math.pi * radius
    s = _nodes(length, ds)
    th = s / radius
    return _make("Skidpad", radius * np.sin(th), radius * (1 - np.cos(th)), np.full_like(s, 1 / radius), True, length)


def acceleration(length: float = ACCEL_LENGTH, ds: float = DEFAULT_DS) -> Track:
    if not length > 0:
        raise EngineError("acceleration length must be greater than 0")
    s = _nodes(length, ds)
    return _make("Acceleration", s, np.zeros_like(s), np.zeros_like(s), False, length)


def test_track(ds: float = DEFAULT_DS) -> Track:
    """Synthetic closed loop, about 381 m, tightest radius about 12.4 m, with a
    reverse-curvature section. Defined analytically as a polar curve so its
    curvature is exact."""
    r0, a, b = 55.0, 0.28, 0.12

    def polar(th):
        r = r0 * (1 + a * np.cos(2 * th) + b * np.sin(3 * th))
        r1 = r0 * (-2 * a * np.sin(2 * th) + 3 * b * np.cos(3 * th))
        r2 = r0 * (-4 * a * np.cos(2 * th) - 9 * b * np.sin(3 * th))
        return r, r1, r2

    th = np.linspace(0, 2 * np.pi, 200_001)
    r, r1, _ = polar(th)
    speed = np.sqrt(r**2 + r1**2)
    arc = np.concatenate([[0.0], np.cumsum((speed[1:] + speed[:-1]) / 2 * np.diff(th))])
    s = _nodes(arc[-1], ds)
    t = np.interp(s, arc, th)
    r, r1, r2 = polar(t)
    kappa = (r**2 + 2 * r1**2 - r * r2) / (r**2 + r1**2) ** 1.5
    return _make("Test track", r * np.cos(t), r * np.sin(t), kappa, True, arc[-1])


def from_points(
    x, y, closed: bool | None = None, ds: float = DEFAULT_DS, smoothing: float = 0.05, name: str = "Imported"
) -> Track:
    """Fits a smoothing spline through centreline points. `smoothing` is the
    expected scatter of the points in metres."""
    pts = np.column_stack([np.asarray(x, float), np.asarray(y, float)])
    if len(pts) and not np.isfinite(pts).all():
        raise EngineError("track points contain non-numeric values")
    keep = np.concatenate([[True], np.hypot(*np.diff(pts, axis=0).T) > 1e-9]) if len(pts) else []
    pts = pts[keep]
    if len(pts) < 4:
        raise EngineError("a track needs at least 4 distinct points")
    seg = np.hypot(*np.diff(pts, axis=0).T)
    gap = float(np.hypot(*(pts[-1] - pts[0])))
    if closed is None:
        closed = gap <= max(3 * float(np.median(seg)), 1.0)
    if closed:
        if gap < 1e-6:
            pts = pts[:-1]
        pts = np.vstack([pts, pts[:1]])  # splprep wants the loop closed explicitly
    chord = np.concatenate([[0.0], np.cumsum(np.hypot(*np.diff(pts, axis=0).T))])
    if smoothing < 0:
        raise EngineError("smoothing must not be negative")
    try:
        tck, _ = splprep([pts[:, 0], pts[:, 1]], u=chord / chord[-1], s=len(pts) * smoothing**2, per=1 if closed else 0, k=3)
    except Exception as exc:  # noqa: BLE001 - scipy raises several types for bad input
        raise EngineError("could not fit a spline through the track points", str(exc)) from None

    dense = np.linspace(0, 1, max(20 * len(pts), 20_000))
    dx, dy = splev(dense, tck, der=1)
    speed = np.hypot(dx, dy)
    arc = np.concatenate([[0.0], np.cumsum((speed[1:] + speed[:-1]) / 2 * np.diff(dense))])
    s = _nodes(arc[-1], ds)
    u = np.interp(s, arc, dense)
    xs, ys = splev(u, tck)
    x1, y1 = splev(u, tck, der=1)
    x2, y2 = splev(u, tck, der=2)
    kappa = (x1 * y2 - y1 * x2) / (x1**2 + y1**2) ** 1.5
    if closed:
        xs[-1], ys[-1], kappa[-1] = xs[0], ys[0], kappa[0]
    return _make(name, xs, ys, kappa, closed, arc[-1])


_SPLIT = re.compile(r"[,;\s]+")


def read_points(path: Path, scale: float = 1.0) -> tuple[np.ndarray, np.ndarray]:
    """First two numeric columns of a CSV. Header and comment lines are skipped."""
    try:
        text = path.read_text(errors="replace")
    except OSError as exc:
        raise EngineError(f"could not read track file {path}", str(exc)) from None
    xs, ys = [], []
    for line in text.splitlines():
        parts = [p for p in _SPLIT.split(line.strip()) if p]
        if len(parts) < 2 or parts[0].startswith("#"):
            continue
        try:
            xs.append(float(parts[0]) * scale)
            ys.append(float(parts[1]) * scale)
        except ValueError:
            continue
    if len(xs) < 4:
        raise EngineError(f"{path.name} has fewer than 4 numeric x, y rows")
    return np.array(xs), np.array(ys)


# Real event layouts in data/tracks (see its README for sources and licences).
EVENT_TRACKS = {"fsg_2019": "FSG Hockenheim (trackdrive)", "fsi_2019": "FSI Varano (trackdrive)"}


def resolve(spec: Any, ds: float = DEFAULT_DS) -> Track:
    """Builds a track from the job's track object."""
    if not isinstance(spec, dict):
        raise EngineError("track must be a JSON object")
    kind = spec.get("builtin")
    if kind == "skidpad":
        return skidpad(float(spec.get("radius", SKIDPAD_RADIUS)), ds)
    if kind == "acceleration":
        return acceleration(float(spec.get("length", ACCEL_LENGTH)), ds)
    if kind == "test_track":
        return test_track(ds)
    if kind in EVENT_TRACKS:
        path = Path(__file__).resolve().parents[4] / "data" / "tracks" / f"{kind}.csv"
        if not path.is_file():
            raise EngineError(f"missing {path}")
        x, y = read_points(path)
        return from_points(x, y, True, ds, 0.05, name=EVENT_TRACKS[kind])
    if kind is not None:
        raise EngineError(f"unknown built-in track '{kind}'",
                          "expected skidpad, acceleration, test_track, " + ", ".join(EVENT_TRACKS))
    if "generated" in spec:
        from .generate import generate

        return generate(int(spec["generated"]), str(spec.get("event", "endurance")), ds)
    if "csv" in spec:
        path = Path(spec["csv"]).expanduser()
        x, y = read_points(path, float(spec.get("scale", 1.0)))
        return from_points(x, y, spec.get("closed"), ds, float(spec.get("smoothing", 0.05)), name=path.stem)
    raise EngineError("track needs 'builtin', 'generated' or 'csv'")
