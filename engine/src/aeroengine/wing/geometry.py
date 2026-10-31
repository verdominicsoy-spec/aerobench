"""A multi-element wing in the wing's frame: placing elements, gap, overlap
and the validity checks. The same rules as the app's WingGeometry.swift, so
a wing the optimiser builds is the wing the canvas would show."""

from __future__ import annotations

from dataclasses import dataclass, field, replace

import numpy as np


@dataclass
class Element:
    unit: np.ndarray  # the normalised section: Selig order, unit chord, leading edge at the origin
    chord: float  # m
    angle: float  # degrees: more lift upright, more downforce inverted
    leading_edge: np.ndarray  # m, wing frame
    inverted: bool = True

    @classmethod
    def from_dict(cls, d: dict) -> "Element":
        return cls(np.asarray(d["unit"], float), float(d["chord"]), float(d.get("angle", 0.0)),
                   np.asarray(d.get("leading_edge", (0.0, 0.0)), float), bool(d.get("inverted", True)))

    @property
    def rotation(self) -> float:
        return (1 if self.inverted else -1) * np.radians(self.angle)

    def _rotate(self, p: np.ndarray) -> np.ndarray:
        c, s = np.cos(self.rotation), np.sin(self.rotation)
        return self.leading_edge + self.chord * (p @ np.array([[c, s], [-s, c]]))

    def placed(self) -> np.ndarray:
        """Points in the wing frame, Selig order (counter-clockwise) either way up."""
        unit = self.unit[::-1] * (1, -1) if self.inverted else self.unit
        return self._rotate(unit)

    @property
    def trailing_edge(self) -> np.ndarray:
        mid = 0.5 * (self.unit[0] + self.unit[-1])
        return self._rotate(mid * (1, -1) if self.inverted else mid)

    @property
    def chord_direction(self) -> np.ndarray:
        d = self.trailing_edge - self.leading_edge
        return d / np.linalg.norm(d)


@dataclass
class Wing:
    elements: list[Element]
    min_gap: float = 0.005  # m
    rules_box: tuple[float, float, float, float] | None = None  # min x, min y, max x, max y (entered by the user)
    alpha: float = 0.0
    ride_height: float | None = None  # m, lowest point to a ground along the flow; None is free air

    def copy(self) -> "Wing":
        return replace(self, elements=[replace(e, leading_edge=e.leading_edge.copy()) for e in self.elements])

    def gap(self, i: int) -> float:
        """Minimum distance from the previous element's trailing edge to this element's surface."""
        return closest(self.elements[i - 1].trailing_edge, self.elements[i].placed())[1]

    def overlap(self, i: int) -> float:
        """How far this leading edge sits ahead of the previous trailing edge, along the main chord."""
        u = self.elements[0].chord_direction
        return float(np.dot(self.elements[i - 1].trailing_edge - self.elements[i].leading_edge, u))

    def move(self, i: int, shift: np.ndarray) -> None:
        """Shifts element i and every one behind it."""
        for e in self.elements[i:]:
            e.leading_edge = e.leading_edge + shift

    def set_gap(self, target: float, i: int) -> None:
        for _ in range(6):
            te = self.elements[i - 1].trailing_edge
            point, d = closest(te, self.elements[i].placed())
            if d <= 1e-12:
                break
            shift = (target - d) * (point - te) / d
            if np.linalg.norm(shift) <= 1e-10:
                break
            self.move(i, shift)

    def set_overlap(self, target: float, i: int) -> None:
        self.move(i, (self.overlap(i) - target) * self.elements[0].chord_direction)

    def issues(self) -> list[str]:
        """Why this wing cannot be built or run: intersections, gaps under the minimum, outside the rules box."""
        shapes = [e.placed() for e in self.elements]
        out = []
        for i in range(len(shapes)):
            for j in range(i + 1, len(shapes)):
                if intersect(shapes[i], shapes[j]):
                    out.append(f"{label(i)} and {label(j)} intersect")
                else:
                    d = distance(shapes[i], shapes[j])
                    if d < self.min_gap:
                        out.append(f"{label(i)} and {label(j)} are {d * 1000:.1f} mm apart, under the minimum gap")
            if self.rules_box is not None:
                x0, y0, x1, y1 = self.rules_box
                p = shapes[i]
                if np.any((p[:, 0] < x0) | (p[:, 0] > x1) | (p[:, 1] < y0) | (p[:, 1] > y1)):
                    out.append(f"{label(i)} reaches outside the rules box")
        return out


def label(i: int) -> str:
    return "Main" if i == 0 else f"Flap {i}"


def closest(p: np.ndarray, poly: np.ndarray) -> tuple[np.ndarray, float]:
    a, b = poly[:-1], poly[1:]
    ab = b - a
    t = np.clip(np.einsum("ij,ij->i", p - a, ab) / np.maximum(np.einsum("ij,ij->i", ab, ab), 1e-300), 0, 1)
    q = a + t[:, None] * ab
    d = np.linalg.norm(p - q, axis=1)
    k = int(np.argmin(d))
    return q[k], float(d[k])


def distance(a: np.ndarray, b: np.ndarray) -> float:
    return min(min(closest(p, b)[1] for p in a), min(closest(p, a)[1] for p in b))


