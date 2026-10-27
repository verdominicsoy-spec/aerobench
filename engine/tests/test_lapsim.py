"""Lap Sim. The four acceptance checks from spec section 5 are marked."""

from __future__ import annotations

import json
import math
from dataclasses import replace
from pathlib import Path

import numpy as np
import pytest
from scipy.integrate import solve_ivp

from aeroengine.job import EngineError
from aeroengine.lapsim import Car, simulate
from aeroengine.lapsim import track as tracks
from aeroengine.lapsim.analysis import sensitivities
from aeroengine.lapsim.solver import G

CAR = Car(
    mass=280.0, cla=3.5, cda=1.3, mu_lat=1.5, mu_long=1.4, power=80e3,
    driven_axle_fraction=0.55, aero_balance_driven=0.55, crr=0.015, rho=1.225, v_max=33.0,
)
BUILTINS = {
    "skidpad": lambda ds=0.5: tracks.skidpad(ds=ds),
    "acceleration": lambda ds=0.5: tracks.acceleration(ds=ds),
    "test_track": lambda ds=0.5: tracks.test_track(ds=ds),
}


# Acceptance check 1 ---------------------------------------------------------

def test_skidpad_without_downforce_runs_exactly_at_the_grip_limit():
    car = replace(CAR, cla=0.0)
    track = tracks.skidpad()
    lap = simulate(car, track)
    expected = math.sqrt(car.mu_lat * G * tracks.SKIDPAD_RADIUS)
    assert np.allclose(lap.v, expected, rtol=1e-12, atol=0)
    assert lap.lap_time == pytest.approx(2 * math.pi * tracks.SKIDPAD_RADIUS / expected, rel=1e-12)


def test_skidpad_with_downforce_matches_the_closed_form():
    track = tracks.skidpad()
    lap = simulate(CAR, track)
    k = 1 / tracks.SKIDPAD_RADIUS
    expected = math.sqrt(CAR.mu_lat * CAR.mass * G / (CAR.mass * k - 0.5 * CAR.mu_lat * CAR.rho * CAR.cla))
    assert np.allclose(lap.v, expected, rtol=1e-12)


# Acceptance check 2 ---------------------------------------------------------

def _accel_by_time_integration(car: Car, length: float) -> float:
    """Independent check: integrate m dv/dt = F_drive - drag - rolling in time
    until the car has covered `length`."""

    def rhs(_t, y):
        v = y[1]
        traction = car.mu_long * (car.mass * G * car.driven_axle_fraction + 0.5 * car.rho * car.cla * v * v * car.aero_balance_driven)
        drive = traction if v <= 0 else min(traction, car.power / v)
        a = (drive - 0.5 * car.rho * car.cda * v * v - car.crr * car.mass * G) / car.mass
        if v >= car.v_max:
            a = min(a, 0.0)
        return [v, a]

    done = lambda _t, y: y[0] - length  # noqa: E731
    done.terminal = True
    sol = solve_ivp(rhs, (0, 60), [0.0, 0.0], events=done, rtol=1e-10, atol=1e-10, max_step=0.01)
    return float(sol.t_events[0][0])


@pytest.mark.parametrize("car", [CAR, replace(CAR, power=40e3), replace(CAR, cla=0.0, cda=0.8), replace(CAR, v_max=20.0)])
def test_acceleration_run_matches_a_hand_calculation(car):
    lap = simulate(car, tracks.acceleration())
    reference = _accel_by_time_integration(car, tracks.ACCEL_LENGTH)
    assert lap.lap_time == pytest.approx(reference, rel=0.01)


def test_acceleration_traction_limited_closed_form():
    # No aero, no rolling resistance, effectively unlimited power: constant
    # acceleration mu_long g f, so t = sqrt(2 L / a).
    car = replace(CAR, cla=0.0, cda=0.0, crr=0.0, power=1e9, v_max=1e3)
    a = car.mu_long * G * car.driven_axle_fraction
    lap = simulate(car, tracks.acceleration())
    assert lap.lap_time == pytest.approx(math.sqrt(2 * tracks.ACCEL_LENGTH / a), rel=1e-9)


# Acceptance check 3 ---------------------------------------------------------

@pytest.mark.parametrize("name", BUILTINS)
def test_more_cla_is_never_slower(name):
    track = BUILTINS[name]()
    times = [simulate(replace(CAR, cla=c), track).lap_time for c in np.linspace(0, 6, 25)]
    assert all(b <= a + 1e-12 for a, b in zip(times, times[1:])), times


