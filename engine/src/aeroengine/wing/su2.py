"""SU2 incompressible RANS runs on a wing mesh.

Turbulence models: Spalart-Allmaras (default, robust for attached and mildly
separated flow), SST (better near separation), or SST with the
Langtry-Menter transition model (laminar runs and separation bubbles, at
the Reynolds numbers of FS wings). A run counts as converged only if the
residuals have dropped by a set amount and lift and drag have stopped
changing over a window; anything else is reported as not converged, never
as a result.
"""

from __future__ import annotations

import csv
import os
import shutil
import subprocess
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Callable

import numpy as np

from ..job import EngineError

MODELS = {"sa": "Spalart-Allmaras", "sst": "SST", "sst-lm": "SST with Langtry-Menter transition"}
# Convective schemes. JST (central, light fourth-order dissipation) is the
# default: SU2's incompressible upwind FDS doubled NACA 0012's pressure drag
# at 10 degrees on meshes of a few tens of thousands of cells (and on NASA's
# own 225 x 65 grid). FDS stays as the fallback when JST will not run.
SCHEMES = {"jst": "JST central", "fds": "FDS upwind (more dissipative: drag reads high)"}
JST_DISSIPATION = (0.5, 0.005)  # second and fourth order coefficients


@dataclass
class Case:
    speed: float
    rho: float
    mu: float
    alpha_deg: float
    ref_chord: float
    ref_point: tuple[float, float]
    walls: list[str]
    model: str = "sa"
    turbulence_intensity: float = 0.01  # for SST and transition, fraction
    iterations: int = 4000
    residual_drop: float = 4.0  # orders of magnitude, on the pressure residual
    window: int = 200  # iterations over which Cl and Cd must hold still
    tolerance: float = 1e-4  # their relative change over the window
    # Fixed CFL with multigrid: on NACA 0012 an adaptive CFL diverged and
    # CFL 50 diverged at once; CFL 25 on two multigrid levels took the
    # residual down 8 orders in about 1,000 iterations.
    cfl: float = 25.0
    multigrid: int = 2
    scheme: str = "jst"
    restart: str | None = None  # a solution to start from (restart.dat of a run on the same mesh)


def find_su2(hint: str | None = None) -> Path:
    """SU2_CFD from a setting (the binary or its folder), $AEROBENCH_SU2, or PATH."""
    for raw in (hint, os.environ.get("AEROBENCH_SU2")):
        if raw:
            p = Path(raw).expanduser()
            if p.is_dir():
                p = p / "SU2_CFD"
            if p.is_file() and os.access(p, os.X_OK):
                return p
    found = shutil.which("SU2_CFD")
    if found:
        return Path(found)
    built = Path(__file__).resolve().parents[4] / "build" / "su2" / "bin" / "SU2_CFD"  # engine/scripts/install_su2.sh
    if built.is_file() and os.access(built, os.X_OK):
        return built
    raise EngineError("SU2 is not installed", "install it from Wing Lab (or engine/scripts/install_su2.sh), or set its folder in Settings")


