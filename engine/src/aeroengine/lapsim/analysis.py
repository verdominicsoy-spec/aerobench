"""Sensitivities, the ClA/CdA exchange rate, and config comparison."""

from __future__ import annotations

from dataclasses import replace

from .car import Car
from .solver import simulate
from .track import Track


def sensitivities(car: Car, track: Track, start_speed: float = 0.0, rel_step: float = 0.05) -> dict:
    """dt/dClA and dt/dCdA by finite differences (central where the step
    stays physical, forward otherwise), and how much ClA one unit of CdA is
    worth at equal lap time."""

    def lap_time(**change) -> float:
        return simulate(replace(car, **change), track, start_speed).lap_time

    def derivative(name: str, floor: float) -> tuple[float, float, str]:
        x = getattr(car, name)
        h = max(rel_step * abs(x), floor)
        if x - h >= 0:
            return (lap_time(**{name: x + h}) - lap_time(**{name: x - h})) / (2 * h), h, "central"
        return (lap_time(**{name: x + h}) - lap_time()) / h, h, "forward"

    dt_dcla, h_cla, m_cla = derivative("cla", 0.05)
    dt_dcda, h_cda, m_cda = derivative("cda", 0.02)
    # At equal lap time: dt/dClA dClA + dt/dCdA dCdA = 0.
    exchange = dt_dcda / -dt_dcla if dt_dcla < -1e-9 else None
    return {
        "dt_dcla": dt_dcla,
        "dt_dcda": dt_dcda,
        "cla_per_cda": exchange,
        "step_cla": h_cla,
        "step_cda": h_cda,
        "method": {"cla": m_cla, "cda": m_cda},
    }
