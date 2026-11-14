"""The vortex lattice behind the on-car induced angle: against the classic
results it has to reproduce before it is trusted on a short wing near a ground."""

from __future__ import annotations

import math

import numpy as np
import pytest

from aeroengine.wing.finite import ground_factor
from aeroengine.wing.vlm import Lattice, section_slope


def helmbold(ar: float) -> float:  # lift slope per radian of a straight wing
    return 2 * math.pi * ar / (2 + math.sqrt(ar * ar + 4))


@pytest.mark.parametrize("ar", [1.0, 2.0, 6.0])
def test_rectangular_wing_lift_slope(ar):
    # Helmbold's formula runs 2-7% above lifting-surface theory on rectangular wings.
    w = Lattice(span=ar, chord=1.0).solve()
    assert w.lift_slope == pytest.approx(helmbold(ar), rel=0.08)
    assert Lattice(span=ar, chord=1.0, ny=48).solve().lift_slope == pytest.approx(w.lift_slope, rel=0.003)  # settled


def test_two_dimensional_limit():
    assert section_slope(1.0, None) == pytest.approx(2 * math.pi, rel=0.01)
    w = Lattice(span=1000.0, chord=1.0).solve()
    mid = len(w.induced) // 2
    assert w.induced[mid] == pytest.approx(0.0, abs=0.003)  # radians per radian of alpha


def test_free_air_induced_drag_as_lifting_line():
    # Short rectangular wings load nearly elliptically: span efficiency 0.98-1.
    for ar in (2.0, 6.0):
        w = Lattice(span=ar, chord=1.0).solve()
        assert 1 / (w.k_drag * math.pi * ar) == pytest.approx(0.99, abs=0.015)
        assert w.k_lift > w.k_drag  # lifting surface: the chord sees more than the downwash at the wing


def test_endplates_as_hoerner():
    # Endplates 0.1 of the span, centred on the wing: Hoerner's AR (1 + 1.9 h/b), made for small h/b.
    bare = Lattice(span=4.0, chord=1.0).solve()
    plated = Lattice(span=4.0, chord=1.0, endplate=0.4, endplate_bottom=-0.2).solve()
    assert bare.k_drag / plated.k_drag == pytest.approx(1.19, rel=0.1)


@pytest.mark.parametrize("hb", [0.1, 0.2])
def test_ground_as_wieselsberger(hb):
    span = 6.0
    free = Lattice(span=span, chord=1.0).solve()
    near = Lattice(span=span, chord=1.0, height=hb * span).solve()
    assert near.k_drag / free.k_drag == pytest.approx(ground_factor(hb * span, span), rel=0.03)


def test_ground_raises_the_section_slope():
    assert section_slope(1.0, 0.1) > section_slope(1.0, 0.3) > section_slope(1.0, None)
    assert section_slope(1.0, 50.0) == pytest.approx(2 * math.pi, rel=0.01)


def test_sealed_endplates_cut_the_induced_angle():
    # Endplates down to the ground's gap: the tip leak closes and the induced angle falls.
    open_ = Lattice(span=1.0, chord=0.5, height=0.1, endplate=0.3, endplate_bottom=0.1).solve()
    sealed = Lattice(span=1.0, chord=0.5, height=0.1, endplate=0.37, endplate_bottom=0.03).solve()
    assert sealed.k_drag < 0.8 * open_.k_drag


def test_level_wing_is_unchanged_by_a_zero_drop():
    a = Lattice(span=1.0, chord=0.5, height=0.1, endplate=0.3, endplate_bottom=0.03).solve()
    b = Lattice(span=1.0, chord=0.5, height=0.1, endplate=0.3, endplate_bottom=0.03, drop=0.0).solve()
    assert b.k_drag == a.k_drag and b.lift_slope == a.lift_slope


@pytest.mark.parametrize("kw, rel", [({}, 0.01), ({"height": 0.1, "endplate": 0.3, "endplate_bottom": 0.03}, 0.03)])
def test_strip_angles_carry_the_lattice_induced_drag(kw, rel):
    # One strip per column, loaded as the lattice loads itself: the lift-weighted induced angle is Cdi.
    # With endplates the plates' own side force carries 2% of it (a thrust), which no wing strip sees.
    w = Lattice(span=1.0, chord=0.5, **kw)
    r = w.solve()
    s = w.strips(w.ny)
    cdi = float(np.sum(r.cl * (s.k @ r.cl) * s.width)) / w.span
    assert cdi == pytest.approx(r.k_drag * r.lift_slope ** 2, rel=rel)


def test_strips_of_a_level_wing_are_symmetric():
    s = Lattice(span=1.0, chord=0.5, height=0.1, endplate=0.3, endplate_bottom=0.03).strips(4)
    assert s.k == pytest.approx(s.k[::-1, ::-1], rel=1e-6)
    assert s.y == pytest.approx(-s.y[::-1]) and s.width.sum() == pytest.approx(1.0)


def test_strips_on_an_endless_span_see_no_induced_angle():
    # Loaded evenly: each strip alone trails vortices at its edges, but evenly the inner edges cancel.
    s = Lattice(span=1000.0, chord=1.0).strips(4)
    assert np.abs(s.k @ np.ones(4))[1:3].max() < 3e-4  # inboard strips; the outer two see the far tips


def test_dropped_wing_sees_more_induced_angle_inboard_at_its_high_end():
    # Endplate bottoms level over the ground, the wing 50 mm lower at +y: the low side is in more ground effect.
    kw = dict(span=1.0, chord=0.5, height=0.1, endplate=0.3, endplate_bottom=0.03)
    s = Lattice(**kw, drop=0.05).strips(4)
    assert s.height[0] == pytest.approx(0.1 + 0.05 * 0.375) and s.height[-1] == pytest.approx(0.1 - 0.05 * 0.375)
    load = s.k @ np.ones(4)
    assert load[1] > load[2] > 0
    assert Lattice(**kw, drop=-0.05).strips(4).k == pytest.approx(s.k[::-1, ::-1], rel=1e-6)  # the mirror image
