"""aeroengine serve: a long-lived engine for requests that take milliseconds
once loaded, so the app can update them live (the quick estimate while an
element is dragged). Loading NeuralFoil takes several seconds; after that a
19-angle estimate takes about 30 ms.

Requests, one JSON object per line on stdin:

    {"id": 1, "command": "wing-estimate", "params": {...}}

Replies on the event stream, one per request, in order:

    {"type": "reply", "id": 1, "data": {...}}
    {"type": "reply", "id": 1, "error": "...", "detail": "..."}

A {"type": "ready"} event comes once the engine is loaded. It exits when
stdin closes."""

from __future__ import annotations

import json
import traceback
from collections.abc import Callable
from typing import TextIO

from .events import Emitter
from .job import EngineError


def _wing_estimate(params: dict) -> dict:
    from .commands.wing import estimate_from_params

    return estimate_from_params(params)


def _lapsim_track(params: dict) -> dict:
    """A track's centreline, for the app's track editor to start from."""
    from .lapsim.track import DEFAULT_DS, resolve

    t = resolve(params.get("track"), float(params.get("ds", DEFAULT_DS)))
    return {"name": t.name, "closed": t.closed, "length": t.length,
            "x": [round(float(v), 4) for v in t.x], "y": [round(float(v), 4) for v in t.y]}


def _part_edit(params: dict) -> dict:
    """The part editor's rebuild: the whole feature list in, the result out."""
    import tempfile
    from pathlib import Path

    from .cad.edit.build import build

    path = Path(params.get("path") or "").expanduser()
    if not path.is_file():
        raise EngineError(f"file not found: {path}")
    out_dir = Path(params.get("out_dir") or Path(tempfile.gettempdir()) / "aerobench-part-edit")
    reply = build(path, params.get("part"), list(params.get("features") or []), params.get("fingerprint"), out_dir)
    # The app loads each GLB once; keep the last few in case one is still loading.
    for old in sorted(out_dir.glob("*.glb"), key=lambda p: p.stat().st_mtime)[:-8]:
        old.unlink(missing_ok=True)
    return reply


def _car_section(params: dict) -> dict:
    """The base car cut at y, for the Car tool's live section view."""
    from pathlib import Path

    from .car.section import cut
    from .cad.edit.refs import load_part

    setup = params.get("setup") or {}
    path = Path(setup.get("step") or "").expanduser()
    if not path.is_file():
        raise EngineError(f"file not found: {path}")
    return cut(load_part(path, None)[0], float(params.get("y", 0.0)), setup)


def _uiuc_results(params: dict) -> dict:
    """The UIUC comparison's history and tunnel points, for the accuracy window."""
    from .validation import results_view

    return results_view()


HANDLERS: dict[str, Callable[[dict], dict]] = {"wing-estimate": _wing_estimate, "lapsim-track": _lapsim_track,
                                               "part-edit": _part_edit, "car-section": _car_section,
                                               "uiuc-results": _uiuc_results}


def _warm_up() -> None:
    """Loads NeuralFoil with a one-element estimate."""
    from .wing.airfoils import naca4
    from .wing.estimate import estimate

    unit = naca4("2412")
    estimate([{"coords": (unit * 0.25).tolist(), "unit": unit.tolist(), "chord": 0.25, "angle": 0.0}], [0.0], 15.0)


def serve(emit: Emitter, requests: TextIO, warm: bool = True) -> int:
    if warm:
        try:
            _warm_up()
        except Exception as exc:  # noqa: BLE001 - the first request will report the real problem
            emit.log(f"warm-up failed: {exc}", level="warning")
    emit.emit({"type": "ready", "commands": sorted(HANDLERS)})
    for line in requests:
        line = line.strip()
        if not line:
            continue
        rid = None
        try:
            req = json.loads(line)
            rid = req.get("id")
            handler = HANDLERS.get(req.get("command"))
            if handler is None:
                raise EngineError(f"serve does not run '{req.get('command')}'", f"it runs: {', '.join(sorted(HANDLERS))}")
            emit.emit({"type": "reply", "id": rid, "data": handler(req.get("params") or {})})
        except EngineError as exc:
            emit.emit({"type": "reply", "id": rid, "error": exc.msg, **({"detail": exc.detail} if exc.detail else {})})
        except Exception as exc:  # noqa: BLE001 - one bad request must not end the server
            emit.emit({"type": "reply", "id": rid, "error": f"{type(exc).__name__}: {exc}",
                       "detail": traceback.format_exc()})
    return 0
