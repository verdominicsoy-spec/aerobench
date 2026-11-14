"""A vortex lattice for the induced angle on the car: a flat rectangular wing
with vertical endplates at both tips and the ground as a mirror image.

Lifting line with Hoerner's endplate rule and Wieselsberger's ground factor
is made for slender wings; a front wing between tall endplates whose bottoms
nearly touch the ground (frontwing#1: aspect ratio 0.77, endplates 60% of the
span, 35 mm under them) is far outside it. Here the planform is solved as it
is: horseshoe vortices on the wing and on both endplates (Bertin & Cummings),
no flow through either, every vortex mirrored under the ground with the
opposite sign.

Two induced angles come out, per unit of the wing's CL (linear: everything
scales with the lift):
- k_drag: the trailing vortices' downwash at the wing, Cdi / CL from the wake
  far behind (Trefftz plane). Lifting line's angle, and the one finite.py
  turns the RANS section by. Free air: span efficiency 0.98-1 on short
  rectangular wings. Over a ground: within 2% of Wieselsberger to h/b 0.2.
- k_lift: the angle a flat 2D section must turn by to carry the 3D lift,
  1 / CL_alpha - 1 / a2D, with a2D the same chordwise lattice on an endless
  span at the same height. It adds the lifting surface's own loss, and runs
  30-60% above k_drag. On Zerihan's wing it put the on-car lift 5-12% under
  the balance where k_drag lands within 3% (docs/validation/ground-3d), so it
  is reported, not used."""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

FAR = 1e3  # trailing legs this many spans downstream stand for infinite ones
CORE = 1e-14  # a point this close (squared, m^2) to a vortex line's axis gets no velocity from it


def _segments(a: np.ndarray, b: np.ndarray, p: np.ndarray) -> np.ndarray:
    """Velocity at points p (n, 3) from unit vortex segments a -> b (m, 3): (n, m, 3)."""
    r1 = p[:, None, :] - a[None, :, :]
    r2 = p[:, None, :] - b[None, :, :]
    cross = np.cross(r1, r2)
    c2 = np.einsum("nmk,nmk->nm", cross, cross)
    n1, n2 = np.linalg.norm(r1, axis=2), np.linalg.norm(r2, axis=2)
    r0 = (b - a)[None, :, :]
    dot = np.einsum("nmk,nmk->nm", r0, r1 / np.maximum(n1, CORE)[..., None] - r2 / np.maximum(n2, CORE)[..., None])
    on_axis = c2 <= CORE * np.einsum("nmk,nmk->nm", r0, r0)  # squared distance from the line under CORE m^2
    scale = np.where(on_axis, 0.0, dot / (4 * math.pi * np.maximum(c2, 1e-300)))
    return cross * scale[..., None]


def _horseshoes(a: np.ndarray, b: np.ndarray, p: np.ndarray, far: float) -> np.ndarray:
    """Unit horseshoes: a leg from far downstream to a, bound a -> b, b back downstream."""
    down = np.array([far, 0.0, 0.0])
    return _segments(a + down, a, p) + _segments(a, b, p) + _segments(b, b + down, p)


def _influence(a: np.ndarray, b: np.ndarray, p: np.ndarray, far: float, ground: bool) -> np.ndarray:
    v = _horseshoes(a, b, p, far)
    if ground:  # the image: mirrored under z = 0, opposite sign, so no flow through the ground
        m = np.array([1.0, 1.0, -1.0])
        v = v - _horseshoes(a * m, b * m, p, far)
    return v


def _cosine(n: int) -> np.ndarray:
    return 0.5 * (1 - np.cos(np.linspace(0.0, math.pi, n + 1)))


def section_slope(chord: float, height: float | None, n: int = 12) -> float:
    """Lift slope per radian of a flat plate on an endless span, at height over a ground (None: free air):
    point vortices at each panel's quarter chord, no flow through at three quarters."""
    x = np.linspace(0.0, chord, n + 1)
    xv, xc = x[:-1] + 0.25 * np.diff(x), x[:-1] + 0.75 * np.diff(x)
    dx = xc[:, None] - xv[None, :]
    a = -1 / (2 * math.pi * dx)  # downwash of a unit vortex, positive circulation lifting
    if height is not None:
        dz = 2 * height
        a = a + dx / (2 * math.pi * (dx * dx + dz * dz))
    gam = np.linalg.solve(a, -np.ones(n))
    return 2 * float(gam.sum()) / chord


@dataclass
class Result:
    y: np.ndarray  # strip centres, m
    cl: np.ndarray  # local Cl per radian of alpha, on the chord
    induced: np.ndarray  # local induced angle per radian of alpha (radians)
    lift_slope: float  # the whole wing's CL per radian
    k_lift: float  # mean induced angle per unit CL (radians): the one strip's angle for the wing's lift
    k_drag: float  # induced drag per CL squared


