"""Generated event tracks: within the rules, the same for a seed, legal loops."""

from __future__ import annotations

import numpy as np
import pytest

from aeroengine.job import EngineError
from aeroengine.lapsim import Car, simulate
from aeroengine.lapsim.generate import _crosses, describe, generate, rules
from aeroengine.lapsim.track import resolve


@pytest.mark.parametrize("seed", [0, 1, 2, 7])
def test_endurance_layouts_keep_to_the_rules(seed):
    r = rules("endurance")
    t = generate(seed)
    d = describe(t)
    assert t.closed and d["length"] == pytest.approx(r["lap_length_m"], rel=0.05)
    assert d["min_radius"] >= r["turning_diameter_min_m"] / 2
    assert d["longest_straight"] <= r["straight_max_m"]
    assert not _crosses(t.x, t.y)
    assert 0.08 < d["share_tighter_than_15m"] < 0.5 and d["corners"] >= 15
    # A slalom: curvature swinging both ways at about the rules' cone spacing.
    assert (t.kappa > 0.03).any() and (t.kappa < -0.03).any()


def test_same_seed_same_track_and_the_lap_sim_runs_it():
    a, b = generate(3), resolve({"generated": 3})
    assert np.allclose(a.x, b.x) and a.name == "Generated endurance #3"
    car = Car(mass=280, cla=3.0, cda=1.2, mu_lat=1.5, mu_long=1.4, power=80000, driven_axle_fraction=0.55,
              aero_balance_driven=0.55, crr=0.015, rho=1.225, v_max=33)
    lap = simulate(car, b).lap_time
    assert 45 < lap < 90  # about 1 km at FS speeds


def test_autocross_is_open_and_unknown_events_say_what_exists():
    t = generate(1, "autocross")
    assert not t.closed and t.length < rules("autocross")["lap_length_max_m"]
    with pytest.raises(EngineError, match="skidpad") as err:
        generate(1, "skidpad")
    assert "endurance" in err.value.detail and "autocross" in err.value.detail