@pytest.mark.parametrize("name", BUILTINS)
def test_more_cda_is_never_faster(name):
    track = BUILTINS[name]()
    times = [simulate(replace(CAR, cda=c), track).lap_time for c in np.linspace(0, 3, 25)]
    assert all(b >= a - 1e-12 for a, b in zip(times, times[1:])), times


def test_monotonic_on_an_imported_track(tmp_path):
    x, y = _wobbly_loop()
    track = tracks.from_points(x, y, closed=True)
    t_cla = [simulate(replace(CAR, cla=c), track).lap_time for c in np.linspace(0, 6, 13)]
    t_cda = [simulate(replace(CAR, cda=c), track).lap_time for c in np.linspace(0, 3, 13)]
    assert all(b <= a + 1e-12 for a, b in zip(t_cla, t_cla[1:]))
    assert all(b >= a - 1e-12 for a, b in zip(t_cda, t_cda[1:]))


# Acceptance check 4 ---------------------------------------------------------

@pytest.mark.parametrize("name", BUILTINS)
def test_halving_the_step_changes_lap_time_under_half_a_percent(name):
    coarse = simulate(CAR, BUILTINS[name](0.5)).lap_time
    fine = simulate(CAR, BUILTINS[name](0.25)).lap_time
    assert abs(fine - coarse) / fine < 0.005


def test_halving_the_step_on_an_imported_track():
    x, y = _wobbly_loop()
    coarse = simulate(CAR, tracks.from_points(x, y, closed=True, ds=0.5)).lap_time
    fine = simulate(CAR, tracks.from_points(x, y, closed=True, ds=0.25)).lap_time
    assert abs(fine - coarse) / fine < 0.005


# Physics sanity -------------------------------------------------------------

def test_speed_never_exceeds_cornering_limit_or_cap():
    lap = simulate(CAR, tracks.test_track())
    assert (lap.v <= np.minimum(lap.v_corner, CAR.v_max) + 1e-9).all()


def test_closed_lap_is_periodic():
    lap = simulate(CAR, tracks.test_track())
    assert lap.v[0] == pytest.approx(lap.v[-1], rel=1e-9)


def test_accel_energy_balances_kinetic_plus_losses():
    car = CAR
    lap = simulate(car, tracks.acceleration(ds=0.1))
    v = lap.v
    v_mid = 0.5 * (v[1:] + v[:-1])
    losses = ((0.5 * car.rho * car.cda * v_mid**2 + car.crr * car.mass * G) * 0.1).sum()
    assert lap.energy == pytest.approx(0.5 * car.mass * v[-1] ** 2 + losses, rel=0.01)


def test_sensitivity_signs_and_exchange_rate():
    sens = sensitivities(CAR, tracks.test_track())
    assert sens["dt_dcla"] < 0
    assert sens["dt_dcda"] > 0
    assert sens["cla_per_cda"] == pytest.approx(sens["dt_dcda"] / -sens["dt_dcla"])
    # Swapping that much ClA for one unit of CdA leaves the lap time unchanged
    # to first order.
    t0 = simulate(CAR, tracks.test_track()).lap_time
    d = 0.05
    t1 = simulate(replace(CAR, cda=CAR.cda + d, cla=CAR.cla + d * sens["cla_per_cda"]), tracks.test_track()).lap_time
    assert abs(t1 - t0) < 0.02 * abs(sens["dt_dcda"] * d)


def test_exchange_rate_is_none_when_downforce_does_not_help():
    # Speed capped below the skidpad's grip limit, so ClA changes nothing.
    sens = sensitivities(replace(CAR, v_max=5.0), tracks.skidpad())
    assert sens["dt_dcla"] == 0
    assert sens["cla_per_cda"] is None


def test_central_difference_falls_back_at_zero_cla():
    sens = sensitivities(replace(CAR, cla=0.0), tracks.test_track())
    assert sens["method"]["cla"] == "forward"


# Tracks ---------------------------------------------------------------------

def _wobbly_loop(n=400, r=40.0):
    th = np.linspace(0, 2 * np.pi, n, endpoint=False)
    rr = r * (1 + 0.2 * np.cos(3 * th))
    return rr * np.cos(th), rr * np.sin(th)