@dataclass
class Lattice:
    """span, chord in m; height of the wing over the ground (None: free air); endplates of height
    endplate whose bottom edge is endplate_bottom over the ground (relative to the wing in free air)."""
    span: float
    chord: float
    height: float | None = None
    endplate: float = 0.0
    endplate_bottom: float | None = None
    nx: int = 8
    ny: int = 24
    nz: int = 8

    def _panels(self):
        b, c = self.span, self.chord
        z0 = self.height or 0.0
        xs = np.linspace(0.0, c, self.nx + 1)
        # Free tips: the lattice ends a quarter strip inside them (Hough), which settles the lift by 24
        # strips; plain spacing creeps down 1% each time the strips double. Endplates keep the full span.
        inset = 0.0 if self.endplate > 0 else 0.25 * b / (self.ny + 0.5)
        ys = (b - 2 * inset) * (np.linspace(0.0, 1.0, self.ny + 1) - 0.5)
        a_pts, b_pts, cols, normals, wing = [], [], [], [], []
        for j in range(self.ny):
            for i in range(self.nx):
                x0, dx = xs[i], xs[i + 1] - xs[i]
                xq, x3 = x0 + 0.25 * dx, x0 + 0.75 * dx
                a_pts.append((xq, ys[j], z0))
                b_pts.append((xq, ys[j + 1], z0))
                cols.append((x3, 0.5 * (ys[j] + ys[j + 1]), z0))
                normals.append((0.0, 0.0, 1.0))
                wing.append(True)
        if self.endplate > 0:
            bottom = z0 + (self.endplate_bottom if self.height is None else self.endplate_bottom - z0) \
                if self.endplate_bottom is not None else z0
            top = bottom + self.endplate
            parts = [(lo, hi) for lo, hi in ((bottom, min(z0, top)), (max(z0, bottom), top)) if hi - lo > 1e-9]
            for lo, hi in parts:  # split at the wing so the lattices meet at the tip
                n = max(2, round(self.nz * (hi - lo) / max(top - bottom, 1e-9)))
                zs = lo + (hi - lo) * _cosine(n)
                for side in (-0.5, 0.5):
                    for k in range(n):
                        for i in range(self.nx):
                            x0, dx = xs[i], xs[i + 1] - xs[i]
                            xq, x3 = x0 + 0.25 * dx, x0 + 0.75 * dx
                            # bound vortex up the plate; the sign follows the side so the normals match
                            za, zb = (zs[k], zs[k + 1]) if side > 0 else (zs[k + 1], zs[k])
                            a_pts.append((xq, side * b, za))
                            b_pts.append((xq, side * b, zb))
                            cols.append((x3, side * b, 0.5 * (zs[k] + zs[k + 1])))
                            normals.append((0.0, 1.0 if side > 0 else -1.0, 0.0))
                            wing.append(False)
        return (np.array(a_pts), np.array(b_pts), np.array(cols), np.array(normals), np.array(wing), xs, ys)

    def solve(self) -> Result:
        a, b, p, n, wing, xs, ys = self._panels()
        ground = self.height is not None
        v = _influence(a, b, p, FAR * max(self.span, self.chord), ground)
        mat = np.einsum("nmk,nk->nm", v, n)
        rhs = -np.where(wing, 1.0, 0.0)  # alpha = 1 rad, small-angle: the freestream's normal part on the wing
        gam = np.linalg.solve(mat, rhs)
        g = gam[wing].reshape(self.ny, self.nx).sum(axis=1)
        cl = 2 * g / self.chord
        cl_wing = float(np.sum(g * np.diff(ys))) * 2 / (self.span * self.chord)
        a2d = section_slope(self.chord, self.height, self.nx)
        cdi = _trefftz_drag(a, b, gam, ground) / (self.span * self.chord)
        return Result(y=0.5 * (ys[:-1] + ys[1:]), cl=cl, induced=1.0 - cl / a2d, lift_slope=cl_wing,
                      k_lift=1 / cl_wing - 1 / a2d, k_drag=cdi / cl_wing ** 2)


def _trefftz_drag(a: np.ndarray, b: np.ndarray, gam: np.ndarray, ground: bool) -> float:
    """Induced drag over q (m^2) from the wake far downstream: every trailing leg a 2D vortex in the
    (y, z) plane (with its image), Di = -(rho/2) sum gamma (x cross t) . u ds over every strip."""
    pts = np.concatenate([a[:, 1:], b[:, 1:]])  # the leg at a runs upstream (-gamma along x), at b downstream
    strength = np.concatenate([-gam, gam])
    if ground:
        pts = np.concatenate([pts, pts * [1.0, -1.0]])
        strength = np.concatenate([strength, -strength])
    mid = 0.5 * (a[:, 1:] + b[:, 1:])
    r = mid[:, None, :] - pts[None, :, :]
    r2 = np.einsum("nmk,nmk->nm", r, r)
    w = np.where(r2 > CORE, strength / (2 * math.pi * np.maximum(r2, 1e-300)), 0.0)
    u = np.stack([-(w * r[..., 1]).sum(1), (w * r[..., 0]).sum(1)], axis=1)  # x cross r, in (y, z)
    t = b[:, 1:] - a[:, 1:]  # the bound vortex, its length the strip's width
    normal = np.stack([-t[:, 1], t[:, 0]], axis=1)  # x cross t, in (y, z)
    return float(-np.sum(gam * np.einsum("nk,nk->n", normal, u)))  # (rho/2) / q = 1
