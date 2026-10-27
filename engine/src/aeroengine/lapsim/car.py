"""Car parameters. SI throughout. The app owns the placeholder values; the
engine insists every field is given so there is one source of defaults."""

from __future__ import annotations

from dataclasses import dataclass, fields
from typing import Any

from ..job import EngineError


@dataclass(frozen=True)
class Car:
    mass: float  # kg, with driver
    cla: float  # m^2, downforce = 1/2 rho ClA v^2
    cda: float  # m^2, drag = 1/2 rho CdA v^2
    mu_lat: float  # lateral tyre friction coefficient
    mu_long: float  # longitudinal tyre friction coefficient
    power: float  # W, peak drive power at the wheels
    driven_axle_fraction: float  # static weight share on the driven axle, 0..1
    aero_balance_driven: float  # downforce share on the driven axle, 0..1
    crr: float  # rolling resistance coefficient, applied to static weight
    rho: float  # kg/m^3, air density
    v_max: float  # m/s, speed cap

    @classmethod
    def from_dict(cls, data: Any, label: str = "car") -> "Car":
        if not isinstance(data, dict):
            raise EngineError(f"{label} must be a JSON object")
        names = [f.name for f in fields(cls)]
        missing = [n for n in names if n not in data]
        if missing:
            raise EngineError(f"{label} is missing {', '.join(missing)}")
        values: dict[str, float] = {}
        for n in names:
            v = data[n]
            if isinstance(v, bool) or not isinstance(v, (int, float)):
                raise EngineError(f"{label}.{n} must be a number, got {v!r}")
            values[n] = float(v)
        car = cls(**values)
        car.validate(label)
        return car

    def validate(self, label: str = "car") -> None:
        positive = ["mass", "mu_lat", "mu_long", "power", "rho", "v_max"]
        non_negative = ["cla", "cda", "crr"]
        fractions = ["driven_axle_fraction", "aero_balance_driven"]
        for n in positive:
            if not getattr(self, n) > 0:
                raise EngineError(f"{label}.{n} must be greater than 0")
        for n in non_negative:
            if getattr(self, n) < 0:
                raise EngineError(f"{label}.{n} must not be negative")
        for n in fractions:
            if not 0 <= getattr(self, n) <= 1:
                raise EngineError(f"{label}.{n} must be between 0 and 1")

    def to_dict(self) -> dict[str, float]:
        return {f.name: getattr(self, f.name) for f in fields(self)}