def config(case: Case, mesh: str) -> str:
    if case.model not in MODELS:
        raise EngineError(f"unknown turbulence model '{case.model}'", f"expected one of {', '.join(MODELS)}")
    al = np.radians(case.alpha_deg)
    walls = ", ".join(case.walls)
    heatflux = ", ".join(f"{w}, 0.0" for w in case.walls)
    turb = {
        "sa": "KIND_TURB_MODEL= SA\nFREESTREAM_NU_FACTOR= 3.0",
        "sst": f"KIND_TURB_MODEL= SST\nFREESTREAM_TURBULENCEINTENSITY= {case.turbulence_intensity}\nFREESTREAM_TURB2LAMVISCRATIO= 10.0",
        "sst-lm": (f"KIND_TURB_MODEL= SST\nKIND_TRANS_MODEL= LM\nFREESTREAM_TURBULENCEINTENSITY= {case.turbulence_intensity}\n"
                   "FREESTREAM_TURB2LAMVISCRATIO= 10.0"),
    }[case.model]
    if case.scheme not in SCHEMES:
        raise EngineError(f"unknown scheme '{case.scheme}'", f"expected one of {', '.join(SCHEMES)}")
    restart = (f"RESTART_SOL= YES\nSOLUTION_FILENAME= {case.restart}\nRESTART_ITER= 1" if case.restart
               else "RESTART_SOL= NO")
    flow_scheme = {
        "jst": f"CONV_NUM_METHOD_FLOW= JST\nMUSCL_FLOW= NO\nJST_SENSOR_COEFF= ( {JST_DISSIPATION[0]}, {JST_DISSIPATION[1]} )",
        "fds": "CONV_NUM_METHOD_FLOW= FDS\nMUSCL_FLOW= YES\nSLOPE_LIMITER_FLOW= NONE",
    }[case.scheme]
    return f"""% AeroBench Wing Lab: 2D incompressible RANS
SOLVER= INC_RANS
{turb}
MATH_PROBLEM= DIRECT
{restart}
INC_DENSITY_MODEL= CONSTANT
INC_ENERGY_EQUATION= NO
INC_NONDIM= INITIAL_VALUES
INC_DENSITY_INIT= {case.rho}
INC_VELOCITY_INIT= ( {case.speed * np.cos(al)}, {case.speed * np.sin(al)}, 0.0 )
VISCOSITY_MODEL= CONSTANT_VISCOSITY
MU_CONSTANT= {case.mu}
REF_ORIGIN_MOMENT_X= {case.ref_point[0]}
REF_ORIGIN_MOMENT_Y= {case.ref_point[1]}
REF_ORIGIN_MOMENT_Z= 0.0
REF_LENGTH= {case.ref_chord}
REF_AREA= {case.ref_chord}
MARKER_HEATFLUX= ( {heatflux} )
MARKER_FAR= ( farfield )
MARKER_PLOTTING= ( {walls} )
MARKER_MONITORING= ( {walls} )
NUM_METHOD_GRAD= GREEN_GAUSS
CFL_NUMBER= {case.cfl}
CFL_ADAPT= NO
MGLEVEL= {case.multigrid}
MGCYCLE= V_CYCLE
MG_PRE_SMOOTH= ( 1, 2, 3 )
MG_POST_SMOOTH= ( 0, 0, 0 )
MG_CORRECTION_SMOOTH= ( 0, 0, 0 )
MG_DAMP_RESTRICTION= 0.75
MG_DAMP_PROLONGATION= 0.75
LINEAR_SOLVER= FGMRES
LINEAR_SOLVER_PREC= ILU
LINEAR_SOLVER_ERROR= 1E-6
LINEAR_SOLVER_ITER= 15
{flow_scheme}
TIME_DISCRE_FLOW= EULER_IMPLICIT
CONV_NUM_METHOD_TURB= SCALAR_UPWIND
MUSCL_TURB= NO
TIME_DISCRE_TURB= EULER_IMPLICIT
ITER= {case.iterations}
CONV_FIELD= RMS_PRESSURE
CONV_RESIDUAL_MINVAL= -12
CONV_STARTITER= 10
MESH_FILENAME= {mesh}
MESH_FORMAT= SU2
SCREEN_OUTPUT= ( INNER_ITER, RMS_PRESSURE, LIFT, DRAG )
HISTORY_OUTPUT= ( ITER, RMS_RES, AERO_COEFF, AERO_COEFF_SURF )
CONV_FILENAME= history
OUTPUT_FILES= ( RESTART, PARAVIEW, SURFACE_CSV )
VOLUME_OUTPUT= ( COORDINATES, SOLUTION, PRIMITIVE )  % Cp and y+ in flow.vtu
OUTPUT_WRT_FREQ= {min(case.iterations, WRITE_EVERY)}
VOLUME_FILENAME= flow
SURFACE_FILENAME= surface
RESTART_FILENAME= restart.dat
"""


def read_history(path: Path) -> dict[str, np.ndarray]:
    with open(path, newline="") as f:
        rows = list(csv.reader(f))
    if len(rows) < 2:
        raise EngineError("SU2 wrote no iterations")
    names = [h.strip().strip('"') for h in rows[0]]
    data = np.array([[float(v) for v in r] for r in rows[1:] if len(r) == len(names)])
    return {n: data[:, k] for k, n in enumerate(names)}


def judge(history: dict[str, np.ndarray], case: Case) -> dict:
    """Converged means the pressure residual dropped by `residual_drop`
    orders and Cl, Cd moved less than `tolerance` (relative) over the last
    `window` iterations."""
    res_key = next((k for k in history if k.lower() in ("rms[p]", "rms_pressure")), None)
    cl, cd = history.get("CL"), history.get("CD")
    if res_key is None or cl is None or cd is None:
        raise EngineError("the SU2 history has no pressure residual, CL or CD column", ", ".join(history))
    res = history[res_key]
    drop = float(res[: min(5, len(res))].max() - res[-1])
    n = len(cl)
    if n < case.window:
        return {"converged": False, "residual_drop": drop, "cl_change": None, "cd_change": None,
                "reason": f"only {n} iterations, fewer than the {case.window}-iteration window"}
    w = slice(n - case.window, n)

    def change(v, floor):
        # Relative to the value, but not below a floor: at zero lift a
        # relative change means nothing.
        span = float(np.ptp(v[w]))
        return span / max(abs(float(v[-1])), floor)

    dcl, dcd = change(cl, 0.1), change(cd, 0.01)
    ok = drop >= case.residual_drop and dcl <= case.tolerance and dcd <= case.tolerance
    reason = None
    if not ok:
        parts = []
        if drop < case.residual_drop:
            parts.append(f"residual fell {drop:.1f} orders, needs {case.residual_drop:.1f}")
        if dcl > case.tolerance:
            parts.append(f"Cl still moving ({dcl:.1e} over the last {case.window} iterations)")
        if dcd > case.tolerance:
            parts.append(f"Cd still moving ({dcd:.1e})")
        reason = "; ".join(parts)
    return {"converged": bool(ok), "residual_drop": drop, "cl_change": dcl, "cd_change": dcd, "reason": reason}