def test_builtin_track_geometry():
    sk = tracks.skidpad()
    assert sk.closed and sk.length == pytest.approx(2 * math.pi * 9.125)
    acc = tracks.acceleration()
    assert not acc.closed and acc.length == 75.0
    tt = tracks.test_track()
    assert tt.closed and 370 < tt.length < 390
    assert 1 / np.abs(tt.kappa).max() > 12
    assert tt.kappa.min() < 0 < tt.kappa.max()  # has a reverse-curvature section


def test_spline_recovers_curvature_of_a_noisy_circle():
    rng = np.random.default_rng(1)
    th = np.linspace(0, 2 * np.pi, 300, endpoint=False)
    r = 25.0
    x = r * np.cos(th) + rng.normal(0, 0.02, th.size)
    y = r * np.sin(th) + rng.normal(0, 0.02, th.size)
    t = tracks.from_points(x, y, smoothing=0.05)
    assert t.closed
    assert t.length == pytest.approx(2 * math.pi * r, rel=0.002)
    assert np.median(t.kappa) == pytest.approx(1 / r, rel=0.01)


def test_csv_import_skips_headers_detects_closure_and_scales(tmp_path: Path):
    x, y = _wobbly_loop()
    csv = tmp_path / "loop.csv"
    csv.write_text("# exported centreline\nx_mm,y_mm\n" + "\n".join(f"{a*1000:.3f},{b*1000:.3f}" for a, b in zip(x, y)))
    t = tracks.resolve({"csv": str(csv), "scale": 0.001})
    assert t.closed
    ref = tracks.from_points(x, y, closed=True)
    # The file is rounded to 1 micron, which shifts the smoothing spline's
    # knots slightly (by ~25 ppm in length on macOS's scipy). A wrong unit
    # scale or closure would be off by orders of magnitude more.
    assert t.length == pytest.approx(ref.length, rel=1e-3)


def test_open_csv_is_detected_as_open(tmp_path: Path):
    csv = tmp_path / "straight.csv"
    csv.write_text("\n".join(f"{i} {0.001*i*i}" for i in range(100)))
    assert not tracks.resolve({"csv": str(csv)}).closed


def test_bad_track_specs_are_engine_errors(tmp_path: Path):
    with pytest.raises(EngineError):
        tracks.resolve({"builtin": "monza"})
    with pytest.raises(EngineError):
        tracks.resolve({})
    (tmp_path / "short.csv").write_text("0,0\n1,1\n")
    with pytest.raises(EngineError):
        tracks.resolve({"csv": str(tmp_path / "short.csv")})


def test_car_validation_names_what_is_wrong():
    with pytest.raises(EngineError, match="missing cda"):
        Car.from_dict({k: v for k, v in CAR.to_dict().items() if k != "cda"})
    with pytest.raises(EngineError, match="driven_axle_fraction"):
        Car.from_dict({**CAR.to_dict(), "driven_axle_fraction": 1.5})
    with pytest.raises(EngineError, match="must be a number"):
        Car.from_dict({**CAR.to_dict(), "mass": "heavy"})


# The command, end to end ----------------------------------------------------

def test_lapsim_command_compares_two_configs(engine, tmp_path: Path):
    workdir = tmp_path / "job"
    job = {
        "command": "lapsim",
        "params": {
            "car": CAR.to_dict(),
            "car_b": {**CAR.to_dict(), "cla": 4.5},
            "track": {"builtin": "test_track"},
            "laps": 22,
        },
    }
    code, events, stderr = engine.run("lapsim", job, workdir, timeout=120)
    assert code == 0, (events, stderr)
    data = json.loads((workdir / "result.json").read_text())["data"]
    a, b = data["a"], data["b"]
    assert b["lap_time"] < a["lap_time"]
    n = len(data["track"]["s"])
    assert len(a["v"]) == len(a["t"]) == len(b["v"]) == len(data["delta_t"]) == n
    assert data["delta_t"][-1] == pytest.approx(b["lap_time"] - a["lap_time"], abs=1e-3)
    assert a["endurance"]["time"] == pytest.approx(22 * a["lap_time"])
    assert a["sensitivity"]["dt_dcla"] < 0
    pcts = [e["pct"] for e in events if e["type"] == "progress"]
    assert pcts == sorted(pcts)


def test_lapsim_command_reports_bad_input(engine, tmp_path: Path):
    code, events, _ = engine.run("lapsim", {"params": {"car": {"mass": 280}, "track": {"builtin": "skidpad"}}}, tmp_path / "job")
    assert code == 1
    assert events[-1]["type"] == "error" and "missing" in events[-1]["msg"]
