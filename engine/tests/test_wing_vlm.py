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


FRONTWING = dict(span=0.5245, chord=0.6245, height=0.0966, endplate=0.315, endplate_bottom=0.035)


def test_chordwise_angle_vanishes_on_an_endless_span():
    a = Lattice(span=1000.0, chord=1.0).chordwise([0.1, 0.5, 0.9])
    assert np.all(np.abs(a) < 1e-3)


def test_chordwise_angle_on_a_slender_wing_barely_grows_along_the_chord():
    a = Lattice(span=10.0, chord=1.0).chordwise([0.1, 0.5, 0.9])
    assert a[0] > 0 and a[0] < a[1] < a[2] < 1.3 * a[0]


def test_chordwise_angle_on_a_short_wing_by_the_ground_grows_aft():
    # frontwing#1.02 (aspect ratio 0.77): the flaps meet a steeper flow than the main (STAR, 15 Nov)
    a = Lattice(**FRONTWING).chordwise([0.1, 0.5, 0.9])
    assert a[0] < a[1] < a[2] and a[2] > 2 * a[0]


def test_chordwise_angle_with_the_flat_plates_own_loading_is_unchanged():
    lat = Lattice(**FRONTWING)
    _, _, _, wing, _, _, _, gam = lat._system()
    g = gam[wing].reshape(lat.ny, lat.nx)[lat.ny // 2]
    own = lat.chordwise([0.1, 0.5, 0.9], loading=g / g.sum())
    # every strip gets mid-span's shape, where the flat plate keeps each strip's own: 4% at the nose
    assert own == pytest.approx(lat.chordwise([0.1, 0.5, 0.9]), rel=5e-2)


def test_chordwise_angle_of_any_loading_vanishes_on_an_endless_span():
    lat = Lattice(span=1000.0, chord=1.0, nx=8)
    aft = np.linspace(1.0, 3.0, 8)
    assert np.all(np.abs(lat.chordwise([0.1, 0.5, 0.9], loading=aft / aft.sum())) < 1e-3)


def _flat_profile(chord: float, n: int, angle: float = 0.0):
    """n equal panels along a flat chord line at angle (rad, trailing edge down), nose at height 0."""
    x = np.linspace(0.0, chord, n + 1)
    pts = np.stack([x * math.cos(angle), -x * math.sin(angle)], axis=1)
    return [(tuple(pts[i]), tuple(pts[i + 1])) for i in range(n)]


def test_a_flat_profile_at_an_angle_carries_the_flat_plates_lift():
    # the profile carries its own angle (flow along x): 0.005 rad of flat plate is 0.005 of the plain lattice
    # (at 0.05 the tilted plate sits 5% of its chord lower at the back, and the tips carry 8% more)
    plain = Lattice(span=4.0, chord=1.0, nx=8).solve().cl
    tilted = Lattice(span=4.0, chord=1.0, profile=_flat_profile(1.0, 8, 0.005)).solve().cl
    assert tilted == pytest.approx(0.005 * plain, rel=2e-3)


def test_a_flat_profile_with_endplates_over_the_ground_matches_the_plain_lattice():
    kw = dict(span=0.5245, chord=0.6245, height=0.0966, endplate=0.315, endplate_bottom=0.035)
    plain = Lattice(**kw).chordwise([0.1, 0.5, 0.9])
    prof = Lattice(**kw, profile=_flat_profile(0.6245, 8, 0.01)).chordwise([0.1, 0.5, 0.9])
    assert prof == pytest.approx(plain, rel=3e-2)


def _two_elements(chord: float = 1.0):
    """A downforce main and a flap climbing behind it (trailing edges up), the flap's nose over the
    main's trailing edge, as frontwing#1.02's."""
    main = [((0.6 * i / 6, 0.02 * i / 6), (0.6 * (i + 1) / 6, 0.02 * (i + 1) / 6)) for i in range(6)]
    nose = np.array([0.55, 0.05])
    tail = nose + 0.45 * np.array([math.cos(0.4), math.sin(0.4)])
    flap = [(tuple(nose + (tail - nose) * i / 4), tuple(nose + (tail - nose) * (i + 1) / 4)) for i in range(4)]
    return main + flap


def test_a_stacked_profile_sees_no_induced_angle_on_an_endless_span():
    lat = Lattice(span=1000.0, chord=1.0, height=0.3, profile=_two_elements())
    assert np.all(np.abs(lat.panel_angles()) < 1e-3)


def test_the_flap_climbing_toward_the_endplates_top_meets_more_induced_angle():
    # frontwing#1.02: flap 3 near the endplates' top edge, the main by the ground
    kw = dict(span=0.5245, chord=1.0, height=0.1, endplate=0.4, endplate_bottom=0.035)
    a = Lattice(**kw, profile=_two_elements()).panel_angles()
    assert a[6:].mean() > a[:6].mean() > 0


def test_panel_loads_split_the_mid_span_circulation_by_panel():
    lat = Lattice(span=1000.0, chord=1.0, height=0.3, profile=_two_elements())
    g = lat.panel_loads()
    assert g.shape == (10,) and np.all(g < 0)  # downforce
    assert 2 * g.sum() == pytest.approx(lat.solve().cl[lat.ny // 2], rel=1e-2)  # Cl = 2 Gamma / c


def test_a_steep_panel_meets_the_same_induced_angle_as_a_level_one():
    # a flow turned by d changes a panel's normal speed by n_z d: the angle is the normal speed over n_z
    # (frontwing#1.02's flap 3 sits at 42 deg on the car; over n_z = 1 it read 26% low). A slender wing, so
    # the plate's wake leaving level from its tilted vortices is far from the strips (at span 10 it is 11%)
    level = Lattice(span=100.0, chord=1.0, profile=_flat_profile(1.0, 8, 0.01)).panel_angles()
    steep = Lattice(span=100.0, chord=1.0, profile=_flat_profile(1.0, 8, 0.5)).panel_angles()
    assert steep.mean() == pytest.approx(level.mean(), rel=1e-2)
