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
class Strips:
    y: np.ndarray  # strip centres, m
    height: np.ndarray | None  # the wing over the ground at each centre, m (None: free air)
    width: np.ndarray  # m
    k: np.ndarray  # k[i, j]: induced angle (rad) at strip i per unit section Cl on strip j


@dataclass
class Lattice:
    """span, chord in m; height of the wing over the ground at mid-span (None: free air); drop, how much
    higher the wing sits at y = -span/2 than at +span/2 (a straight change, m); endplates of height
    endplate whose bottom edge is endplate_bottom over the ground (relative to the wing in free air)."""
    span: float
    chord: float
    height: float | None = None
    endplate: float = 0.0
    endplate_bottom: float | None = None
    nx: int = 8
    ny: int = 24
    nz: int = 8
    drop: float = 0.0
    # The section as it is: chordwise panels ((x0, z0), (x1, z1)) in m, x from the leading edge, z over
    # z(y) (the base height). The panels carry the section's angles, the flow runs along x; nx is then the
    # endplates' columns. None: a flat plate at a uniform angle of 1 rad.
    profile: tuple | list | None = None

    def z(self, y):
        """The wing's height (over the ground, or over mid-span's in free air) at spanwise station y."""
        return (self.height or 0.0) - self.drop * np.asarray(y) / self.span

    def _panels(self):
        if self.profile is not None:
            return self._profile_panels()
        b, c = self.span, self.chord
        xs = np.linspace(0.0, c, self.nx + 1)
        # Free tips: the lattice ends a quarter strip inside them (Hough), which settles the lift by 24
        # strips; plain spacing creeps down 1% each time the strips double. Endplates keep the full span.
        inset = 0.0 if self.endplate > 0 else 0.25 * b / (self.ny + 0.5)
        ys = (b - 2 * inset) * (np.linspace(0.0, 1.0, self.ny + 1) - 0.5)
        a_pts, b_pts, cols, normals, wing = [], [], [], [], []
        zy = self.z(ys)
        slope = -self.drop / b  # dz/dy: the strip is tilted about x, its normal with it
        normal = np.array([0.0, -slope, 1.0]) / math.hypot(1.0, slope)
        for j in range(self.ny):
            for i in range(self.nx):
                x0, dx = xs[i], xs[i + 1] - xs[i]
                xq, x3 = x0 + 0.25 * dx, x0 + 0.75 * dx
                a_pts.append((xq, ys[j], zy[j]))
                b_pts.append((xq, ys[j + 1], zy[j + 1]))
                cols.append((x3, 0.5 * (ys[j] + ys[j + 1]), 0.5 * (zy[j] + zy[j + 1])))
                normals.append(tuple(normal))
                wing.append(True)
        if self.endplate > 0:
            for side in (-0.5, 0.5):
                z0 = float(self.z(side * b))
                bottom = z0 + (self.endplate_bottom if self.height is None else self.endplate_bottom - z0) \
                    if self.endplate_bottom is not None else z0
                top = bottom + self.endplate
                parts = [(lo, hi) for lo, hi in ((bottom, min(z0, top)), (max(z0, bottom), top)) if hi - lo > 1e-9]
                for lo, hi in parts:  # split at the wing so the lattices meet at the tip
                    n = max(2, round(self.nz * (hi - lo) / max(top - bottom, 1e-9)))
                    zs = lo + (hi - lo) * _cosine(n)
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

    def _profile_panels(self):
        """_panels for a profile: each chordwise panel at its own height and slope, the endplates in
        columns from the section's nose to its tail, their vortices joined at every height the wing's
        trailing legs leave the tip, so no leg passes next to an endplate control point."""
        b = self.span
        prof = np.asarray(self.profile, float)  # (n, 2 ends, (x, z))
        p0, p1 = prof[:, 0], prof[:, 1]
        q, c3, t = p0 + 0.25 * (p1 - p0), p0 + 0.75 * (p1 - p0), p1 - p0
        inset = 0.0 if self.endplate > 0 else 0.25 * b / (self.ny + 0.5)  # as _panels
        ys = (b - 2 * inset) * (np.linspace(0.0, 1.0, self.ny + 1) - 0.5)
        zy = self.z(ys)
        slope = -self.drop / b
        normal = np.stack([-t[:, 1], -t[:, 0] * slope, t[:, 0]], axis=1)  # (t_x, 0, t_z) x (0, 1, dz/dy)
        normal /= np.linalg.norm(normal, axis=1, keepdims=True)
        a_pts, b_pts, cols, normals, wing = [], [], [], [], []
        for j in range(self.ny):
            for i in range(len(prof)):
                a_pts.append((q[i, 0], ys[j], zy[j] + q[i, 1]))
                b_pts.append((q[i, 0], ys[j + 1], zy[j + 1] + q[i, 1]))
                cols.append((c3[i, 0], 0.5 * (ys[j] + ys[j + 1]), 0.5 * (zy[j] + zy[j + 1]) + c3[i, 1]))
                normals.append(tuple(normal[i]))
                wing.append(True)
        xs = np.linspace(float(prof[..., 0].min()), float(prof[..., 0].max()), self.nx + 1)
        if self.endplate > 0:
            for side in (-0.5, 0.5):
                z0 = float(self.z(side * b))
                bottom = (self.endplate_bottom if self.height is not None else z0 + self.endplate_bottom) \
                    if self.endplate_bottom is not None else z0 + float(min(p0[:, 1].min(), p1[:, 1].min()))
                top = bottom + self.endplate
                legs = np.unique(np.round(z0 + q[:, 1], 9))
                legs = legs[(legs > bottom) & (legs < top)]
                gap = 0.3 * (top - bottom) / self.nz
                grid = bottom + (top - bottom) * _cosine(self.nz)
                keep = [z for z in grid if z in (bottom, top) or np.abs(legs - z).min(initial=np.inf) > gap]
                zs = np.unique(np.concatenate([keep, legs]))
                for k in range(len(zs) - 1):
                    for i in range(self.nx):
                        x0, dx = xs[i], xs[i + 1] - xs[i]
                        xq, x3 = x0 + 0.25 * dx, x0 + 0.75 * dx
                        za, zb = (zs[k], zs[k + 1]) if side > 0 else (zs[k + 1], zs[k])
                        a_pts.append((xq, side * b, za))
                        b_pts.append((xq, side * b, zb))
                        cols.append((x3, side * b, 0.5 * (zs[k] + zs[k + 1])))
                        normals.append((0.0, 1.0 if side > 0 else -1.0, 0.0))
                        wing.append(False)
        return (np.array(a_pts), np.array(b_pts), np.array(cols), np.array(normals), np.array(wing), xs, ys)

    @property
    def _chordwise_panels(self) -> int:
        return self.nx if self.profile is None else len(self.profile)

    def _system(self):
        a, b, p, n, wing, xs, ys = self._panels()
        ground = self.height is not None
        v = _influence(a, b, p, FAR * max(self.span, self.chord), ground)
        mat = np.einsum("nmk,nk->nm", v, n)
        # alpha = 1 rad, small-angle, on a flat plate; a profile carries its own angles, the flow along x
        rhs = -np.where(wing, n[:, 0] if self.profile is not None else n[:, 2], 0.0)
        return a, b, n, wing, ys, ground, mat, np.linalg.solve(mat, rhs)

    def solve(self) -> Result:
        a, b, n, wing, ys, ground, mat, gam = self._system()
        g = gam[wing].reshape(self.ny, self._chordwise_panels).sum(axis=1)
        cl = 2 * g / self.chord
        cl_wing = float(np.sum(g * np.diff(ys))) * 2 / (self.span * self.chord)
        a2d = section_slope(self.chord, self.height, self.nx)
        cdi = _trefftz_drag(a, b, gam, ground) / (self.span * self.chord)
        return Result(y=0.5 * (ys[:-1] + ys[1:]), cl=cl, induced=1.0 - cl / a2d, lift_slope=cl_wing,
                      k_lift=1 / cl_wing - 1 / a2d, k_drag=cdi / cl_wing ** 2)

    def chordwise(self, stations: list[float], loading=None) -> np.ndarray:
        """The induced angle (rad) along the chord at mid-span per unit section Cl on the chord, at
        stations (fractions of the chord from the leading edge; straight between the control points,
        held at the ends). The lattice's downwash beyond what the same chordwise loading would make
        on an endless span at the same height: on a slender wing nearly level along the chord, on one
        shorter than its chord growing aft, so the elements behind meet a steeper flow.
        loading: each chordwise panel's share of every strip's circulation (the strips keep the
        lattice's own totals, the endplates are solved with the wing held); default the flat plate's
        own, heaviest at the front, where a multi-element wing spreads its load along the chord."""
        xc, angles = self._panel_angles(loading)
        order = np.argsort(xc)
        return np.interp(np.asarray(stations, float) * self.chord, xc[order], angles[order])

    def panel_angles(self, loading=None) -> np.ndarray:
        """chordwise's induced angle at each chordwise panel's control point (rad per unit section Cl)."""
        return self._panel_angles(loading)[1]

    def panel_loads(self) -> np.ndarray:
        """Each chordwise panel's circulation at mid-span (the mean of the middle strips), m^2/s per m/s of
        flow: 1 rad on a flat plate, the profile's own angles on a profile. Cl on the chord is 2 sum / chord."""
        _, _, _, wing, _, _, _, gam = self._system()
        return gam[wing].reshape(self.ny, self._chordwise_panels)[self._middle()].mean(axis=0)

    def _middle(self) -> list[int]:
        return [self.ny // 2 - 1, self.ny // 2] if self.ny % 2 == 0 else [self.ny // 2]

    def _panel_angles(self, loading=None) -> tuple[np.ndarray, np.ndarray]:
        a, b, p, n, wing, _, _ = self._panels()
        _, _, _, _, ys, ground, mat, gam = self._system()
        nc = self._chordwise_panels
        g = gam.copy()
        if loading is not None:
            shape = np.asarray(loading, float)
            total = gam[wing].reshape(self.ny, nc).sum(axis=1)
            g[wing] = (total[:, None] * (shape / shape.sum())[None, :]).ravel()
            plate = ~wing
            if plate.any():
                g[plate] = np.linalg.solve(mat[np.ix_(plate, plate)], -mat[np.ix_(plate, wing)] @ g[wing])
        w3 = (mat @ g)[wing].reshape(self.ny, nc)  # every vortex's normal velocity at the control points
        gw = g[wing].reshape(self.ny, nc)
        wa, wb = a[wing].reshape(self.ny, nc, 3), b[wing].reshape(self.ny, nc, 3)
        wp, wn = p[wing].reshape(self.ny, nc, 3), n[wing].reshape(self.ny, nc, 3)
        far = 1e4 * max(self.span, self.chord)
        angles = []
        for j in self._middle():
            # the same loading on an endless span: each bound vortex run out to both sides (and its image)
            ends = 0.5 * (wa[j] + wb[j])
            lo, hi = ends.copy(), ends.copy()
            lo[:, 1], hi[:, 1] = -far, far
            v = _segments(lo, hi, wp[j])
            if ground:
                m = np.array([1.0, 1.0, -1.0])
                v = v - _segments(lo * m, hi * m, wp[j])
            two_d = np.einsum("nmk,nk->nm", v, wn[j])
            # the 3D flow less what the same loading makes in 2D, over n_z: a flow turned by d changes a panel's
            # normal speed by n_z d. shortcut: n_z held to 0.2 (78 deg), where no turn of the flow emulates it
            induced = -(w3[j] - two_d @ gw[j]) / np.maximum(wn[j][:, 2], 0.2)
            angles.append(induced / (2 * gw[j].sum() / self.chord))
        return wp[self._middle()[0], :, 0], np.mean(angles, axis=0)

    def strips(self, count: int) -> Strips:
        """The induced angle on count equal spanwise strips per unit section Cl on each, for a strip
        model (finite.couple_strips): each strip's circulation held in its chordwise shape (the
        lattice's own at a uniform angle), the endplates solved to let no flow through, then the
        trailing vortices' downwash far behind (Trefftz plane) over 2, the mean over the strip, as
        lifting line. Loaded as the lattice loads itself, sum Cl_i (k Cl)_i width_i / span is its Cdi."""
        if self.ny % count:
            raise ValueError(f"{self.ny} lattice strips do not split into {count}")
        a, b, n, wing, ys, ground, mat, gam = self._system()
        shape = gam[wing].reshape(self.ny, self.nx)
        shape = shape / shape.sum(axis=1, keepdims=True)
        plate = ~wing
        wa, wb = a[wing].reshape(self.ny, self.nx, 3)[:, 0, 1:], b[wing].reshape(self.ny, self.nx, 3)[:, 0, 1:]
        mid, up = 0.5 * (wa + wb), n[wing].reshape(self.ny, self.nx, 3)[:, 0, 1:]  # column centres, normals (y, z)
        per = self.ny // count
        k = np.zeros((count, count))
        for j in range(count):
            g = np.zeros_like(gam)
            col = np.zeros((self.ny, self.nx))
            col[j * per:(j + 1) * per] = 0.5 * self.chord * shape[j * per:(j + 1) * per]  # Cl 1 = circulation c / 2
            g[wing] = col.ravel()
            if plate.any():
                g[plate] = np.linalg.solve(mat[np.ix_(plate, plate)], -mat[np.ix_(plate, wing)] @ g[wing])
            angle = -0.5 * np.einsum("nk,nk->n", _wake_velocity(a, b, g, ground, mid), up)
            k[:, j] = angle.reshape(count, per).mean(axis=1)
        y = 0.5 * (ys[:-1] + ys[1:]).reshape(count, per).mean(axis=1)
        return Strips(y=y, height=self.z(y) if self.height is not None else None,
                      width=np.diff(ys).reshape(count, per).sum(axis=1), k=k)


def _wake_velocity(a: np.ndarray, b: np.ndarray, gam: np.ndarray, ground: bool, at: np.ndarray) -> np.ndarray:
    """Velocity (y, z) far downstream at points at (n, 2), every trailing leg a 2D vortex with its image."""
    pts = np.concatenate([a[:, 1:], b[:, 1:]])  # the leg at a runs upstream (-gamma along x), at b downstream
    strength = np.concatenate([-gam, gam])
    if ground:
        pts = np.concatenate([pts, pts * [1.0, -1.0]])
        strength = np.concatenate([strength, -strength])
    r = at[:, None, :] - pts[None, :, :]
    r2 = np.einsum("nmk,nmk->nm", r, r)
    w = np.where(r2 > CORE, strength / (2 * math.pi * np.maximum(r2, 1e-300)), 0.0)
    return np.stack([-(w * r[..., 1]).sum(1), (w * r[..., 0]).sum(1)], axis=1)  # x cross r, in (y, z)


def _trefftz_drag(a: np.ndarray, b: np.ndarray, gam: np.ndarray, ground: bool) -> float:
    """Induced drag over q (m^2) from the wake far downstream: every trailing leg a 2D vortex in the
    (y, z) plane (with its image), Di = -(rho/2) sum gamma (x cross t) . u ds over every strip."""
    u = _wake_velocity(a, b, gam, ground, 0.5 * (a[:, 1:] + b[:, 1:]))
    t = b[:, 1:] - a[:, 1:]  # the bound vortex, its length the strip's width
    normal = np.stack([-t[:, 1], t[:, 0]], axis=1)  # x cross t, in (y, z)
    return float(-np.sum(gam * np.einsum("nk,nk->n", normal, u)))  # (rho/2) / q = 1