# SU2 runs on towards a residual of 1e-12 long after lift and drag have
# settled (on NACA 0012 at 10 degrees they held still from iteration 2,262
# of 3,790). The engine watches the run and stops it once the convergence
# test passes, at half the tolerance to leave a margin; the flow and surface
# files are written every WRITE_EVERY iterations, so they are at most that
# many iterations older than the forces.
WRITE_EVERY = 100
STOP_AFTER_WRITE = 20  # iterations after a write before stopping, so the files are complete

CFL_STEPS = (25.0, 10.0, 4.0)  # tried in turn when SU2 diverges
FALLBACK = ("fds", 10.0)  # last resort: the more dissipative scheme, flagged in the result


def run(case: Case, mesh: Path, workdir: Path, su2: Path, cores: int = 1,
        progress: Callable[[float, str], None] | None = None, env: dict | None = None) -> dict:
    """Runs SU2 at the case's CFL, and if it diverges, again at each lower
    CFL in CFL_STEPS, then once with the upwind scheme: what an engineer
    would do by hand. Every attempt is judged the same way; the result says
    which CFL and scheme it took."""
    from dataclasses import replace

    attempts = []
    plan = [(case.scheme, c) for c in [case.cfl] + [c for c in CFL_STEPS if c < case.cfl]]
    if case.scheme != FALLBACK[0]:
        plan.append(FALLBACK)
    for scheme, cfl in plan:
        try:
            out = _start(replace(case, cfl=cfl, scheme=scheme), mesh, workdir, su2, cores, progress, env)
            out["cfl"] = cfl
            out["scheme"] = scheme
            out["attempts"] = attempts + [{"cfl": cfl, "scheme": scheme, "outcome": "finished"}]
            return out
        except Diverged as exc:
            attempts.append({"cfl": cfl, "scheme": scheme, "outcome": f"diverged at iteration {exc.iteration}"})
            if progress:
                progress(10, f"diverged ({SCHEMES[scheme]}, CFL {cfl:g}); trying again more cautiously")
    raise EngineError("SU2 diverged at every CFL tried",
                      "; ".join(f"{a['scheme'].upper()} CFL {a['cfl']:g}: {a['outcome']}" for a in attempts)
                      + ". Check the mesh: a finer level, or a wider slot.")


RESTART_COPY = "start.dat"  # the solution a restarted run begins from, copied into its folder


def _start(case: Case, mesh: Path, workdir: Path, su2: Path, cores: int,
           progress: Callable[[float, str], None] | None, env: dict | None) -> dict:
    """One attempt, started again more cautiously if Open MPI crashes while
    SU2 is still setting up. On some of GitHub's Linux runners Open MPI
    segfaults choosing a one-sided component for MPI_Win_create, before a
    single iteration, every time on that machine. So the second start names
    the component (rdma) instead of letting Open MPI choose, and the third
    runs SU2 as one process without mpirun. Nothing is lost by trying again;
    where the first start works (as it does on a Mac) nothing changes."""
    base = dict(env or os.environ)
    ladder = [(cores, base), (cores, {**base, "OMPI_MCA_osc": "rdma"}), (1, {**base, "OMPI_MCA_osc": "rdma"})]
    for k, (n, e) in enumerate(ladder):
        try:
            return _run_once(case, mesh, workdir, su2, n, progress, e)
        except StartupCrash as exc:
            if k == len(ladder) - 1:
                raise EngineError("SU2 crashed while starting, every time", exc.detail) from None
            if progress:
                progress(10, "SU2 crashed while starting; starting it again"
                         + (" on one core" if ladder[k + 1][0] == 1 and n > 1 else ""))
    raise AssertionError("unreachable")


class StartupCrash(Exception):
    def __init__(self, detail: str) -> None:
        super().__init__("SU2 crashed while starting")
        self.detail = detail


class Diverged(Exception):
    def __init__(self, iteration: int) -> None:
        super().__init__(f"diverged at {iteration}")
        self.iteration = iteration


