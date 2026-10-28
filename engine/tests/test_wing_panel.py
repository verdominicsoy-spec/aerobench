"""Panel method: exact solutions, convergence, multi-element behaviour."""

from __future__ import annotations

import numpy as np
import pytest

from aeroengine.wing.airfoils import naca4, section
from aeroengine.wing.panel import Solver, karman_trefftz


def _place(coords: np.ndarray, chord: float, angle_deg: float, at: tuple[float, float], flip: bool = False) -> np.ndarray:
    """A unit-chord section scaled, rotated nose-down by angle (positive is
    trailing edge down, the usual flap sense) about its leading edge, and moved."""
    xy = coords * chord
    if flip:
        xy = xy * [1, -1]
        xy = xy[::-1]  # keep Selig order (counter-clockwise) after mirroring
    a = -np.radians(angle_deg)
    rot = np.array([[np.cos(a), -np.sin(a)], [np.sin(a), np.cos(a)]])
    return xy @ rot.T + at


def test_matches_the_exact_karman_trefftz_solution_with_second_order_convergence():
    errors = []
    for n in (40, 80, 160, 320):
        kt = karman_trefftz(alpha_deg=4.0, n=n)
        r = Solver([kt["xy"]]).solve(4.0)
        errors.append(abs(r.cl_total / kt["cl"] - 1))
        if n == 320:
            assert np.max(np.abs(np.abs(r.gamma[0][5:-5]) - kt["speed"][5:-5])) < 0.005
    assert errors[-1] < 1e-4
    assert all(a / b > 3 for a, b in zip(errors, errors[1:]))


def test_naca0012_lift_slope_and_symmetry():
    s = Solver([section("0012", naca4("0012")).coords])
    assert abs(s.solve(0).cl_total) < 1e-9
    slope = (s.solve(4).cl_total - s.solve(-4).cl_total) / np.radians(8)
    # Thin-airfoil 2 pi, raised by thickness (about 1 + 0.77 t/c).
    assert slope == pytest.approx(2 * np.pi * (1 + 0.77 * 0.12), rel=0.02)


def test_cambered_section_has_a_nose_down_moment():
    r = Solver([section("2412", naca4("2412")).coords]).solve(0)
    assert r.cl_total == pytest.approx(0.26, abs=0.01)
    assert r.cm_total == pytest.approx(-0.055, abs=0.005)


def test_closed_and_open_trailing_edges_agree():
    open_ = Solver([section("o", naca4("0012")).coords]).solve(6).cl_total
    closed = Solver([section("c", naca4("0012", closed=True)).coords]).solve(6).cl_total
    assert closed == pytest.approx(open_, rel=0.01)


def test_inverted_for_downforce():
    base = section("4412", naca4("4412")).coords
    up = Solver([_place(base, 1, 0, (0, 0))]).solve(3).cl_total
    down = Solver([_place(base, 1, 0, (0, 0), flip=True)]).solve(-3).cl_total
    assert down == pytest.approx(-up, rel=1e-6)


def test_far_apart_elements_barely_interact():
    """Two sections in tandem 20 chords apart: the front one's downwash there
    is about 0.17 degrees, so a few percent; ten times further, a tenth."""
    base = section("2412", naca4("2412")).coords
    single = Solver([base]).solve(4).cl_total
    near = Solver([base, base + (20, 0)]).solve(4).cl
    far = Solver([base, base + (200, 0)]).solve(4).cl
    assert near[1] < single and abs(near[1] / single - 1) == pytest.approx(0.028, abs=0.005)
    assert abs(far[1] / single - 1) == pytest.approx(abs(near[1] / single - 1) / 10, rel=0.2)


def _two_element(n: int):
    main = section("main", naca4("4412", n=n)).coords
    flap = section("flap", naca4("4412", n=n)).coords
    return [_place(main, 1.0, 0, (0, 0)), _place(flap, 0.35, 20, (0.97, -0.05))]


def test_two_element_wing_converges_with_panel_count():
    ref = Solver(_two_element(641)).solve(4)
    errs = []
    for n in (81, 161, 321):
        r = Solver(_two_element(n)).solve(4)
        errs.append(abs(r.cl_total / ref.cl_total - 1))
    assert errs[1] < 0.005 and errs[2] < errs[1] < errs[0]
    # A deflected flap loads the main element up: more lift than the main alone.
    alone = Solver(_two_element(161)[:1]).solve(4).cl_total
    assert Solver(_two_element(161)).solve(4).cl[0] > alone
