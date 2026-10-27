"""lapsim: one or two car configs around one track."""

from __future__ import annotations

import numpy as np

from ..job import EngineError, JobContext
from ..lapsim import Car, simulate
from ..lapsim.analysis import sensitivities
from ..lapsim.track import DEFAULT_DS, resolve
from . import command


def _arr(a: np.ndarray, digits: int = 4) -> list[float]:
    return np.round(a, digits).tolist()


def _config(ctx: JobContext, car: Car, track, start_speed: float, laps: int, want_sens: bool, label: str, pct: tuple[float, float]) -> dict:
    lap = simulate(car, track, start_speed)
    ctx.emit.progress(pct[0], f"config {label}: lap {lap.lap_time:.3f} s")
    out = {
        "car": car.to_dict(),
        **lap.summary(),
        "endurance": {"laps": laps, "time": lap.lap_time * laps, "energy": lap.energy * laps},
        "v": _arr(lap.v),
        "t": _arr(lap.t),
        "v_corner": _arr(np.minimum(lap.v_corner, car.v_max)),
        "sensitivity": None,
    }
    if want_sens:
        out["sensitivity"] = sensitivities(car, track, start_speed)
        ctx.emit.progress(pct[1], f"config {label}: sensitivities done")
    return out


@command("lapsim")
def lapsim(ctx: JobContext) -> dict:
    p = ctx.params
    ds = float(p.get("ds", DEFAULT_DS))
    laps = int(p.get("laps", 22))
    start_speed = float(p.get("start_speed", 0.0))
    want_sens = bool(p.get("sensitivities", True))
    if laps < 1:
        raise EngineError("laps must be at least 1")

    car_a = Car.from_dict(p.get("car"), "car")
    car_b = Car.from_dict(p["car_b"], "car_b") if p.get("car_b") is not None else None

    ctx.emit.progress(2, "building track")
    track = resolve(p.get("track"), ds)
    ctx.emit.log(f"track '{track.name}': {track.length:.1f} m, {'closed' if track.closed else 'open'}, {len(track.x)} nodes")

    a = _config(ctx, car_a, track, start_speed, laps, want_sens, "A", (20, 55) if car_b else (40, 95))
    b = _config(ctx, car_b, track, start_speed, laps, want_sens, "B", (70, 95)) if car_b else None

    delta = None
    if b is not None:
        delta = _arr(np.asarray(b["t"]) - np.asarray(a["t"]))

    return {
        "track": {
            "name": track.name,
            "length": track.length,
            "closed": track.closed,
            "ds": track.ds,
            "s": _arr(track.s),
            "x": _arr(track.x),
            "y": _arr(track.y),
            "kappa": _arr(track.kappa, 6),
        },
        "start_speed": start_speed,
        "a": a,
        "b": b,
        "delta_t": delta,
    }
