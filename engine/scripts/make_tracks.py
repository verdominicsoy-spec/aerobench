"""Builds data/tracks/*.csv (closed centrelines, metres) from the cone
layouts in AMZ's fssim simulator (MIT licence, see data/tracks/LICENSE-fssim.md):
the Formula Student Germany and Italy trackdrive layouts.

    uv run python scripts/make_tracks.py <path to fssim>/fssim_gazebo/models/track/tracks_yaml
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import yaml

TRACKS = {"FSG.yaml": ("fsg_2019", "Formula Student Germany, Hockenheim: trackdrive layout"),
          "FSI.yaml": ("fsi_2019", "Formula Student Italy, Varano: trackdrive layout")}


def centreline(left: np.ndarray, right: np.ndarray) -> np.ndarray:
    """Midpoints between each left cone and the nearest right cone, in the
    left cones' order (they run round the track)."""
    out = []
    for p in left:
        q = right[np.argmin(np.linalg.norm(right - p, axis=1))]
        out.append(0.5 * (p + q))
    pts = np.array(out)
    keep = np.concatenate([[True], np.linalg.norm(np.diff(pts, axis=0), axis=1) > 0.3])
    return pts[keep]


def main(folder: Path) -> None:
    out_dir = Path(__file__).resolve().parents[2] / "data" / "tracks"
    out_dir.mkdir(parents=True, exist_ok=True)
    for src, (name, title) in TRACKS.items():
        d = yaml.safe_load((folder / src).read_text())
        pts = centreline(np.array(d["cones_left"], float), np.array(d["cones_right"], float))
        lines = [f"# {title}", "# Centreline between the cone lines of AMZ fssim's " + src + " (MIT licence, (c) 2019",
                 "# Akademischer Motorsportverein Zurich; see LICENSE-fssim.md). Closed loop, metres.", "x_m,y_m"]
        lines += [f"{x:.3f},{y:.3f}" for x, y in pts]
        (out_dir / f"{name}.csv").write_text("\n".join(lines) + "\n")
        print(name, len(pts), "points")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
