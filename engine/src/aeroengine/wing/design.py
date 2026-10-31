"""A starting wing in seconds, for designing one from an empty project.

The library's sections are ranked by NeuralFoil's maximum lift at the main
element's Reynolds number (about 2 ms a section), the few best are laid out
as a two- or three-element wing in a standard arrangement (inside the rules
box when there is one), and the quick estimate picks the one that carries
the most load there. The optimiser then takes it from that start; this only
has to be a good place to begin, not the answer."""

from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path

import numpy as np

from ..job import EngineError
from . import library_polars
from .airfoils import NACA_SET, naca
from .estimate import estimate
from .geometry import Element, Variable, Wing, label
from .viscous import reynolds

# Chord shares and in-place angles of the standard arrangement: a common
# starting point for FS rear wings (main nearly flat, each flap steeper).
SHARES = {2: (0.68, 0.32), 3: (0.55, 0.27, 0.18)}
ANGLES = {2: (3.0, 25.0), 3: (2.0, 20.0, 40.0)}
GAP = 0.012  # m, each flap's slot to start with
OVERLAP = 0.005  # m


def _sections(root: Path | None, min_thickness: float) -> list[tuple[str, str, np.ndarray]]:
    """(key, name, unit coords) of every section at least min_thickness
    thick: the library index if there is one, else the NACA set."""
    index = root / "index.sqlite" if root else None
    if index and index.exists():
        db = sqlite3.connect(index)
        try:
            rows = db.execute("SELECT key, name, coords FROM airfoils WHERE thickness >= ? AND te_thickness < 0.02",
                              (min_thickness,)).fetchall()
        finally:
            db.close()
        return [(k, n, np.asarray(json.loads(c), float)) for k, n, c in rows]
    # The last two digits of a NACA code are its thickness in % of chord.
    return [(f"naca/{code}", f"NACA {code}", naca(code)) for code in NACA_SET if int(code[-2:]) / 100 >= min_thickness]


def layout(units: list[np.ndarray], chord_total: float, inverted: bool, rules_box=None, min_gap: float = 0.005) -> Wing:
    """The standard arrangement, scaled down until it fits the rules box."""
    n = len(units)
    if n not in SHARES:
        raise EngineError("a starting wing has 2 or 3 elements")
    scale = 1.0
    for _ in range(12):
        chords = [chord_total * scale * s for s in SHARES[n]]
        origin = np.zeros(2)
        if rules_box is not None:
            x0, y0, x1, y1 = rules_box
            origin = np.array([x0 + 0.03 * (x1 - x0), y0 + (0.75 if inverted else 0.25) * (y1 - y0)])
        els = [Element(units[0], chords[0], ANGLES[n][0], origin.copy(), inverted)]
        for i in range(1, n):
            prev = els[-1]
            els.append(Element(units[i], chords[i], ANGLES[n][i], prev.trailing_edge.copy(), inverted))
        w = Wing(els, min_gap=min_gap, rules_box=rules_box)
        for i in range(1, n):
            w.set_overlap(OVERLAP, i)
            w.set_gap(GAP, i)
        if not w.issues():
            return w
        scale *= 0.9
    return w  # the best it could do; the optimiser treats what breaks the box as invalid


def variables(wing: Wing) -> list[Variable]:
    """What the optimiser searches from the start: every angle, every slot's
    gap and overlap. Ranges are wide enough to hold the usual FS wings."""
    n = len(wing.elements)
    out = [Variable(0, "angle", -4.0, 12.0)]
    flap_ranges = {2: [(12.0, 45.0)], 3: [(10.0, 35.0), (25.0, 60.0)]}[n]
    for i, (lo, hi) in enumerate(flap_ranges, start=1):
        out.append(Variable(i, "angle", lo, hi))
        out.append(Variable(i, "gap", max(wing.min_gap + 0.001, 0.006), 0.022))
        out.append(Variable(i, "overlap", -0.005, 0.020))
    return out


def starter(root: Path | None, elements: int = 2, chord_total: float = 0.44, inverted: bool = True,
            rules_box=None, speed: float = 15.0, rho: float = 1.225, mu: float = 1.81e-5, n_crit: float = 9.0,
            min_thickness: float = 0.08, candidates: int = 6, min_gap: float = 0.005,
            progress=lambda pct, msg: None) -> dict:
    t0 = time.time()
    secs = _sections(root, min_thickness)
    if not secs:
        raise EngineError(f"no section in the library is at least {min_thickness * 100:.0f}% thick")
    main_chord = chord_total * SHARES[elements][0]
    re = reynolds(speed, main_chord, rho, mu)
    progress(5, f"ranking {len(secs)} sections at Re {re:.3g}")
    ranked = []
    for k, (key, name, unit) in enumerate(secs):
        try:
            s = library_polars.summary(unit, re, n_crit)
        except Exception:  # an odd section: skip it
            continue
        if s["trusted"]:
            ranked.append((s["cl_max"], key, name, unit))
        if k % 200 == 0:
            progress(5 + 60 * k / len(secs), f"{k} of {len(secs)} sections")
    ranked.sort(key=lambda r: -r[0])
    tried, best = [], None
    for j, (clmax, key, name, unit) in enumerate(ranked[:candidates]):
        progress(70 + 25 * j / candidates, f"trying {name}")
        w = layout([unit] * elements, chord_total, inverted, rules_box, min_gap)
        els = [{"coords": e.placed().tolist(), "unit": e.unit.tolist(), "chord": e.chord, "angle": e.angle,
                "inverted": e.inverted} for e in w.elements]
        row = estimate(els, [0.0], speed, rho, mu, n_crit)["rows"][0]
        load = -row["cl"] if inverted else row["cl"]
        ok = not w.issues() and not row["separating"]
        tried.append({"key": key, "name": name, "cl_max": clmax, "load": load, "cd": row["cd"], "valid": ok})
        if ok and (best is None or load > best[0]):
            best = (load, key, name, w)
    if best is None:
        raise EngineError("none of the best sections made a valid starting wing",
                          "widen the rules box, lower the minimum thickness or use fewer elements")
    _, key, name, w = best
    return {
        "section": {"key": key, "name": name},
        "elements": [{"key": key, "name": name, "unit": e.unit.tolist(), "chord": e.chord, "angle": e.angle,
                      "leading_edge": e.leading_edge.tolist(), "inverted": e.inverted} for e in w.elements],
        "variables": [{"element": v.element, "kind": v.kind, "low": v.low, "high": v.high} for v in variables(w)],
        "re": re, "ranked": len(ranked), "tried": tried, "seconds": time.time() - t0,
        "labels": [label(i) for i in range(len(w.elements))],
    }
