"""Representative event tracks when no layout is published.

The FS rules give limits, not a layout (data/rules/fs2027_tracks.json): the
longest straight, slalom cone spacing, the tightest turn, the lap length.
A track here is built the way one is sketched: straights (mostly short, the
odd long one), corners (radius and turn drawn from spreads tuned against the
FSG and FSI layouts), and one slalom at the rules' cone spacing, with eased
curvature between them. The turns are trimmed so the lap turns through
exactly one circle and a small drift correction closes it; a layout is kept
only if it does not cross itself and stays within the rules. The same seed
always gives the same track.

Against the real trackdrive layouts in data/tracks (34 to 43% of the lap in
corners tighter than 15 m, 4 to 5 corners per 100 m) these come out a little
more open (about 15 to 30%, 3 per 100 m), as a 1 km endurance lap tends to
be. They are for comparing cars on a typical layout, not for predicting an
event's lap time."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from ..job import EngineError
from .track import DEFAULT_DS, Track, from_points

RULES = Path(__file__).resolve().parents[4] / "data" / "rules" / "fs2027_tracks.json"
STRAIGHT_RADIUS = 150.0  # m: flatter than this counts as straight
STRAIGHT_MEAN = 18.0  # m, straights' mean length (exponential, clipped to the rules)
CORNER_RADII = (4.8, 22.0)  # m, log-uniform
HAIRPIN_SHARE = 0.4  # of corners that turn 90 to 180 degrees; the rest turn 30 to 90
SWITCH = 0.65  # chance the next corner turns the other way
SLALOM_AMPLITUDE = 1.0  # m, the line's sideways swing through the cones
SLALOM_CONES = 5


def rules(event: str = "endurance", path: Path = RULES) -> dict:
    data = json.loads(path.read_text())
    if not isinstance(data.get(event), dict):
        events = [k for k, v in data.items() if isinstance(v, dict)]
        raise EngineError(f"no layout rules for '{event}'", f"{path.name} has: {', '.join(events)}")
    return {k: v["value"] for k, v in data[event].items()}


def _runs(flags: np.ndarray) -> list[int]:
    """Lengths (in nodes) of runs of True around a closed loop."""
    if flags.all():
        return [len(flags)]
    rolled = np.roll(flags, -int(np.argmin(flags)))  # start on a False so no run is split
    out, count = [], 0
    for f in rolled:
        if f:
            count += 1
        elif count:
            out.append(count)
            count = 0
    if count:
        out.append(count)
    return out


def _crosses(x: np.ndarray, y: np.ndarray, step: int = 8) -> bool:
    """Whether a closed polyline (thinned to every step-th point) crosses itself."""
    p = np.column_stack([x[::step], y[::step]])
    n = len(p)
    a, b = p, np.roll(p, -1, axis=0)

    def orient(p0, p1, p2):
        return np.sign((p1[..., 0] - p0[..., 0]) * (p2[..., 1] - p0[..., 1]) - (p1[..., 1] - p0[..., 1]) * (p2[..., 0] - p0[..., 0]))

    A, B, C, D = a[:, None], b[:, None], a[None], b[None]
    hit = (orient(A, B, C) * orient(A, B, D) < 0) & (orient(C, D, A) * orient(C, D, B) < 0)
    i, j = np.indices((n, n))
    near = (np.abs(i - j) <= 1) | (np.abs(i - j) >= n - 1)
    return bool((hit & ~near).any())


def _curvature_profile(rng: np.random.Generator, length: float, straight_max: float, spacing: float,
                       ds: float) -> np.ndarray | None:
    """Signed curvature at every ds along a lap that turns one full circle."""
    pieces: list[tuple[str, float, float]] = []  # (kind, length or radius, signed angle)
    total, sign = 0.0, 1.0
    slalom_at = int(rng.integers(2, 6))
    while total < length:
        straight = float(np.clip(rng.exponential(STRAIGHT_MEAN), 4.0, 0.9 * straight_max))
        pieces.append(("straight", straight, 0.0))
        total += straight
        if len(pieces) == 2 * slalom_at:
            pieces.append(("slalom", spacing * SLALOM_CONES, 0.0))
            total += spacing * SLALOM_CONES
        radius = float(np.exp(rng.uniform(*np.log(CORNER_RADII))))
        turn = np.radians(rng.uniform(90, 180) if rng.random() < HAIRPIN_SHARE else rng.uniform(30, 90))
        if rng.random() < SWITCH:
            sign = -sign
        pieces.append(("corner", radius, sign * turn))
        total += radius * turn
    net = sum(a for kind, _, a in pieces if kind == "corner")
    if abs(net) < 1e-6:
        return None
    # Trim the turns that go the net way so the lap turns exactly one circle.
    with_net = sum(a for kind, _, a in pieces if kind == "corner" and np.sign(a) == np.sign(net))
    factor = (2 * np.pi * np.sign(net) - (net - with_net)) / with_net
    if not 0.6 < factor < 1.6:
        return None
    kappa: list[np.ndarray] = []
    for kind, size, angle in pieces:
        if kind == "straight":
            kappa.append(np.zeros(max(int(size / ds), 1)))
        elif kind == "slalom":
            s = np.arange(int(size / ds)) * ds
            # The line y = A sin(pi s / spacing) through cones every `spacing`: y'' is its curvature.
            kappa.append(-SLALOM_AMPLITUDE * (np.pi / spacing) ** 2 * np.sin(np.pi * s / spacing) * np.sin(np.pi * s / size) ** 2)
        else:
            angle = angle * factor if np.sign(angle) == np.sign(net) else angle
            kappa.append(np.full(max(int(abs(angle) * size / ds), 1), np.sign(angle) / size))
    k = np.concatenate(kappa)
    ease = int(3.0 / ds)  # corners ease in and out over about 6 m
    k = np.convolve(np.r_[k[-ease:], k, k[:ease]], np.ones(2 * ease + 1) / (2 * ease + 1), "same")[ease:-ease]
    return k * (2 * np.pi * np.sign(net)) / (k.sum() * ds)


def generate(seed: int, event: str = "endurance", ds: float = DEFAULT_DS, rules_path: Path = RULES,
             attempts: int = 1000) -> Track:
    r = rules(event, rules_path)
    length = float(r.get("lap_length_m") or 0.8 * float(r["lap_length_max_m"]))
    r_min = float(r["turning_diameter_min_m"]) / 2
    straight_max = float(r["straight_max_m"])
    spacing = float(np.mean(r["slalom_spacing_m"]))
    for k in range(attempts):
        rng = np.random.default_rng([seed, k])
        kappa = _curvature_profile(rng, length, straight_max, spacing, ds)
        if kappa is None:
            continue
        heading = np.cumsum(kappa) * ds
        x, y = np.cumsum(np.cos(heading)) * ds, np.cumsum(np.sin(heading)) * ds
        s = np.arange(len(x)) * ds
        gap = np.array([x[-1] - x[0], y[-1] - y[0]])
        if np.hypot(*gap) > 0.25 * s[-1]:
            continue  # too far from closing to correct without distorting it
        x, y = x - s / s[-1] * gap[0], y - s / s[-1] * gap[1]
        x, y = x * length / s[-1], y * length / s[-1]
        if _crosses(x, y):
            continue
        # Autocross is one lap from a standing start: the same loop, run open.
        closed = bool(r.get("closed", True))
        track = from_points(x[:-1] if closed else x, y[:-1] if closed else y, closed, ds, 0.0,
                            name=f"Generated {event} #{seed}")
        d = describe(track)
        if d["min_radius"] >= r_min and d["longest_straight"] <= straight_max:
            return track
    raise EngineError(f"no {event} layout within the rules after {attempts} tries for seed {seed}")


def describe(track: Track) -> dict:
    """What a layout is like: corners and their sizes, the longest straight."""
    k = np.abs(track.kappa)
    corners = _runs(k > 1 / 30.0)  # tighter than 30 m radius
    return {
        "length": float(track.length),
        "min_radius": float(1 / k.max()),
        "longest_straight": float(max(_runs(k < 1 / STRAIGHT_RADIUS), default=0) * track.ds),
        "corners": len(corners),
        "share_tighter_than_15m": float(np.mean(k > 1 / 15.0)),
    }
