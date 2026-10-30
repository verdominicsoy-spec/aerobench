"""aeroengine serve: requests on stdin, one reply each, the server survives bad ones."""

from __future__ import annotations

import io
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from test_wing_estimate import _elements, _starter

from aeroengine.events import Emitter
from aeroengine.serve import serve


def _replies(lines: list[str]) -> list[dict]:
    out = io.StringIO()
    serve(Emitter(out), io.StringIO("\n".join(lines) + "\n"), warm=False)
    return [json.loads(x) for x in out.getvalue().splitlines()]


def test_answers_each_request_and_survives_bad_ones():
    good = json.dumps({"id": 3, "command": "wing-estimate",
                       "params": {"elements": _elements(_starter()), "alphas": [0.0, 2.0], "speed": 15}})
    events = _replies(["not json", json.dumps({"id": 1, "command": "wing-rans"}), "",
                       json.dumps({"id": 2, "command": "wing-estimate", "params": {}}), good])
    assert events[0]["type"] == "ready" and events[0]["commands"] == ["wing-estimate"]
    replies = [e for e in events if e["type"] == "reply"]
    assert [r["id"] for r in replies] == [None, 1, 2, 3]
    assert "error" in replies[0] and "wing-rans" in replies[1]["error"] and "elements" in replies[2]["error"]
    rows = replies[3]["data"]["rows"]
    assert [r["alpha"] for r in rows] == [0.0, 2.0] and rows[1]["cl"] > rows[0]["cl"]


def test_the_command_line_server_is_quick_once_loaded():
    proc = subprocess.Popen([sys.executable, "-m", "aeroengine", "serve"], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, text=True)
    try:
        assert json.loads(proc.stdout.readline())["type"] == "ready"
        req = {"command": "wing-estimate", "params": {"elements": _elements(_starter()),
                                                      "alphas": [float(a) for a in range(-6, 13)]}}
        times = []
        for i in range(3):
            t = time.perf_counter()
            proc.stdin.write(json.dumps({"id": i, **req}) + "\n")
            proc.stdin.flush()
            reply = json.loads(proc.stdout.readline())
            times.append(time.perf_counter() - t)
            assert reply["id"] == i and len(reply["data"]["rows"]) == 19
        assert min(times) < 0.5  # about 30 ms here; fast enough to follow a drag
        proc.stdin.close()
        assert proc.wait(timeout=10) == 0
    finally:
        proc.kill()
