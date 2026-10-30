"""Every library section's polar at one Reynolds number (NeuralFoil, about
2 ms a section), boiled down to the numbers worth sorting by: maximum lift
and best lift-to-drag, with the angles they come at. Written beside the
index as polars.json, so the app can show and sort by them."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import numpy as np

from ..job import EngineError
from .viscous import polar

ALPHAS = np.arange(-4.0, 25.0, 1.0)  # past the stall of high-lift sections


def summary(coords: np.ndarray, re: float, n_crit: float = 9.0) -> dict:
    rows = polar(coords, ALPHAS, re, n_crit)["rows"]
    cl = np.array([r["cl"] for r in rows])
    cd = np.array([r["cd"] for r in rows])
    ld = cl / np.maximum(cd, 1e-6)
    i, j = int(np.argmax(cl)), int(np.argmax(ld))
    return {
        "cl_max": round(float(cl[i]), 4), "alpha_cl_max": float(ALPHAS[i]),
        "ld_max": round(float(ld[j]), 2), "alpha_ld_max": float(ALPHAS[j]), "cl_at_ld_max": round(float(cl[j]), 4),
        "cd_min": round(float(cd.min()), 5),
        # Maximum lift at the end of the sweep means it was not found; NeuralFoil
        # unsure at maximum lift means the number is a guess.
        "trusted": bool(rows[i]["trusted"] and i < len(ALPHAS) - 1),
    }


def build(root: Path, re: float, n_crit: float = 9.0, progress=None) -> dict:
    """root is the airfoils folder holding index.sqlite."""
    index = root / "index.sqlite"
    if not index.exists():
        raise EngineError("no airfoil library yet", "download it or build the NACA set first")
    db = sqlite3.connect(index)
    try:
        sections = db.execute("SELECT key, coords FROM airfoils").fetchall()
    finally:
        db.close()
    out, failed = {}, []
    for k, (key, coords) in enumerate(sections):
        try:
            out[key] = summary(np.asarray(json.loads(coords), float), re, n_crit)
        except Exception as exc:  # one odd section must not stop the rest
            failed.append({"key": key, "error": str(exc)[:200]})
        if progress and k % 100 == 0:
            progress(100 * k / max(len(sections), 1), f"{k} of {len(sections)} sections")
    result = {"re": re, "n_crit": n_crit, "alphas": [float(ALPHAS[0]), float(ALPHAS[-1])], "rows": out}
    tmp = root / "polars.json.tmp"
    tmp.write_text(json.dumps(result, separators=(",", ":")))
    tmp.replace(root / "polars.json")
    return {"re": re, "n_crit": n_crit, "count": len(out), "failed": failed, "file": str(root / "polars.json")}
