"""The vortex lattice behind the on-car induced angle: against the classic
results it has to reproduce before it is trusted on a short wing near a ground."""

from __future__ import annotations

import math

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