def intersect(a: np.ndarray, b: np.ndarray) -> bool:
    p, r = a[:-1, None, :], (a[1:] - a[:-1])[:, None, :]
    q, s = b[None, :-1, :], (b[1:] - b[:-1])[None, :, :]

    def cross(u, v):
        return u[..., 0] * v[..., 1] - u[..., 1] * v[..., 0]

    den = cross(r, s)
    ok = np.abs(den) > 1e-300
    with np.errstate(divide="ignore", invalid="ignore"):
        t = cross(q - p, s) / den
        u = cross(q - p, r) / den
    if np.any(ok & (t >= 0) & (t <= 1) & (u >= 0) & (u <= 1)):
        return True
    return inside(a[0], b) or inside(b[0], a)  # one inside the other


def inside(p: np.ndarray, poly: np.ndarray) -> bool:
    a, b = poly, np.roll(poly, 1, axis=0)
    crosses = (a[:, 1] > p[1]) != (b[:, 1] > p[1])
    with np.errstate(divide="ignore", invalid="ignore"):
        x = (b[:, 0] - a[:, 0]) * (p[1] - a[:, 1]) / (b[:, 1] - a[:, 1]) + a[:, 0]
    return bool(np.count_nonzero(crosses & (p[0] < x)) % 2)


@dataclass
class Variable:
    """One design variable: an element's angle (degrees), gap or overlap (m),
    or its shape: camber added (fraction of chord) and thickness (scale);
    or the whole wing's ride height over a ground (m, element 0)."""
    element: int
    kind: str  # "angle", "gap", "overlap", "camber", "thickness" or "height"
    low: float
    high: float
    name: str = field(init=False)

    def __post_init__(self) -> None:
        self.name = f"{self.kind}_{self.element}"


def reshape(unit: np.ndarray, camber: float = 0.0, thickness: float = 1.0) -> np.ndarray:
    """A section (Selig order, unit chord) with camber added and its
    thickness scaled. The camber goes on as a parabola, `camber` of the
    chord at mid-chord and nothing at either end, so the chord line stays
    put; the thickness about the camber line is multiplied by `thickness`.
    Two numbers per element: enough to let the optimiser reshape a section
    without a full shape parameterisation."""
    if camber == 0.0 and thickness == 1.0:
        return unit
    i = int(np.argmin(unit[:, 0]))
    upper, lower = unit[: i + 1][::-1], unit[i:]  # both leading edge to trailing edge

    def at(surface: np.ndarray, x: np.ndarray) -> np.ndarray:
        order = np.argsort(surface[:, 0], kind="stable")
        return np.interp(x, surface[order, 0], surface[order, 1])

    def moved(points: np.ndarray, other: np.ndarray) -> np.ndarray:
        x, y = points[:, 0], points[:, 1]
        mean = 0.5 * (y + at(other, x))
        return np.column_stack([x, mean + camber * 4 * x * (1 - x) + thickness * (y - mean)])

    new_upper, new_lower = moved(upper, lower), moved(lower, upper)
    return np.vstack([new_upper[::-1], new_lower[1:]])


SHAPE_KINDS = ("camber", "thickness")


def apply(base: Wing, values: dict[str, float]) -> Wing:
    """The base wing with design values applied. Shapes change first; angles
    turn each element about its leading edge; then, element by element from
    the front, each flap's gap and overlap go to the design value, or back
    to what the base wing had, so turning an element does not drag the slot
    with it."""
    w = base.copy()
    if "height_0" in values:
        w.ride_height = values["height_0"]
    targets = [(base.gap(i), base.overlap(i)) if i else (0.0, 0.0) for i in range(len(base.elements))]
    for i, e in enumerate(w.elements):
        if f"camber_{i}" in values or f"thickness_{i}" in values:
            e.unit = reshape(e.unit, values.get(f"camber_{i}", 0.0), values.get(f"thickness_{i}", 1.0))
        e.angle = values.get(f"angle_{i}", e.angle)
    # Start each flap where it sat relative to the trailing edge in front,
    # turned with the main element, so the slot solve begins close.
    u0, u1 = base.elements[0].chord_direction, w.elements[0].chord_direction
    c, s = float(np.dot(u0, u1)), float(u0[0] * u1[1] - u0[1] * u1[0])
    turn = np.array([[c, -s], [s, c]])
    for i in range(1, len(w.elements)):
        offset = base.elements[i].leading_edge - base.elements[i - 1].trailing_edge
        w.move(i, w.elements[i - 1].trailing_edge + turn @ offset - w.elements[i].leading_edge)
        target = np.array([values.get(f"gap_{i}", targets[i][0]), values.get(f"overlap_{i}", targets[i][1])])
        _place_slot(w, i, target)
    return w


def _place_slot(w: Wing, i: int, target: np.ndarray) -> None:
    """Moves flap i (and those behind it) so its gap and overlap are both on
    target: Newton on the leading edge shift, with a numerical Jacobian. The
    gap's direction depends on where the nearest point is, so the two moves
    are not independent and setting them in turn does not settle."""
    def residual() -> np.ndarray:
        return np.array([w.gap(i), w.overlap(i)]) - target

    h = 1e-7 * max(w.elements[i].chord, 1e-3)
    for _ in range(30):
        r = residual()
        if np.max(np.abs(r)) < 1e-9:
            return
        jac = np.empty((2, 2))
        for k in range(2):
            d = np.zeros(2)
            d[k] = h
            w.move(i, d)
            jac[:, k] = (residual() - r) / h
            w.move(i, -d)
        try:
            step = -np.linalg.solve(jac, r)
        except np.linalg.LinAlgError:
            step = -r[0] * np.array([0.0, 1.0])
        # Never jump more than a fifth of the flap chord in one go.
        n = np.linalg.norm(step)
        cap = 0.2 * w.elements[i].chord
        w.move(i, step * min(1.0, cap / n) if n > 0 else step)
