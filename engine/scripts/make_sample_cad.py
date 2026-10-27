"""Builds the synthetic CAD samples in samples/.

    uv run python scripts/make_sample_cad.py            # sample_car.step / .igs / .stl / .obj
    uv run python scripts/make_sample_cad.py --dense    # also dense_1M.stl (~50 MB, not committed)

The sample car is a named STEP assembly with exactly known dimensions, used by
the tests and for checking the CAD Viewer by hand:

    Chassis           box 1500 x 600 x 300 mm, corner at the origin
    Wheel             cylinder, diameter 457.2 mm, width 200 mm, axis along y,
                      instanced four times: Wheel FL, FR, RL, RR
                      wheelbase 1530 mm (front axle x = -15, rear axle x = 1515)
    Front Wing        sub-assembly: Main Plane (NACA 4412, chord 300 mm) and
                      Flap 1 (NACA 4412, chord 150 mm), span 1200 mm
    Rear Wing         sub-assembly, same Main Plane and Flap parts reused
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from aeroengine.cad.sample import build_sample_car, write_dense_stl  # noqa: E402
from aeroengine.cad.tessellate import tessellate_file  # noqa: E402
from aeroengine.cad.meshio import write_obj, write_stl  # noqa: E402

SAMPLES = Path(__file__).resolve().parents[2] / "samples"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dense", action="store_true", help="also write dense_1M.stl")
    ap.add_argument("--out", type=Path, default=SAMPLES)
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    step = args.out / "sample_car.step"
    iges = args.out / "sample_car.igs"
    build_sample_car(step, iges)
    print("wrote", step, iges)

    # STL and OBJ straight from the tessellated STEP, in mm like a CAD export.
    model = tessellate_file(step, "medium")
    write_stl(model, args.out / "sample_car.stl", scale=1000.0)
    write_obj(tessellate_file(step, "coarse"), args.out / "sample_car.obj", scale=1000.0)
    print("wrote sample_car.stl (medium), sample_car.obj (coarse), both in mm")

    if args.dense:
        path = args.out / "dense_1M.stl"
        n = write_dense_stl(path, 1_000_000)
        print(f"wrote {path} with {n} triangles")


if __name__ == "__main__":
    main()
