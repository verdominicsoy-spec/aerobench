from __future__ import annotations

import io
import json

from aeroengine.events import Emitter


def test_progress_is_clamped_and_one_line_per_event():
    buf = io.StringIO()
    e = Emitter(buf)
    e.progress(150, "over")
    e.progress(-3)
    e.error("boom", "trace")
    lines = buf.getvalue().splitlines()
    assert [json.loads(l) for l in lines] == [
        {"type": "progress", "pct": 100.0, "msg": "over"},
        {"type": "progress", "pct": 0.0, "msg": ""},
        {"type": "error", "msg": "boom", "detail": "trace"},
    ]


def test_closed_stdout_does_not_crash_the_job():
    class Broken(io.StringIO):
        def write(self, s):
            raise BrokenPipeError

    e = Emitter(Broken())
    e.log("first")
    e.log("second")  # silently dropped, no exception
