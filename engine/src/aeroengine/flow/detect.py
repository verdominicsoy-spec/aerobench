"""Finds the calibration a person would otherwise draw: the plot region,
the overlays to exclude (legend, labels, axis triad), the legend bar and
whether the ground line is in view.

Overlays are static from frame to frame while the flow changes, and they
have sharp edges, so they show up as static edges in a handful of frames
spread over the sweep. The plot region is wherever the colour map's colours
appear in any of those frames, outside the overlays.
"""

from __future__ import annotations

import cv2
import numpy as np

from . import colormap


def _sample(source, count: int, samples: int) -> tuple[list[int], list[np.ndarray]]:
    pick = sorted(set(np.linspace(0, count - 1, min(samples, count)).round().astype(int)))
    got = list(source.frames(pick))
    return [int(i) for i, _ in got], [f for _, f in got]


def overlay_boxes(frames: list[np.ndarray], pad: int = 6) -> list[tuple[int, int, int, int]]:
    """Boxes [x0, y0, x1, y1) around things drawn over the flow that do not
    change between frames. Anything wider or taller than half the frame is
    left out: that is a fixed camera's ground line or plot border, not an
    overlay."""
    h, w = frames[0].shape[:2]
    total = np.zeros((h, w, 3), np.float32)
    total_sq = np.zeros((h, w, 3), np.float32)
    for f in frames:
        f32 = f.astype(np.float32)
        total += f32
        total_sq += f32 * f32
    mean = total / len(frames)
    spread = np.sqrt(np.maximum(total_sq / len(frames) - mean * mean, 0)).max(axis=2)
    gray = cv2.cvtColor(mean.astype(np.uint8), cv2.COLOR_RGB2GRAY).astype(np.float32)
    grad = np.hypot(cv2.Sobel(gray, cv2.CV_32F, 1, 0), cv2.Sobel(gray, cv2.CV_32F, 0, 1))
    edges = ((spread < 4) & (grad > 60)).astype(np.uint8)
    blob = cv2.morphologyEx(edges, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_RECT, (31, 31)))
    blob = cv2.dilate(blob, cv2.getStructuringElement(cv2.MORPH_RECT, (2 * pad + 1, 2 * pad + 1)))
    n, _, stats, _ = cv2.connectedComponentsWithStats(blob)
    boxes = []
    for x, y, bw, bh, area in stats[1:n]:
        if bw > 0.5 * w or bh > 0.5 * h or area < 200:
            continue
        boxes.append((int(x), int(y), int(x + bw), int(y + bh)))
    return _merge(boxes)


def _merge(boxes: list[tuple[int, int, int, int]], gap: int = 4) -> list[tuple[int, int, int, int]]:
    """Joins boxes that overlap or nearly touch, so a legend and its labels are one."""
    boxes = list(boxes)
    merged = True
    while merged:
        merged = False
        for i in range(len(boxes)):
            for j in range(i + 1, len(boxes)):
                a, b = boxes[i], boxes[j]
                if a[0] - gap < b[2] and b[0] - gap < a[2] and a[1] - gap < b[3] and b[1] - gap < a[3]:
                    boxes[i] = (min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3]))
                    del boxes[j]
                    merged = True
                    break
            if merged:
                break
    return sorted(boxes)


