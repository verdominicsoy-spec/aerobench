"""The base car: its wheels and the ground they stand on.

Wheels are found as the large solids that are round seen from the side and
narrow across; several solids sharing a centre (tyre, rim) count once. The
ground is the lowest wheel bottom. The user confirms or corrects both.
"""

from __future__ import annotations

from pathlib import Path

from OCP.Bnd import Bnd_Box
from OCP.BRepBndLib import BRepBndLib
from OCP.TopAbs import TopAbs_SOLID

from ..cad.bodyrepair import _subshapes
from ..cad.edit.refs import load_part
from ..job import EngineError

MIN_WHEEL_MM = 250.0  # smaller round solids are hubs, discs, uprights


def _box(shape):
    b = Bnd_Box()
    BRepBndLib.Add_s(shape, b)
    lo, hi = b.CornerMin(), b.CornerMax()
    return (lo.X(), lo.Y(), lo.Z()), (hi.X(), hi.Y(), hi.Z())


def find_wheels(shape) -> list[dict]:
    """FL, FR, RL, RR in a car frame with +x forward, +y left, z up (mm)."""
    found = []
    for solid in _subshapes(shape, TopAbs_SOLID):
        lo, hi = _box(solid)
        dx, dy, dz = (h - l for h, l in zip(hi, lo))
        if min(dx, dz) < MIN_WHEEL_MM or abs(dx - dz) > 0.1 * max(dx, dz) or dy > 0.8 * min(dx, dz):
            continue
        centre = [(h + l) / 2 for h, l in zip(hi, lo)]
        same = next((w for w in found if sum((a - b) ** 2 for a, b in zip(w["centre"], centre)) ** 0.5 < 20), None)
        r = (dx + dz) / 4
        if same is None:
            found.append({"centre": centre, "radius": r, "width": dy})
        elif r > same["radius"]:
            same.update(radius=r, width=max(same["width"], dy))
    if len(found) != 4:
        raise EngineError(f"found {len(found)} wheels, not 4", "set the wheels by hand")
    front_x = max(w["centre"][0] for w in found)
    for w in found:
        axle = "F" if w["centre"][0] > front_x - 200 else "R"
        w["name"] = axle + ("L" if w["centre"][1] > 0 else "R")
        w["centre"] = [round(c, 3) for c in w["centre"]]
        w["radius"], w["width"] = round(w["radius"], 3), round(w["width"], 3)
    if sorted(w["name"] for w in found) != ["FL", "FR", "RL", "RR"]:
        raise EngineError("the wheels are not two each side on two axles", "set the wheels by hand")
    return sorted(found, key=lambda w: w["name"])


def ground_z(wheels: list[dict]) -> float:
    return round(min(w["centre"][2] - w["radius"] for w in wheels), 3)


def setup(path: Path, forward: str = "+x", up: str = "+z") -> dict:
    if (forward, up) != ("+x", "+z"):
        raise EngineError("only +x forward and +z up are supported so far", "export the car with those axes")
    shape, _, _ = load_part(Path(path), None)
    wheels = find_wheels(shape)
    return {"step": str(path), "forward": forward, "up": up, "wheels": wheels, "ground_z": ground_z(wheels),
            "head_restraint": None, "speed": 15.0}
