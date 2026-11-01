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


def test_drawn_points_and_the_editor_request():
    import io
    import json

    import numpy as np

    from aeroengine.events import Emitter
    from aeroengine.lapsim.track import resolve
    from aeroengine.serve import serve

    th = np.linspace(0, 2 * np.pi, 400, endpoint=False)
    t = resolve({"points": {"x": (20 * np.cos(th)).tolist(), "y": (20 * np.sin(th)).tolist()}, "closed": True})
    assert t.closed and t.name == "Drawn track"
    assert t.length == pytest.approx(2 * np.pi * 20, rel=1e-3)
    assert np.allclose(t.kappa[5:-5], 1 / 20, rtol=1e-2)
    with pytest.raises(Exception, match="points"):
        resolve({"points": [1, 2]})

    out = io.StringIO()
    serve(Emitter(out), io.StringIO(json.dumps({"id": 1, "command": "lapsim-track",
                                                "params": {"track": {"builtin": "fsg_2019"}}}) + "\n"), warm=False)
    data = json.loads(out.getvalue().splitlines()[1])["data"]
    assert data["closed"] and len(data["x"]) == len(data["y"]) > 100
