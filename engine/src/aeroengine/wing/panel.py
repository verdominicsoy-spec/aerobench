"""Multi-element linear-vorticity panel method (inviscid preview).

The stream-function formulation of XFOIL (Drela 1989): vorticity varies
linearly along each panel, with strengths gamma at the nodes. On every
element the stream function is a constant psi_k (unknown), and each element
has a Kutta condition gamma_first + gamma_last = 0. The surface speed is
gamma itself, so Cp = 1 - (gamma / V)^2.

Elements are point arrays in Selig order (trailing edge, upper surface,
leading edge, lower surface, trailing edge) in one shared frame, chord
lengths in metres or any unit. A trailing edge gap is left open (no TE
panel); a closed trailing edge, whose first and last nodes coincide, gets
XFOIL's extrapolation condition in place of the duplicate equation.

This ignores viscosity, so it has nothing to say about the slot effects
that set the best gap; it is for angle trends and sanity checks. The stream
function grows with distance, so elements more than a few hundred chords
apart lose precision; a wing's are within a couple.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

SHARP = 1e-4  # a trailing edge gap below this fraction of the element's chord counts as closed


@dataclass
class Result:
    alpha_deg: float
    gamma: list[np.ndarray]  # surface speed / V at each node, per element (positive along the Selig order)
    cp: list[np.ndarray]
    cl: list[float]  # per element, on the reference chord
    cd: list[float]  # pressure drag per element (zero in total for a closed body, up to discretisation)
    cm: list[float]  # about the reference point, nose up positive
    cl_total: float
    cm_total: float


def _psi_matrix(px: np.ndarray, py: np.ndarray, nodes: list[np.ndarray], self_terms: bool = True) -> np.ndarray:
    """d psi(p) / d gamma_j for every field point p and every node j (all
    elements' nodes concatenated), from the linear vortex panels of each
    element. Field points that are panel nodes take XFOIL's limits (unless
    self_terms is off: the panels are images, never at a field point)."""
    total = sum(len(n) for n in nodes)
    out = np.zeros((len(px), total))
    q = 1 / (4 * np.pi)
    offset = 0
    # Which global node each field point is, if any: same coordinates, same index order.
    field_node = np.arange(len(px)) if self_terms and len(px) == total else None
    for xy in nodes:
        n = len(xy)
        a, b = xy[:-1], xy[1:]
        d = b - a
        length = np.hypot(d[:, 0], d[:, 1])
        sx, sy = d[:, 0] / length, d[:, 1] / length
        rx1 = px[:, None] - a[None, :, 0]
        ry1 = py[:, None] - a[None, :, 1]
        rx2 = px[:, None] - b[None, :, 0]
        ry2 = py[:, None] - b[None, :, 1]
        x1 = sx * rx1 + sy * ry1
        x2 = sx * rx2 + sy * ry2
        yy = sx * ry1 - sy * rx1
        rs1, rs2 = x1 * x1 + yy * yy, x2 * x2 + yy * yy
        sgn = np.where(yy >= 0, 1.0, -1.0)
        self1 = np.zeros_like(rs1, bool)
        self2 = np.zeros_like(rs2, bool)
        if field_node is not None:
            j = np.arange(n - 1) + offset
            self1 = field_node[:, None] == j[None, :]
            self2 = field_node[:, None] == (j + 1)[None, :]
        ok1, ok2 = ~self1 & (rs1 > 0), ~self2 & (rs2 > 0)
        with np.errstate(divide="ignore", invalid="ignore"):
            g1 = np.where(ok1, np.log(np.where(ok1, rs1, 1)), 0)
            g2 = np.where(ok2, np.log(np.where(ok2, rs2, 1)), 0)
        t1 = np.where(ok1, np.arctan2(sgn * x1, sgn * yy) + (0.5 - 0.5 * sgn) * np.pi, 0)
        t2 = np.where(ok2, np.arctan2(sgn * x2, sgn * yy) + (0.5 - 0.5 * sgn) * np.pi, 0)
        dxinv = 1 / (x1 - x2)
        psis = 0.5 * x1 * g1 - 0.5 * x2 * g2 + x2 - x1 + yy * (t1 - t2)
        psid = ((x1 + x2) * psis + 0.5 * (rs2 * g2 - rs1 * g1 + x1 * x1 - x2 * x2)) * dxinv
        out[:, offset:offset + n - 1] += q * (psis - psid)
        out[:, offset + 1:offset + n] += q * (psis + psid)
        offset += n
    return out


class Solver:
    """Factorises the influence matrix once per geometry; any number of
    angles of attack then cost one back substitution each."""

    def __init__(self, elements: list[np.ndarray], ref_chord: float | None = None,
                 ref_point: tuple[float, float] | None = None, ground: float | None = None) -> None:
        """ground: the height (y) of a ground plane parallel to x, the flow's
        direction, so only alpha 0 makes sense with it (turn the wing instead).
        It is an image wing of opposite vorticity mirrored in that line,
        which makes the line a streamline: a ground moving with the flow, as
        a rolling road, without a boundary layer of its own."""
        self.elements = [np.asarray(e, float) for e in elements]
        self.ground = ground
        if not self.elements:
            raise ValueError("no elements")
        sizes = [len(e) for e in self.elements]
        # Solved about the centroid: the stream function grows with distance.
        self.origin = np.vstack(self.elements).mean(axis=0)
        self.local = [e - self.origin for e in self.elements]
        nodes = np.vstack(self.local)
        m, k = len(nodes), len(self.elements)
        a = np.zeros((m + k, m + k))
        a[:m, :m] = _psi_matrix(nodes[:, 0], nodes[:, 1], self.local)
        if ground is not None:
            g = ground - self.origin[1]
            images = [np.column_stack([e[:, 0], 2 * g - e[:, 1]]) for e in self.local]
            a[:m, :m] -= _psi_matrix(nodes[:, 0], nodes[:, 1], images, self_terms=False)  # image strengths are -gamma
        starts = np.cumsum([0] + sizes[:-1])
        self.sharp = []
        for e, (s, n) in enumerate(zip(starts, sizes)):
            a[s:s + n, m + e] = -1  # psi = psi_k on this element
            xy = self.elements[e]
            chord = np.max(np.linalg.norm(xy - 0.5 * (xy[0] + xy[-1]), axis=1))
            sharp = np.linalg.norm(xy[0] - xy[-1]) < SHARP * chord
            self.sharp.append(sharp)
            if sharp:  # the last node repeats the first: extrapolate gamma there instead
                row = s + n - 1
                a[row, :] = 0
                a[row, [s, s + 1, s + 2]] = [1, -2, 1]
                a[row, [s + n - 1, s + n - 2, s + n - 3]] += [-1, 2, -1]
            a[m + e, s] = 1  # Kutta: gamma_first + gamma_last = 0
            a[m + e, s + n - 1] = 1
        import scipy.linalg

        self.lu = scipy.linalg.lu_factor(a)
        self.nodes, self.starts, self.sizes, self.m = nodes, starts, sizes, m
        main = self.elements[0]
        self.ref_chord = ref_chord or float(np.max(np.linalg.norm(main - 0.5 * (main[0] + main[-1]), axis=1)))
        if ref_point is None:  # quarter chord of the first element
            te = 0.5 * (main[0] + main[-1])
            le = main[int(np.argmax(np.linalg.norm(main - te, axis=1)))]
            ref_point = tuple(le + 0.25 * (te - le))
        self.ref_point = np.asarray(ref_point, float)

    def solve(self, alpha_deg: float) -> Result:
        if self.ground is not None and abs(alpha_deg) > 1e-9:
            raise ValueError("with a ground plane the flow runs along x: turn the wing, not the flow")
        al = np.radians(alpha_deg)
        x, y = self.nodes[:, 0], self.nodes[:, 1]
        rhs = np.zeros(self.m + len(self.elements))
        rhs[:self.m] = -(np.cos(al) * y - np.sin(al) * x)  # freestream psi, V = 1
        for e, (s, n) in enumerate(zip(self.starts, self.sizes)):
            if self.sharp[e]:
                rhs[s + n - 1] = 0
        import scipy.linalg

        sol = scipy.linalg.lu_solve(self.lu, rhs)
        wind = np.array([np.cos(al), np.sin(al)])
        lift_dir = np.array([-np.sin(al), np.cos(al)])
        gam, cps, cls, cds, cms = [], [], [], [], []
        for e, (s, n) in enumerate(zip(self.starts, self.sizes)):
            g = sol[s:s + n]
            cp = 1 - g**2
            xy = self.elements[e]
            # Pressure force on each panel (mean Cp), normal pointing out of the body:
            # the surface runs clockwise (Selig order), so the outward normal is (-dy, dx)... checked by sign below.
            d = np.diff(xy, axis=0)
            cpm = 0.5 * (cp[:-1] + cp[1:])
            normal = np.column_stack([d[:, 1], -d[:, 0]])  # length = panel length, outward for clockwise order
            force = -(cpm[:, None] * normal).sum(axis=0) / self.ref_chord
            mid = 0.5 * (xy[:-1] + xy[1:]) - self.ref_point
            fpan = -(cpm[:, None] * normal)
            moment = (mid[:, 0] * fpan[:, 1] - mid[:, 1] * fpan[:, 0]).sum() / self.ref_chord**2
            gam.append(g)
            cps.append(cp)
            cls.append(float(force @ lift_dir))
            cds.append(float(force @ wind))
            cms.append(float(-moment))  # nose up positive: a counter-clockwise moment pitches the nose down
        return Result(alpha_deg, gam, cps, cls, cds, cms, float(sum(cls)), float(sum(cms)))


def solve(elements: list[np.ndarray], alpha_deg: float, ref_chord: float | None = None) -> Result:
    return Solver(elements, ref_chord).solve(alpha_deg)


# Exact reference: Karman-Trefftz airfoils -----------------------------------------------

def karman_trefftz(mu_x: float = -0.08, mu_y: float = 0.08, tau_deg: float = 10.0, n: int = 400,
                   alpha_deg: float = 4.0) -> dict:
    """A Karman-Trefftz airfoil (circle centre (mu_x, mu_y) through zeta = 1,
    trailing edge angle tau) in Selig order with its exact surface speed and
    lift coefficient at alpha, chord-normalised."""
    k = 2 - np.radians(tau_deg) / np.pi
    centre = complex(mu_x, mu_y)
    radius = abs(1 - centre)
    beta = np.angle(1 - centre)  # angle from the centre to the trailing edge point zeta = 1
    al = np.radians(alpha_deg)
    # Around the circle from the trailing edge, counter-clockwise: the upper
    # surface first, as in Selig order.
    theta = beta + np.linspace(0, 2 * np.pi, n + 1)
    zeta = centre + radius * np.exp(1j * theta)

    def mapping(z):
        return k * ((z + 1) ** k + (z - 1) ** k) / ((z + 1) ** k - (z - 1) ** k)

    w = mapping(zeta)
    # Circulation (clockwise positive, lift = rho V gamma) for the Kutta
    # condition at zeta = 1.
    gamma = 4 * np.pi * radius * np.sin(al - beta)
    # Complex velocity on the circle: dW/dzeta.
    dw = np.exp(-1j * al) - radius**2 * np.exp(1j * al) / (zeta - centre) ** 2 + 1j * gamma / (2 * np.pi * (zeta - centre))
    dz = k**2 * 4 * ((zeta - 1) ** (k - 1) * (zeta + 1) ** (k - 1)) / ((zeta + 1) ** k - (zeta - 1) ** k) ** 2 * 1
    with np.errstate(divide="ignore", invalid="ignore"):
        speed = np.abs(dw / dz)
    xy = np.column_stack([w.real, w.imag])
    te = xy[0]
    le = xy[int(np.argmax(np.linalg.norm(xy - te, axis=1)))]
    chord = float(np.linalg.norm(te - le))
    return {"xy": xy, "speed": speed, "cl": float(2 * gamma / chord), "chord": chord}
