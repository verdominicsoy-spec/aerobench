"""Frames picked by time, as the app picks them, when the frame rate is given."""

from __future__ import annotations

import cv2
import numpy as np
import pytest

from aeroengine.flow.reconstruct import FrameSource


@pytest.fixture
def numbered(tmp_path):
    """30 frames at 30 fps; frame n is a flat grey of level 8 n."""
    path = tmp_path / "n.avi"
    w = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*"MJPG"), 30.0, (32, 24))
    if not w.isOpened():
        pytest.skip("no video writer here")
    for n in range(30):
        w.write(np.full((24, 32, 3), 8 * n, np.uint8))
    w.release()
    return path


def _level(img):
    return int(round(float(np.median(img)) / 8))


def test_counted_and_timed_agree_at_the_true_rate(numbered):
    counted = {i: _level(f) for i, f in FrameSource(numbered).frames([0, 5, 17, 29])}
    timed = {i: _level(f) for i, f in FrameSource(numbered, fps=30.0).frames([0, 5, 17, 29])}
    assert counted == timed == {0: 0, 5: 5, 17: 17, 29: 29}


def test_a_typed_frame_rate_picks_frames_by_time(numbered):
    # Told 15 fps, frame i is what shows at (i + 1/2) / 15 s: source frame 2i + 1.
    src = FrameSource(numbered, fps=15.0)
    assert src.count == 15
    got = {i: _level(f) for i, f in src.frames([0, 3, 14])}
    assert got == {0: 1, 3: 7, 14: 29}
    # And the frame count, when given, is taken as it is.
    assert FrameSource(numbered, fps=15.0, frames=12).count == 12
