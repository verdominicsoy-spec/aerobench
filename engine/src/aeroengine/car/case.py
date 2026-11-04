"""The SU2 case for a car section: SST RANS, plain no-slip walls on the
body and wheels' high-y+ mesh, wings resolved to the wall, the ground and
wheels moving or not as asked. Runs through Wing Lab's SU2 runner (CFL fallbacks,
convergence test, early stop), with this file's config.

In the mesh the flow runs along +X with the car standing still: a ground
moving at the air's speed is a slip wall, one moving at another speed slides
along +X at it, a fixed one is no-slip, and a rolling wheel turns about its
axle at speed / radius, counter-clockwise, so its contact point moves with
the ground. Beyond the car's ends the ground ("road") is always slip.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from ..wing import su2
from . import mesh as car_mesh

RHO, MU = 1.225, 1.81e-5


def _walls(markers: list[str]) -> list[str]:
    return [m for m in markers if m == "body" or m.startswith("wheel_") or m.startswith("wing_")]


def config(markers: list[str], setup: dict, flow: dict, mesh_file: str, iterations: int = 6000,
           cfl: float = 10.0, scheme: str = "fds") -> str:
    walls = _walls(markers)
    ground = float(setup.get("ground_z", 0.0))
    speed = float(flow.get("speed", setup.get("speed", 15.0)))
    moving, origins, rotation, translation = [], [], [], []
    ground_moving = flow.get("ground", {}).get("moving", True)
    ground_speed = float(flow.get("ground", {}).get("speed", speed))
    # A ground moving at the air's speed is slip: as a moving no-slip wall its cells (too big to
    # resolve the thin layer it drags) pumped the air under the nose, and the centreline's lift went
    # from +0.3 to -0.1 per metre, coarse to medium; slip gives -0.56 and -0.61. The air the ground
    # drags into the floor gap is left out.
    slip_ground = ground_moving and abs(ground_speed - speed) <= 1e-6 * max(speed, 1.0)
    if ground_moving and not slip_ground:
        moving.append("ground")
        origins += [0.0, 0.0, 0.0]
        rotation += [0.0, 0.0, 0.0]
        translation += [ground_speed, 0.0, 0.0]
    if flow.get("wheels", {}).get("rotating", True):
        wheels = {w["name"]: w for w in setup.get("wheels", [])}
        for m in walls:
            if m.startswith("wheel_") and m[6:] in wheels:
                w = wheels[m[6:]]
                r = w["radius"] / 1000.0
                moving.append(m)
                origins += [round(-w["centre"][0] / 1000.0, 6), round((w["centre"][2] - ground) / 1000.0, 6), 0.0]
                rotation += [0.0, 0.0, round(float(flow["wheels"].get("speed", speed)) / r, 4)]
                translation += [0.0, 0.0, 0.0]
    fmt = lambda xs: ", ".join(str(float(x)) for x in xs)  # noqa: E731
    motion = ""
    if moving:
        motion = (f"SURFACE_MOVEMENT= ( {', '.join(['MOVING_WALL'] * len(moving))} )\n"
                  f"MARKER_MOVING= ( {', '.join(moving)} )\n"
                  f"SURFACE_MOTION_ORIGIN= ( {fmt(origins)} )\n"
                  f"SURFACE_ROTATION_RATE= ( {fmt(rotation)} )\n"
                  f"SURFACE_TRANSLATION_RATE= ( {fmt(translation)} )\n")
    heatflux = ", ".join(f"{w}, 0.0" for w in walls + ([] if slip_ground else ["ground"]))
    slip = (["ground"] if slip_ground else []) + (["road"] if "road" in markers else [])
    slip_line = f"MARKER_SYM= ( {', '.join(slip)} )\n" if slip else ""
    # No wall functions: SU2 8.5's put k near 1e5 (U = 1) on wall nodes at the
    # real car's sharp corners from the first iterations, and SST ran away
    # (eddy viscosity 1e5 to 1e9 times the laminar, CD 7 to 18 per metre, fixed
    # or moving ground); on a rotating wall they gave NaN at once. Plain no-slip
    # on the same mesh settles (centreline: residual down 5 orders).
    flow_scheme = {
        "jst": f"CONV_NUM_METHOD_FLOW= JST\nMUSCL_FLOW= NO\nJST_SENSOR_COEFF= ( {su2.JST_DISSIPATION[0]}, {su2.JST_DISSIPATION[1]} )",
        "fds": "CONV_NUM_METHOD_FLOW= FDS\nMUSCL_FLOW= YES\nSLOPE_LIMITER_FLOW= NONE",
    }[scheme]
    return f"""% AeroBench Car: 2D incompressible RANS of a car section