def find_legend(frame: np.ndarray, boxes, lut: colormap.ColorLUT, threshold: float) -> dict | None:
    """The colour bar inside one of the overlay boxes: the row (or column)
    whose colours run steadily through at least 90% of the colour map. Returns
    the line from its low end to its high end, as the legend tool would."""
    best = None
    for x0, y0, x1, y1 in boxes:
        region = frame[y0:y1, x0:x1]
        values, dist = lut.invert(region)
        ok = dist < threshold
        t = (values - lut.vmin) / (lut.vmax - lut.vmin)
        for vertical in (False, True):
            lines_t, lines_ok = (t.T, ok.T) if vertical else (t, ok)
            good = []
            for k in range(lines_t.shape[0]):
                idx = np.where(lines_ok[k])[0]
                if idx.size < 30:
                    continue
                lo, hi = idx[0], idx[-1]
                if idx.size < 0.9 * (hi - lo + 1):
                    continue  # gaps: not a solid bar
                tt = lines_t[k, idx]
                if tt.max() - tt.min() < 0.9:
                    continue
                corr = np.corrcoef(idx, tt)[0, 1]
                if abs(corr) < 0.95:
                    continue
                good.append((k, lo, hi, corr))
            if len(good) < 3:
                continue
            ks = np.array([g[0] for g in good])
            mid = good[int(np.argmin(np.abs(ks - np.median(ks))))]
            k, lo, hi, corr = mid
            length = hi - lo
            if best is not None and length <= best[0]:
                continue
            # The low end of the colour map first.
            a, b = (lo + 0.5, hi + 0.5) if corr > 0 else (hi + 0.5, lo + 0.5)
            if vertical:
                p0, p1 = [x0 + k + 0.5, y0 + a], [x0 + k + 0.5, y0 + b]
            else:
                p0, p1 = [x0 + a, y0 + k + 0.5], [x0 + b, y0 + k + 0.5]
            p0, p1 = [float(c) for c in p0], [float(c) for c in p1]
            half = max(1, min(6, (ks.max() - ks.min()) // 3))
            best = (length, {"p0": p0, "p1": p1, "half_width": int(half), "box": [x0, y0, x1, y1]})
    return best[1] if best else None


def detect(source, cal_data: dict, samples: int = 24) -> dict:
    """Crop, exclusions, legend line and ground visibility for a video."""
    indices, frames = _sample(source, source.count, samples)
    h, w = frames[0].shape[:2]
    preset = (cal_data.get("colormap") or {}).get("preset") or "star_blue_yellow_red"
    lut = colormap.ColorLUT(colormap.preset(preset), -1.0, 1.0)
    threshold = float(cal_data.get("threshold", 12.0))
    tolerance = float(cal_data.get("mask_tolerance", 10.0))
    masks = [list(map(float, c)) for c in cal_data.get("mask_colors", [[255, 255, 255]])]

    boxes = overlay_boxes(frames)
    middle = len(frames) // 2
    legend = find_legend(frames[middle], boxes, lut, threshold)
    if legend is not None:
        legend["frame"] = indices[middle]

    # Where the colour map shows in any frame, at half size for speed.
    flow = np.zeros((h // 2, w // 2), bool)
    for f in frames[:: max(len(frames) // 8, 1)]:
        small = cv2.resize(f, (w // 2, h // 2), interpolation=cv2.INTER_AREA)
        _, dist = lut.invert(small)
        flow |= dist < threshold
    flow = cv2.resize(flow.astype(np.uint8), (w, h), interpolation=cv2.INTER_NEAREST).astype(bool)
    for x0, y0, x1, y1 in boxes:
        flow[y0:y1, x0:x1] = False
    # Specks of matching colour in text or the background are not the plot.
    flow = cv2.morphologyEx(flow.astype(np.uint8), cv2.MORPH_OPEN, np.ones((5, 5), np.uint8)).astype(bool)
    if flow.sum() < 0.01 * h * w:
        return {"found": False, "exclude": [list(b) for b in boxes], "legend": legend,
                "message": "no colour-map colours found; check the colour map preset"}
    ys, xs = np.where(flow)
    x0, x1, y0, y1 = int(xs.min()), int(xs.max()) + 1, int(ys.min()), int(ys.max()) + 1

    # A strip of ground below the flow, so the ground line can be tracked.
    below = []
    for f in frames:
        strip = f[y1: min(y1 + 24, h), x0:x1]
        if strip.shape[0] < 4:
            break
        m = np.zeros(strip.shape[:2], bool)
        for c in masks:
            m |= colormap.lab_distance(strip, c) < tolerance
        below.append(m.mean())
    ground = bool(below) and float(np.median(below)) > 0.5
    crop = [x0, y0, x1, min(y1 + 16, h) if ground else y1]

    exclude = [list(b) for b in boxes if b[0] < crop[2] and crop[0] < b[2] and b[1] < crop[3] and crop[1] < b[3]]
    return {"found": True, "crop": crop, "exclude": exclude, "legend": legend, "ground_visible": ground,
            "frames_sampled": len(frames), "source_size": [w, h]}