def _run_once(case: Case, mesh: Path, workdir: Path, su2: Path, cores: int,
              progress: Callable[[float, str], None] | None, env: dict | None) -> dict:
    report = progress or (lambda pct, msg: None)
    for stale in ("history.csv", "surface.csv", "flow.vtu", "restart.dat"):
        (workdir / stale).unlink(missing_ok=True)
    if case.restart and Path(case.restart).name != RESTART_COPY:
        # SU2 keeps the solution file's name in a fixed-size buffer and
        # aborts ("buffer overflow detected") on a long path: copy it here
        # under a short name.
        shutil.copyfile(case.restart, workdir / RESTART_COPY)
        case = replace(case, restart=RESTART_COPY)
    rel = mesh.resolve().relative_to(workdir.resolve()) if mesh.resolve().is_relative_to(workdir.resolve()) else mesh.resolve()
    (workdir / "su2.cfg").write_text(config(case, str(rel)))
    cmd = [str(su2), "su2.cfg"]
    mpirun = shutil.which("mpirun", path=str(su2.parent)) or shutil.which("mpirun")
    if cores > 1 and mpirun:
        cmd = [mpirun, "-n", str(cores)] + (["--allow-run-as-root"] if hasattr(os, "geteuid") and os.geteuid() == 0 else []) + cmd
        # One machine: keep Open MPI off the cluster network transports.
        # SU2 segfaulted on GitHub's Linux runners while Open MPI chose the
        # one-sided component for MPI_Win_create: first in UCX's, then
        # (intermittently) in rdma's, which probes the UCX-based uct
        # transport. Shared memory and TCP are all one machine needs.
        env = dict(env or os.environ)
        env.setdefault("OMPI_MCA_osc", "^ucx")
        env.setdefault("OMPI_MCA_pml", "^ucx")
        env.setdefault("OMPI_MCA_btl", "^uct,ofi,usnic")
    log = open(workdir / "su2.log", "w")
    proc = subprocess.Popen(cmd, cwd=workdir, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            env=env, errors="replace")
    tail: list[str] = []
    screen: dict[str, list[float]] = {"rms[P]": [], "CL": [], "CD": []}
    strict = replace(case, tolerance=case.tolerance / 2)
    stopped = False
    try:
        for line in proc.stdout:  # type: ignore[union-attr]
            log.write(line)
            tail = (tail + [line.rstrip()])[-40:]
            parts = line.split("|")
            if len(parts) > 4:
                try:
                    it = int(parts[1].strip())
                    vals = [float(parts[k]) for k in (2, 3, 4)]
                except ValueError:
                    continue
                report(10 + 85 * min(it / case.iterations, 1), f"iteration {it}")
                for key, v in zip(screen, vals):
                    screen[key].append(v)
                if it % WRITE_EVERY == STOP_AFTER_WRITE and len(screen["CL"]) > case.window:
                    if judge({k: np.array(v) for k, v in screen.items()}, strict)["converged"]:
                        stopped = True
                        report(95, f"converged at iteration {it}")
                        proc.terminate()
                        break
        proc.wait()
    finally:
        log.close()
        if proc.poll() is None:
            proc.kill()
    history_file = workdir / "history.csv"
    if not stopped and proc.returncode != 0 and any("has diverged" in line for line in tail):
        last = 0
        for line in tail:
            parts = line.split("|")
            if len(parts) > 3 and parts[1].strip().isdigit():
                last = int(parts[1])
        raise Diverged(last)
    if proc.returncode != 0 and not stopped and not screen["CL"] and any(
            k in line for line in tail for k in ("MPI_Win_create", "ompi_osc", "MPI_Init")):
        raise StartupCrash("\n".join(tail[-12:]))
    if (proc.returncode != 0 and not stopped) or not history_file.exists():
        raise EngineError(f"SU2 stopped with exit code {proc.returncode}", "\n".join(tail[-12:]))
    hist = read_history(history_file)
    verdict = judge(hist, case)
    out = {"iterations": int(len(hist["CL"])), "model": case.model, **verdict, "stopped_early": stopped,
           "cl": float(hist["CL"][-1]), "cd": float(hist["CD"][-1]),
           "cm": float(hist["CMz"][-1]) if "CMz" in hist else None, "elements": []}
    for wall in case.walls:
        row = {"marker": wall}
        for key in ("CL", "CD", "CMz"):
            col = next((k for k in hist if k.replace("(", "_").replace(")", "").replace(" ", "") == f"{key}_{wall}"), None)
            row[key.lower()] = float(hist[col][-1]) if col else None
        out["elements"].append(row)
    out["history_columns"] = list(hist)
    return out