SOLVER= INC_RANS
KIND_TURB_MODEL= SST
FREESTREAM_TURBULENCEINTENSITY= 0.01
FREESTREAM_TURB2LAMVISCRATIO= 10.0
MATH_PROBLEM= DIRECT
RESTART_SOL= NO
INC_DENSITY_MODEL= CONSTANT
INC_ENERGY_EQUATION= NO
INC_NONDIM= INITIAL_VALUES
INC_DENSITY_INIT= {RHO}
INC_VELOCITY_INIT= ( {speed}, 0.0, 0.0 )
VISCOSITY_MODEL= CONSTANT_VISCOSITY
MU_CONSTANT= {MU}
REF_ORIGIN_MOMENT_X= 0.0
REF_ORIGIN_MOMENT_Y= 0.0
REF_ORIGIN_MOMENT_Z= 0.0
REF_LENGTH= 1.0
REF_AREA= 1.0
MARKER_HEATFLUX= ( {heatflux} )
{slip_line}{motion}MARKER_FAR= ( inlet, outlet, top )
MARKER_PLOTTING= ( {', '.join(walls)} )
MARKER_MONITORING= ( {', '.join(walls)} )
NUM_METHOD_GRAD= GREEN_GAUSS
CFL_NUMBER= {cfl}
CFL_ADAPT= NO
MGLEVEL= 0
LINEAR_SOLVER= FGMRES
LINEAR_SOLVER_PREC= ILU
LINEAR_SOLVER_ERROR= 1E-6
LINEAR_SOLVER_ITER= 15
{flow_scheme}
TIME_DISCRE_FLOW= EULER_IMPLICIT
CONV_NUM_METHOD_TURB= SCALAR_UPWIND
MUSCL_TURB= NO
TIME_DISCRE_TURB= EULER_IMPLICIT
ITER= {iterations}
CONV_FIELD= RMS_PRESSURE
CONV_RESIDUAL_MINVAL= -12
CONV_STARTITER= 10
MESH_FILENAME= {mesh_file}
MESH_FORMAT= SU2
SCREEN_OUTPUT= ( INNER_ITER, RMS_PRESSURE, LIFT, DRAG )
HISTORY_OUTPUT= ( ITER, RMS_RES, AERO_COEFF, AERO_COEFF_SURF )
CONV_FILENAME= history
OUTPUT_FILES= ( RESTART, PARAVIEW, SURFACE_CSV )
VOLUME_OUTPUT= ( COORDINATES, SOLUTION, PRIMITIVE )
OUTPUT_WRT_FREQ= {min(iterations, su2.WRITE_EVERY)}
VOLUME_FILENAME= flow
SURFACE_FILENAME= surface
RESTART_FILENAME= restart.dat
"""


@dataclass
class CarCase(su2.Case):
    # A car is a bluff body: upwind FDS holds steady where Wing Lab's JST
    # drifted (a box near the ground: CD 1 to 12 with JST, steady with FDS),
    # and its residual seldom falls 4 orders, so converged means 2 orders
    # down and lift and drag within 0.5 % over the last 500 iterations.
    scheme: str = "fds"
    residual_drop: float = 2.0
    window: int = 500
    tolerance: float = 5e-3
    markers: list = field(default_factory=list)
    setup: dict = field(default_factory=dict)
    flow: dict = field(default_factory=dict)

    def cfg(self, mesh: str) -> str:
        return config(self.markers, self.setup, self.flow, mesh, self.iterations, self.cfl, self.scheme)


def solve_section(section: dict, wings: list[dict], setup: dict, flow: dict, preset: str, workdir: Path,
                  su2_hint: str | None, cores: int, progress, iterations: int = 6000) -> dict:
    """One strip: mesh, solve, and the forces per metre of width (lift up +,
    drag along the flow), where the lift acts (car x, mm) and each wing's share."""
    workdir.mkdir(parents=True, exist_ok=True)
    mesh_file = workdir / "car.su2"
    stats = car_mesh.build(section, wings, {**setup, "speed": flow.get("speed", setup.get("speed", 15.0))}, preset, mesh_file)
    speed = float(flow.get("speed", setup.get("speed", 15.0)))
    case = CarCase(speed=speed, rho=RHO, mu=MU, alpha_deg=0.0, ref_chord=1.0, ref_point=(0.0, 0.0),
                   walls=_walls(stats["markers"]), model="sst", iterations=iterations, cfl=10.0, multigrid=0, scheme="fds",
                   markers=stats["markers"], setup=setup, flow=flow)
    out = su2.run(case, mesh_file, workdir, su2.find_su2(su2_hint), cores, progress)
    q = 0.5 * RHO * speed * speed
    lift, drag = out["cl"] * q, out["cd"] * q
    # The moment origin is on the ground line, so moment over lift is the point where the lift alone
    # would load the axles as the lift and the drag (acting above the ground) do: the axle split needs that.
    x_cp = -1000.0 * (out["cm"] / out["cl"]) if out.get("cm") is not None and abs(out["cl"]) > 1e-9 else None
    wing_lift, wing_drag, wing_x = {}, {}, {}
    for row in out["elements"]:
        if row["marker"].startswith("wing_") and row["cl"] is not None:
            pos = row["marker"][5:]
            wing_lift[pos] = row["cl"] * q
            wing_drag[pos] = (row["cd"] or 0.0) * q
            if row.get("cmz") is not None and abs(row["cl"]) > 1e-9:
                wing_x[pos] = -1000.0 * row["cmz"] / row["cl"]
    return {"y": float(section["y"]), "lift": float(lift), "drag": float(drag), "x_cp": x_cp, "wing_x_cp": wing_x,
            "converged": bool(out["converged"]), "reason": out.get("reason"), "iterations": out["iterations"],
            "wing_lift": wing_lift, "wing_drag": wing_drag, "cells": stats["cells"]}
