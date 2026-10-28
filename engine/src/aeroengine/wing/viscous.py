"""Quick viscous polars for one section: NeuralFoil.

NeuralFoil (Sharpe, MIT licence) is a neural network trained on XFOIL
runs: lift, drag and moment with free transition at a Reynolds number, and
where each surface goes from laminar to turbulent, in milliseconds. It is
one section at a time, in isolation: no slot effects between elements.
Its own confidence score is passed on, and answers it is unsure of are
flagged rather than shown as good.
"""

from __future__ import annotations

import numpy as np

from ..job import EngineError

CONFIDENT = 0.8  # NeuralFoil's analysis_confidence below this is flagged


def reynolds(speed: float, chord: float, rho: float = 1.225, mu: float = 1.81e-5) -> float:
    if speed <= 0 or chord <= 0 or rho <= 0 or mu <= 0:
        raise EngineError("speed, chord, density and viscosity must be above zero")
    return rho * speed * chord / mu


def polar(coords: np.ndarray, alphas, re: float, n_crit: float = 9.0, inverted: bool = False,
          model_size: str = "large") -> dict:
    """Coefficients over angles of attack for one unit-chord section in
    Selig order. With `inverted` the section is analysed upright and the
    answer mirrored: lift and moment change sign, and the surfaces swap, so
    "suction" is always the side the load pulls towards."""
    try:
        import neuralfoil as nf
    except ImportError as exc:  # pragma: no cover
        raise EngineError("NeuralFoil is not installed in the engine", "run uv sync in engine/") from exc
    coords = np.asarray(coords, float)
    if coords.ndim != 2 or coords.shape[1] != 2 or len(coords) < 10:
        raise EngineError("the section needs at least ten [x, y] points")
    if not 1e3 <= re <= 1e8:
        raise EngineError(f"Reynolds number {re:.3g} is outside 1e3 to 1e8")
    a = np.atleast_1d(np.asarray(alphas, float))
    r = nf.get_aero_from_coordinates(coordinates=coords, alpha=a, Re=re, n_crit=n_crit, model_size=model_size)
    sign = -1.0 if inverted else 1.0
    top, bottom = np.asarray(r["Top_Xtr"], float), np.asarray(r["Bot_Xtr"], float)
    conf = np.asarray(r["analysis_confidence"], float)
    rows = []
    for k, al in enumerate(a):
        rows.append({
            "alpha": float(al),  # the element's own angle: bigger means more load either way up
            "cl": float(sign * r["CL"][k]),
            "cd": float(r["CD"][k]),
            "cm": float(sign * r["CM"][k]),
            # x/c where each surface turns turbulent (1 = laminar to the trailing
            # edge). The section is analysed upright, so the suction side is
            # always its upper surface; on an inverted wing that surface faces down.
            "transition_suction": float(top[k]),
            "transition_pressure": float(bottom[k]),
            "confidence": float(conf[k]),
            "trusted": bool(conf[k] >= CONFIDENT),
        })
    return {"re": re, "n_crit": n_crit, "inverted": inverted, "rows": rows}
