"""JSON-lines event stream written to stdout.

One JSON object per line, flushed immediately so the app sees progress live:

    {"type": "progress", "pct": 42, "msg": "meshing"}
    {"type": "log", "level": "info", "msg": "..."}
    {"type": "result", "path": "result.json"}
    {"type": "error", "msg": "gmsh failed", "detail": "..."}
"""

from __future__ import annotations

import json
import sys
import threading
from typing import Any, TextIO


class Emitter:
    def __init__(self, stream: TextIO | None = None) -> None:
        self._stream = stream if stream is not None else sys.stdout
        self._lock = threading.Lock()
        self._closed = False

    def emit(self, event: dict[str, Any]) -> None:
        line = json.dumps(event, separators=(",", ":"), default=str)
        with self._lock:
            if self._closed:
                return
            try:
                self._stream.write(line + "\n")
                self._stream.flush()
            except (BrokenPipeError, ValueError):
                # The app went away or closed our stdout. Keep running so the
                # job can still clean up after itself, just stop talking.
                self._closed = True

    def progress(self, pct: float, msg: str = "") -> None:
        pct = max(0.0, min(100.0, float(pct)))
        self.emit({"type": "progress", "pct": round(pct, 2), "msg": msg})

    def log(self, msg: str, level: str = "info") -> None:
        self.emit({"type": "log", "level": level, "msg": msg})

    def result(self, path: str) -> None:
        self.emit({"type": "result", "path": path})

    def error(self, msg: str, detail: str | None = None) -> None:
        event: dict[str, Any] = {"type": "error", "msg": msg}
        if detail:
            event["detail"] = detail
        self.emit(event)
