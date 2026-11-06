"""The car's centreline section, solved once: its 2D numbers.

Only 2D: the section's lift and drag per metre of width, Cl and Cd on the
car's length (the section's extent along x), each wing's Cl and Cd on its own
chord, and the share of the section's lift on the rear axle. Nothing is
scaled to a width or corrected to a finite wing, as one section cannot say
how the car changes across it. The result keeps the section under "strips"
for the app's saved results.
"""

from __future__ import annotations

from pathlib import Path


def _axles(setup: dict) -> tuple[float, float]:
    xs = {w["name"][0]: [] for w in setup["wheels"]}
    for w in setup["wheels"]:
        xs[w["name"][0]].append(w["centre"][0])
    return sum(xs["F"]) / len(xs["F"]), sum(xs["R"]) / len(xs["R"])


def _chord_m(wing: dict) -> float:
    """The wing's reference chord (Wing Lab's: the sum of its element chords) when sent, else
    the elements' extents along x."""
    if wing.get("chord"):
        return float(wing["chord"])
    return sum((max(p[0] for p in el) - min(p[0] for p in el)) for el in wing["elements"]) / 1000.0


def combine(sec: dict, setup: dict, speed: float, rho: float, wings: list[dict], mesh: str, ref_length: float,
            flow: dict | None = None) -> dict:
    """Lift up +, as Wing Lab's Cl: a car pressed down has a negative Cl."""
    q = 0.5 * rho * speed * speed
    x_front, x_rear = _axles(setup)
    rear = lambda x: None if x is None else (x_front - x) / (x_front - x_rear)  # noqa: E731 - a force's share on the rear axle
    out_wings = []
    for w in wings:
        pos = w["position"]
        if pos not in sec.get("wing_lift", {}):
            continue
        chord = _chord_m(w)
        out_wings.append({"position": pos, "chord": chord, "cl": sec["wing_lift"][pos] / (q * chord),
                          "cd": sec["wing_drag"].get(pos, 0.0) / (q * chord)})
    return {"mesh": mesh, "speed": speed, "flow": flow, "n": 1, "ref_length": ref_length,
            "cl": sec["lift"] / (q * ref_length), "cd": sec["drag"] / (q * ref_length),
            "rear_share": rear(sec.get("x_cp")), "strips": [sec], "converged": bool(sec["converged"]), "wings": out_wings}


def run(setup: dict, wings: list[dict], flow: dict, preset: str, workdir: Path, su2_hint: str | None, cores: int,
        progress, iterations: int = 6000) -> dict:
    """The centreline section solved; the car result."""
    from ..cad.edit.refs import load_part
    from ..job import EngineError
    from . import case as car_case
    from . import section as car_section

    shape, _, _ = load_part(Path(setup["step"]), None)
    sec = car_section.cut(shape, 0.0, setup)
    xs = [p[0] for lp in sec["loops"] for p in lp["points"]]
    if not xs:
        raise EngineError("the car's centreline cut is empty", "check the STEP is the whole car, centred on y 0")
    r = car_case.solve_section(sec, wings, setup, flow, preset, workdir / "section", su2_hint, cores, progress, iterations)
    r["folder"] = "section"  # its run, and field.json when it has one, in the job folder
    r["open_gaps"] = len(sec.get("open", [])) // 2
    out = combine(r, setup, float(flow.get("speed", setup.get("speed", 15.0))), car_case.RHO, wings, preset,
                  (max(xs) - min(xs)) / 1000.0, flow)
    out["open_gaps"] = r["open_gaps"]
    return out
