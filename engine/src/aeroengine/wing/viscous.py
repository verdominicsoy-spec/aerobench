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
# NeuralFoil (so XFOIL) reads lift high at low Reynolds numbers. One scale takes
# 171 UIUC clean runs (52 sections, Re 1.5 to 5 x 10^5) from a mean error of 9.7%
# to 7.0%, scored on each section left out of the fit (best scale -5.9%); section
# shape, Reynolds number and lift level added nothing. It fades out to 2 x 10^6,
# where the elements of the NLR 7301 and 30P30N need none. Untested in the fade.
LOW_RE_LIFT_SCALE = 0.94
LOW_RE, HIGH_RE = 5e5, 2e6


def tunnel_lift_scale(re: float) -> float:
    """What NeuralFoil's lift is multiplied by to match the tunnel at this Reynolds number."""
    return float(1 + (LOW_RE_LIFT_SCALE - 1) * np.clip(np.log(HIGH_RE / re) / np.log(HIGH_RE / LOW_RE), 0.0, 1.0))


def reynolds(speed: float, chord: float, rho: float = 1.225, mu: float = 1.81e-5) -> float:
    if speed <= 0 or chord <= 0 or rho <= 0 or mu <= 0:
        raise EngineError("speed, chord, density and viscosity must be above zero")
    return rho * speed * chord / mu


def check_re(re: float) -> None:
    if not 1e3 <= re <= 1e8:
        raise EngineError(f"Reynolds number {re:.3g} is outside 1e3 to 1e8")


def polar(coords: np.ndarray, alphas, re: float, n_crit: float = 9.0, inverted: bool = False,
          model_size: str = "large", xtr: float = 1.0, tunnel: bool = True) -> dict:
    """Coefficients over angles of attack for one unit-chord section in
    Selig order. With `inverted` the section is analysed upright and the
    answer mirrored: lift and moment change sign, and the surfaces swap, so
    "suction" is always the side the load pulls towards. xtr below 1 trips
    both surfaces there (x/c), as a wind-tunnel model's grit does. `tunnel`
    applies tunnel_lift_scale; off gives NeuralFoil's own lift, which a
    multi-element estimate needs, being fitted to RANS on it."""
    try:
        import neuralfoil as nf
    except ImportError as exc:  # pragma: no cover
        raise EngineError("NeuralFoil is not installed in the engine", "run uv sync in engine/") from exc
    coords = np.asarray(coords, float)
    if coords.ndim != 2 or coords.shape[1] != 2 or len(coords) < 10:
        raise EngineError("the section needs at least ten [x, y] points")
    check_re(re)
    a = np.atleast_1d(np.asarray(alphas, float))
    r = nf.get_aero_from_coordinates(coordinates=coords, alpha=a, Re=re, n_crit=n_crit, xtr_upper=xtr, xtr_lower=xtr,
                                     model_size=model_size)
    sign = -1.0 if inverted else 1.0
    scale = tunnel_lift_scale(re) if tunnel else 1.0
    top, bottom = np.asarray(r["Top_Xtr"], float), np.asarray(r["Bot_Xtr"], float)
    conf = np.asarray(r["analysis_confidence"], float)
    rows = []
    for k, al in enumerate(a):
        rows.append({
            "alpha": float(al),  # the element's own angle: bigger means more load either way up
            "cl": float(sign * scale * r["CL"][k]),
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
