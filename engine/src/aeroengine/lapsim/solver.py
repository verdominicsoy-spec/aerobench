"""Quasi-steady point-mass solver.

Cornering limit, with downforce:
    m v^2 k = mu_lat (m g + 1/2 rho ClA v^2)
    v^2 = mu_lat m g / (m k - 1/2 mu_lat rho ClA), uncapped if the denominator <= 0

Forward pass: drive force is the smaller of P / v and traction on the driven
axle (static share plus its share of downforce), scaled by the friction circle
for the lateral grip in use, minus drag and rolling resistance. Backward pass:
braking on all four tyres, same friction circle, helped by drag and rolling
resistance. Speed is the minimum of the cornering limit and both passes.
Steps integrate v^2 over distance with Heun's method.

With load transfer on (car.axles: a CoG height or a tyre load sensitivity),
each axle must hold its own share of the cornering force (front and rear in
proportion to the static weight, by moments about the CoG) with its own
load: static weight, its share of the downforce, and the lateral load
transfer m a_y h / t across it, shared the same way. Each tyre's mu falls
with its load, mu (1 - k (Fz / Fz0 - 1)) with Fz0 its static load. The axle
that runs out first sets the cornering speed, so the aero balance against
the weight distribution matters. Traction on the driven axle (the rear)
gains the longitudinal transfer m a h / L. Braking keeps the total grip.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from ..job import EngineError
from .car import Car
from .track import Track

G = 9.81


@dataclass
class Lap:
    s: np.ndarray
    v: np.ndarray  # m/s at each node
    t: np.ndarray  # cumulative time at each node, s
    v_corner: np.ndarray  # cornering limit at each node
    drive_force: np.ndarray  # per segment, N (0 when braking or coasting)
    lap_time: float
    energy: float  # J, integral of drive force over distance

    def summary(self) -> dict:
        return {
            "lap_time": self.lap_time,
            "energy": self.energy,
            "v_min": float(self.v.min()),
            "v_max": float(self.v.max()),
            "v_avg": float(self.s[-1] / self.lap_time),
        }


def axle_ratio(car: Car, v, kappa):
    """Lateral force needed over grip available, for the worse axle (1 is
    the limit). Works on floats or arrays."""
    v2 = np.asarray(v, float) ** 2
    ay = v2 * np.abs(kappa)
    q = 0.5 * car.rho * v2
    worst = np.zeros_like(ay)
    for weight, aero in ((1 - car.driven_axle_fraction, 1 - car.aero_balance_driven),
                         (car.driven_axle_fraction, car.aero_balance_driven)):
        if weight <= 0:
            continue
        fz = car.mass * G * weight + q * car.cla * aero
        fy = car.mass * ay * weight
        shift = fy * car.cog_height / car.track_width if car.track_width > 0 else 0.0 * fy
        outer = np.minimum(fz / 2 + shift, fz)
        inner = np.maximum(fz / 2 - shift, 0.0)
        static = car.mass * G * weight / 2
        k = car.tyre_load_sensitivity

        def grip(f):
            return car.mu_lat * np.maximum(1 - k * (f / static - 1), 0.0) * f

        worst = np.maximum(worst, fy / np.maximum(grip(outer) + grip(inner), 1e-9))
    return worst


def corner_speed(car: Car, kappa: np.ndarray) -> np.ndarray:
    if car.axles:
        # The ratio rises with speed, so bisect for where it reaches 1.
        lo, hi = np.zeros_like(kappa, dtype=float), np.full(len(kappa), float(car.v_max))
        free = axle_ratio(car, hi, kappa) <= 1
        for _ in range(48):
            mid = 0.5 * (lo + hi)
            ok = axle_ratio(car, mid, kappa) <= 1
            lo, hi = np.where(ok, mid, lo), np.where(ok, hi, mid)
        return np.where(free, car.v_max, lo)
    k = np.abs(kappa)
    denom = car.mass * k - 0.5 * car.mu_lat * car.rho * car.cla
    with np.errstate(divide="ignore", invalid="ignore"):
        v = np.sqrt(car.mu_lat * car.mass * G / denom)
    v = np.where(denom > 0, v, np.inf)
    return np.minimum(v, car.v_max)


class _Physics:
    """Scalar force model, kept in plain floats because it runs per node."""

    def __init__(self, car: Car) -> None:
        self.car = car
        self.axles = car.axles
        if car.axles:
            # The same sums as axle_ratio, in plain floats: it runs per node.
            self.axle_terms = [
                (car.mass * G * w, car.cla * a, car.mass * w, car.mass * G * w / 2)
                for w, a in ((1 - car.driven_axle_fraction, 1 - car.aero_balance_driven),
                             (car.driven_axle_fraction, car.aero_balance_driven)) if w > 0
            ]
            self.h_over_t = car.cog_height / car.track_width if car.track_width > 0 else 0.0
            self.sens = car.tyre_load_sensitivity
        self.transfer = car.cog_height / car.wheelbase if car.axles and car.wheelbase > 0 else 0.0
        self.m = car.mass
        self.half_rho = 0.5 * car.rho
        self.cla, self.cda = car.cla, car.cda
        self.mu_lat, self.mu_long = car.mu_lat, car.mu_long
        self.power = car.power
        self.w_driven = car.mass * G * car.driven_axle_fraction
        self.bal = car.aero_balance_driven
        self.roll = car.crr * car.mass * G  # static weight only, see DECISIONS.md

    def _axle_ratio(self, v: float, k: float, q: float) -> float:
        ay = v * v * abs(k)
        worst = 0.0
        mu, sens, h_t = self.mu_lat, self.sens, self.h_over_t
        for weight, aero, mass_w, static in self.axle_terms:
            fz = weight + q * aero
            fy = mass_w * ay
            shift = fy * h_t
            outer = min(fz / 2 + shift, fz)
            inner = max(fz / 2 - shift, 0.0)
            grip = mu * (max(1 - sens * (outer / static - 1), 0.0) * outer + max(1 - sens * (inner / static - 1), 0.0) * inner)
            worst = max(worst, fy / max(grip, 1e-9))
        return worst

    def _long_share(self, v: float, k: float, q: float) -> float:
        if self.axles:
            r = self._axle_ratio(v, k, q)
        else:
            lat = self.m * v * v * abs(k)
            grip = self.mu_lat * (self.m * G + q * self.cla)
            r = lat / grip
        return math.sqrt(1.0 - r * r) if r < 1.0 else 0.0

    def accel(self, v: float, k: float) -> float:
        q = self.half_rho * v * v
        load = self.w_driven + q * self.cla * self.bal
        if self.transfer:
            # The rear gains m a h / L as the car accelerates, and a depends on
            # the traction: Fx = mu (load + h/L (Fx - D - R)), solved for Fx.
            resist = q * self.cda + self.roll
            denom = 1.0 - self.mu_long * self.transfer
            if denom > 0:
                load = max((load - self.transfer * resist) / denom, 0.0)
        traction = self.mu_long * load * self._long_share(v, k, q)
        drive = traction if v <= 0 else min(traction, self.power / v)
        # Negative means the car cannot gain speed here; it holds speed
        # rather than being slowed by the forward pass (braking is the
        # backward pass's job). This is what makes a constant-radius corner
        # run exactly at its cornering limit.
        return max((drive - q * self.cda - self.roll) / self.m, 0.0)

    def decel(self, v: float, k: float) -> float:
        q = self.half_rho * v * v
        brake = self.mu_long * (self.m * G + q * self.cla) * self._long_share(v, k, q)
        return (brake + q * self.cda + self.roll) / self.m


def _forward(phys: _Physics, kappa: np.ndarray, vc2: np.ndarray, ds: float, u0: float) -> np.ndarray:
    n = len(kappa)
    u = np.empty(n)
    u[0] = min(u0, vc2[0])
    k = kappa.tolist()
    cap = vc2.tolist()
    for i in range(n - 1):
        ui = u[i]
        k1 = 2 * phys.accel(math.sqrt(ui), k[i])
        up = min(ui + ds * k1, cap[i + 1])
        k2 = 2 * phys.accel(math.sqrt(up), k[i + 1])
        u[i + 1] = min(ui + ds * 0.5 * (k1 + k2), cap[i + 1])
    return u


def _backward(phys: _Physics, kappa: np.ndarray, vc2: np.ndarray, ds: float, u_end: float) -> np.ndarray:
    n = len(kappa)
    u = np.empty(n)
    u[-1] = min(u_end, vc2[-1])
    k = kappa.tolist()
    cap = vc2.tolist()
    for i in range(n - 1, 0, -1):
        ui = u[i]
        k1 = 2 * phys.decel(math.sqrt(ui), k[i])
        up = min(ui + ds * k1, cap[i - 1])
        k2 = 2 * phys.decel(math.sqrt(up), k[i - 1])
        u[i - 1] = min(ui + ds * 0.5 * (k1 + k2), cap[i - 1])
    return u


def simulate(car: Car, track: Track, start_speed: float = 0.0) -> Lap:
    """One lap. Closed tracks give a flying lap; open tracks start at
    `start_speed` and finish without having to brake."""
    ds = track.ds
    phys = _Physics(car)
    vc = corner_speed(car, track.kappa)
    vc2 = vc**2  # inf where grip never limits and v_max is inf (it never is)

    if track.closed:
        # Three laps back to back; the middle one is free of start and end
        # effects because every corner resets the speed.
        n = len(track.kappa) - 1
        kappa3 = np.concatenate([np.tile(track.kappa[:-1], 3), track.kappa[:1]])
        vc2_3 = np.concatenate([np.tile(vc2[:-1], 3), vc2[:1]])
        u = np.minimum(_forward(phys, kappa3, vc2_3, ds, vc2[0]), _backward(phys, kappa3, vc2_3, ds, vc2[0]))
        u = u[n : 2 * n + 1]
    else:
        if start_speed < 0:
            raise EngineError("start speed must not be negative")
        u = np.minimum(
            _forward(phys, track.kappa, vc2, ds, start_speed**2),
            _backward(phys, track.kappa, vc2, ds, math.inf),
        )

    v = np.sqrt(np.maximum(u, 0.0))
    v_sum = v[1:] + v[:-1]
    if (v_sum <= 0).any():
        raise EngineError("the car never gets moving", "check power, mass and grip")
    dt = 2 * ds / v_sum  # exact for constant acceleration over a segment
    t = np.concatenate([[0.0], np.cumsum(dt)])

    a = (v[1:] ** 2 - v[:-1] ** 2) / (2 * ds)
    v_mid = 0.5 * v_sum
    force = car.mass * a + 0.5 * car.rho * car.cda * v_mid**2 + phys.roll
    drive = np.maximum(force, 0.0)
    s = track.s
    return Lap(s, v, t, vc, drive, float(t[-1]), float((drive * ds).sum()))
