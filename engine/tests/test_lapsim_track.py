"""Real event layouts bundled in data/tracks."""

from __future__ import annotations

import pytest


@pytest.mark.parametrize("name, length", [("fsg_2019", 309.0), ("fsi_2019", 218.0)])
def test_event_tracks(name, length):
    import numpy as np

    from aeroengine.lapsim.track import resolve

    t = resolve({"builtin": name})
    assert t.closed and t.length == pytest.approx(length, abs=5)
    # FS rules keep hairpins to at least 9 m outside diameter: a centreline radius of about 3 m or more.
    assert 1 / np.max(np.abs(t.kappa)) > 2.8
