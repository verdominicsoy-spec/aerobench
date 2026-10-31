"""lapsim: one to five car configs around one track."""

from __future__ import annotations

import numpy as np

from ..job import EngineError, JobContext
from ..lapsim import Car, simulate
from ..lapsim.analysis import sensitivities
from ..lapsim.track import DEFAULT_DS, resolve
from . import command


MAX_CARS = 5
LABELS = "ABCDE"


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

    # "cars" (A to E); older jobs send "car" and an optional "car_b".
    raw = p.get("cars") or [p.get("car")] + ([p["car_b"]] if p.get("car_b") is not None else [])
    if not 1 <= len(raw) <= MAX_CARS:
        raise EngineError(f"between 1 and {MAX_CARS} cars, not {len(raw)}")
    cars = [Car.from_dict(c, f"car {LABELS[i]}") for i, c in enumerate(raw)]

    ctx.emit.progress(2, "building track")
    track = resolve(p.get("track"), ds)
    ctx.emit.log(f"track '{track.name}': {track.length:.1f} m, {'closed' if track.closed else 'open'}, {len(track.x)} nodes")

    configs = []
    for i, car in enumerate(cars):
        lo = 10 + 85 * i / len(cars)
        configs.append({"label": LABELS[i], **_config(ctx, car, track, start_speed, laps, want_sens, LABELS[i],
                                                       (lo + 85 / len(cars) / 2, lo + 85 / len(cars)))})
    # Each car's time gained (negative) or lost along the lap against A.
    deltas = [None] + [_arr(np.asarray(c["t"]) - np.asarray(configs[0]["t"])) for c in configs[1:]]

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
        "configs": configs,
        "deltas": deltas,
        # The first two as before, for readers of the A/B result.
        "a": configs[0],
        "b": configs[1] if len(configs) > 1 else None,
        "delta_t": deltas[1] if len(configs) > 1 else None,
    }
