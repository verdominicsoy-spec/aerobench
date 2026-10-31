"""Load transfer and tyre load sensitivity in the Lap Sim."""

from __future__ import annotations

from dataclasses import replace

import numpy as np
import pytest

from aeroengine.job import EngineError
from aeroengine.lapsim import Car, simulate
from aeroengine.lapsim.solver import axle_ratio, corner_speed
from aeroengine.lapsim.track import resolve

BASE = Car(mass=280, cla=3.0, cda=1.2, mu_lat=1.5, mu_long=1.4, power=80000, driven_axle_fraction=0.55,
           aero_balance_driven=0.55, crr=0.015, rho=1.225, v_max=33)
ON = replace(BASE, cog_height=0.28, wheelbase=1.53, track_width=1.2, tyre_load_sensitivity=0.15)


def test_off_by_default_and_matching_balance_with_no_sensitivity_is_the_point_mass():
    k = np.array([0.0, 0.02, 0.05, 0.11])
    assert not BASE.axles
    # Balance equal to the weight split and mu independent of load: each axle
    # is the point mass in proportion, so the speeds agree.
    linear = replace(BASE, cog_height=0.28, wheelbase=1.53, track_width=1.2)
    assert corner_speed(linear, k) == pytest.approx(corner_speed(BASE, k), rel=1e-6)


def test_load_sensitivity_and_aero_balance_cost_cornering_speed():
    k = np.array([1 / 9.125])  # skidpad radius
    v_on = corner_speed(ON, k)[0]
    assert v_on < corner_speed(BASE, k)[0]  # tyres give less grip per unit load as load rises
    assert axle_ratio(ON, v_on, k[0]) == pytest.approx(1.0, abs=1e-6)
    # Downforce all at the front: the rear runs out first.
    assert corner_speed(replace(ON, aero_balance_driven=0.0), k)[0] < v_on


def test_rear_drive_gains_traction_under_acceleration():
    track = resolve({"builtin": "acceleration"})
    low_power = dict(power=200000, cla=0.0)  # traction-limited the whole way
    flat = simulate(replace(BASE, **low_power, cog_height=0.0, tyre_load_sensitivity=1e-9, wheelbase=1.53, track_width=1.2), track)
    tall = simulate(replace(BASE, **low_power, cog_height=0.35, tyre_load_sensitivity=1e-9, wheelbase=1.53, track_width=1.2), track)
    assert tall.lap_time < flat.lap_time


def test_lap_and_validation():
    track = resolve({"builtin": "fsg_2019"})
    base = simulate(BASE, track).lap_time
    # Load sensitivity alone only costs cornering grip.
    assert simulate(replace(BASE, tyre_load_sensitivity=0.15), track).lap_time > base
    # With the CoG height too, the rear-drive traction out of FSG's slow
    # corners more than pays for it (22.22 s against 22.31 s): both effects are real.
    assert simulate(ON, track).lap_time == pytest.approx(base, rel=0.02)
    with pytest.raises(EngineError, match="wheelbase"):
        Car.from_dict({**BASE.to_dict(), "cog_height": 0.3})
    assert Car.from_dict({k: v for k, v in BASE.to_dict().items() if k not in ("cog_height", "wheelbase")}) == BASE
