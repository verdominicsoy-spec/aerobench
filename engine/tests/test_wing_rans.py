"""Meshing and SU2 runs. The SU2 tests are skipped where SU2 is not installed."""

from __future__ import annotations

import time

import json
import os
import shutil
from dataclasses import replace
from pathlib import Path
import subprocess

import numpy as np
import pytest

from aeroengine.job import EngineError
from aeroengine.wing.airfoils import naca4
from aeroengine.wing.mesh import Settings, boundary_layer_thickness, build, first_cell_height, layers_for
from aeroengine.wing.su2 import Case, config, judge, settled


def _place(c, chord, angle, at):
    a = -np.radians(angle)
    rot = np.array([[np.cos(a), -np.sin(a)], [np.sin(a), np.cos(a)]])
    return (c * chord) @ rot.T + at


def _two():
    return [_place(naca4("4412"), 1.0, 0, (0, 0)), _place(naca4("4412"), 0.35, 20, (0.97, -0.05))]


def test_wall_layer_sizes():
    # y+ = 1 at Re 6e6 on a 1 m chord is a few microns; the layers hold a
    # ~2 cm turbulent boundary layer.
    h = first_cell_height(6e6, 1.0)
    assert 3e-6 < h < 8e-6
    assert boundary_layer_thickness(6e6, 1.0) == pytest.approx(0.37 * 6e6**-0.2)
    n = layers_for(h, 1.15, 0.02)
    assert h * (1.15**n - 1) / 0.15 >= 0.02 > h * (1.15 ** (n - 1) - 1) / 0.15


def _su2_cells(path):
    lines = path.read_text().splitlines()
    n = int(lines[1].split("=")[1])
    return [list(map(int, l.split()[1:-1])) for l in lines[2:2 + n]], lines


def test_mesh_has_markers_layers_and_no_degenerate_cells(tmp_path):
    out = build(_two(), Settings(re=1e6, ref_chord=1.35, transition=[(0.3, 0.6), (0.1, 0.4)]), tmp_path / "w.su2")
    assert out["quads"] > 0 and out["triangles"] > 0 and out["bad_cells"] == 0
    cells, lines = _su2_cells(tmp_path / "w.su2")
    assert all(len(set(c)) == len(c) for c in cells)
    markers = [l.split("=")[1].strip() for l in lines if l.startswith("MARKER_TAG")]
    assert markers == ["wall_0", "wall_1", "farfield"]
    # Slot: the layers are capped below half the gap, so they cannot collide.
    assert out["layer_thickness_m"] <= 0.4 * out["min_gap_m"] + 1e-12


def test_laminar_zones_get_finer_surfaces(tmp_path):
    turbulent = build(_two()[:1], Settings(re=1e6, ref_chord=1.0, transition=[(0.0, 0.0)]), tmp_path / "t.su2")
    laminar = build(_two()[:1], Settings(re=1e6, ref_chord=1.0, transition=[(0.6, 0.6)]), tmp_path / "l.su2")
    assert laminar["surface_nodes"][0] > 1.4 * turbulent["surface_nodes"][0]


def test_rejects_a_slot_too_narrow_and_too_fast_growth(tmp_path):
    els = _two()
    els[1] = els[1] + (0, 0.04)  # 0.5 mm from the main element's trailing edge
    with pytest.raises(EngineError, match="too narrow"):
        build(els, Settings(re=1e6, ref_chord=1.35), tmp_path / "x.su2")
    with pytest.raises(EngineError, match="growth"):
        build(_two(), Settings(re=1e6, ref_chord=1.35, growth=1.3), tmp_path / "y.su2")


def _history(n, cl_end, cd_end, wobble, res_drop):
    it = np.arange(n)
    return {"rms[P]": -3 - res_drop * it / (n - 1), "CL": cl_end + wobble * np.sin(it), "CD": cd_end + 0 * it}


def test_convergence_is_judged_not_assumed():
    case = Case(speed=10, rho=1.2, mu=1.8e-5, alpha_deg=0, ref_chord=1, ref_point=(0.25, 0), walls=["wall_0"])
    assert judge(_history(1000, 1.2, 0.01, 1e-6, 5), case)["converged"]
    bad = judge(_history(1000, 1.2, 0.01, 1e-2, 5), case)
    assert not bad["converged"] and "Cl still moving" in bad["reason"]
    assert "residual fell" in judge(_history(1000, 1.2, 0.01, 0, 2), case)["reason"]
    # At zero lift, a tiny absolute wobble is still converged.
    assert judge(_history(1000, 0.0, 0.009, 1e-6, 5), case)["converged"]
    assert not judge(_history(100, 1.2, 0.01, 0, 5), case)["converged"]


def test_config_per_model():
    case = Case(speed=20, rho=1.2, mu=1.8e-5, alpha_deg=5, ref_chord=0.4, ref_point=(0.1, 0), walls=["wall_0", "wall_1"], model="sa")
    sa = config(case, "m.su2")
    assert "KIND_TURB_MODEL= SA" in sa and "MARKER_HEATFLUX= ( wall_0, 0.0, wall_1, 0.0 )" in sa
    assert f"INC_VELOCITY_INIT= ( {20 * np.cos(np.radians(5))}" in sa
    case.model = "sst-lm"
    lm = config(case, "m.su2")
    assert "KIND_TURB_MODEL= SST" in lm and "KIND_TRANS_MODEL= LM" in lm
    case.model = "kw"
    with pytest.raises(EngineError):
        config(case, "m.su2")


def test_config_schemes():
    case = Case(speed=20, rho=1.2, mu=1.8e-5, alpha_deg=5, ref_chord=0.4, ref_point=(0.1, 0), walls=["wall_0"])
    jst = config(case, "m.su2")  # the default: central, and SU2 refuses MUSCL with it
    assert "CONV_NUM_METHOD_FLOW= JST" in jst and "MUSCL_FLOW= NO" in jst and "JST_SENSOR_COEFF= ( 0.5, 0.005 )" in jst
    case.scheme = "fds"
    fds = config(case, "m.su2")
    assert "CONV_NUM_METHOD_FLOW= FDS" in fds and "MUSCL_FLOW= YES" in fds and "JST" not in fds
    case.scheme = "roe"
    with pytest.raises(EngineError):
        config(case, "m.su2")


def test_divergence_ladder_ends_with_the_upwind_scheme(monkeypatch, tmp_path):
    from aeroengine.wing import su2 as m

    tried = []

    def fake(case, *a, **k):
        tried.append((case.scheme, case.cfl))
        if case.scheme == "jst":
            raise m.Diverged(42)
        return {"converged": True}

    monkeypatch.setattr(m, "_run_once", fake)
    case = Case(speed=20, rho=1.2, mu=1.8e-5, alpha_deg=5, ref_chord=0.4, ref_point=(0.1, 0), walls=["wall_0"])
    out = m.run(case, tmp_path / "m.su2", tmp_path, tmp_path / "SU2_CFD")
    assert tried == [("jst", 25.0), ("jst", 10.0), ("jst", 4.0), ("fds", 10.0)]
    assert out["scheme"] == "fds" and len(out["attempts"]) == 4


su2 = pytest.mark.skipif(shutil.which("SU2_CFD") is None and not os.environ.get("AEROBENCH_SU2"),
                         reason="SU2 is not installed here")


@su2
def test_wing_rans_end_to_end(tmp_path):
    """A coarse two-element run through the command: it meshes, runs, and
    reports per-element coefficients, surface Cp and its convergence."""
    els = _two()
    unit = naca4("4412").tolist()
    job = {"command": "wing-rans", "options": {"cores": 2}, "params": {
        "elements": [{"coords": e.tolist(), "unit": unit, "angle": a, "inverted": False, "chord": c}
                     for e, a, c in zip(els, (0, 20), (1.0, 0.35))],
        "speed": 15.0, "alpha": 2.0, "model": "sa", "mesh": "medium", "iterations": 1500, "transition": "auto"}}
    (tmp_path / "job.json").write_text(json.dumps(job))
    proc = subprocess.run(["aeroengine", "wing-rans", "--input", str(tmp_path / "job.json"), "--workdir", str(tmp_path / "w")],
                          capture_output=True, text=True)
    assert proc.returncode == 0, proc.stdout[-2000:] + proc.stderr[-2000:]
    data = json.loads((tmp_path / "w" / "result.json").read_text())["data"]
    assert len(data["elements"]) == 2 and all(e["cl"] is not None for e in data["elements"])
    assert sum(e["cl"] for e in data["elements"]) == pytest.approx(data["cl"], rel=1e-6)
    assert data["cl"] > 1.0  # a deflected flap, upright: plenty of lift
    assert len(data["surface"]) == 2 and len(data["surface"][1]["cp"]) > 50
    # The flow field for the app, sampled from this run.
    assert data["field_view"] == "field.json"
    head = json.loads((tmp_path / "w" / "field.json").read_text())
    assert [s["key"] for s in head["scalars"]][:3] == ["cp", "speed", "cp0"] and head["streamlines"]
    assert (tmp_path / "w" / "field.bin").stat().st_size == 4 * head["nx"] * head["ny"] * len(head["scalars"])
    assert 0 < data["transition"][0][0] < 1  # predicted, not left at the default
    assert not (tmp_path / "w" / "mesh").exists()  # the mesh is not kept unless asked


def test_convex_corners_get_fans():
    from aeroengine.wing.mesh import _convex_corners

    # A counter-clockwise L: five convex corners, one concave (index 3) that needs none.
    ell = np.array([[0, 0], [2, 0], [2, 1], [1, 1], [1, 2], [0, 2]], float)
    assert _convex_corners(ell, closed=True) == [0, 1, 2, 4, 5]
    # A smooth section has none away from its trailing edge.
    sec = naca4("4412")
    assert all(k in (0, len(sec) - 1) for k in _convex_corners(sec, closed=False))


def test_run_stops_once_converged(tmp_path):
    """A stand-in SU2 that would run for 100,000 iterations: lift and drag
    settle and the residual falls, so the engine stops it at the first
    check after a file write."""
    import stat
    import sys

    from aeroengine.wing import su2 as m

    fake = tmp_path / "SU2_CFD"
    fake.write_text(f"""#!{sys.executable}
import math, sys, time
with open("history.csv", "w") as h:
    h.write('"Inner_Iter","rms[P]","CL","CD"\\n')
    for it in range(100000):
        rms, cl, cd = -2 - it / 50, 1.2 + 0.3 * math.exp(-it / 5), 0.02 + 0.01 * math.exp(-it / 5)
        h.write(f"{{it}},{{rms}},{{cl}},{{cd}}\\n"); h.flush()
        print(f"|{{it:>12}}|{{rms:>12.6f}}|{{cl:>12.6f}}|{{cd:>12.6f}}|", flush=True)
        if it % 50 == 0:
            time.sleep(0.01)
""")
    fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
    case = Case(speed=20, rho=1.2, mu=1.8e-5, alpha_deg=5, ref_chord=0.4, ref_point=(0.1, 0), walls=[],
                iterations=100000)
    out = m.run(case, tmp_path / "m.su2", tmp_path, fake, cores=1)
    assert out["converged"] and out["stopped_early"]
    # Stopped within a couple of checks of the window filling, not at 100,000 (plus lines in flight).
    assert out["iterations"] < case.window + 2 * m.WRITE_EVERY + m.STOP_AFTER_WRITE + 50
    assert out["cl"] == pytest.approx(1.2, abs=1e-6)


def test_a_crash_while_starting_is_retried(tmp_path):
    """Open MPI sometimes segfaults setting up, before any iteration: the
    run starts SU2 again rather than failing."""
    import stat
    import sys

    from aeroengine.wing import su2 as m

    fake = tmp_path / "SU2_CFD"
    fake.write_text(f"""#!{sys.executable}
import math, os, sys
flag = "started_once"
if not os.path.exists(flag):
    open(flag, "w").close()
    print("[runner:01] [ 3] libmpi.so.40(ompi_osc_base_select+0x11a)", flush=True)
    print("[runner:01] [ 5] libmpi.so.40(MPI_Win_create+0xd3)", flush=True)
    sys.exit(139)
with open("history.csv", "w") as h:
    h.write('"Inner_Iter","rms[P]","CL","CD"\\n')
    for it in range(400):
        rms, cl, cd = -2 - it / 50, 1.2 + 0.3 * math.exp(-it / 5), 0.02 + 0.01 * math.exp(-it / 5)
        h.write(f"{{it}},{{rms}},{{cl}},{{cd}}\\n"); h.flush()
        print(f"|{{it:>12}}|{{rms:>12.6f}}|{{cl:>12.6f}}|{{cd:>12.6f}}|", flush=True)
""")
    fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
    case = Case(speed=20, rho=1.2, mu=1.8e-5, alpha_deg=5, ref_chord=0.4, ref_point=(0.1, 0), walls=[], iterations=400)
    out = m.run(case, tmp_path / "m.su2", tmp_path, fake, cores=1)
    assert (tmp_path / "started_once").exists(), out
    assert out["converged"], out


def test_sweep_chains_restarts_and_keeps_to_its_time_limit(monkeypatch, tmp_path):
    from aeroengine.wing import rans

    calls = []
    clock = {"t": 0.0}
    monkeypatch.setattr("time.time", lambda: clock["t"])

    def fake_solve(p, workdir, mesh_file, su2_hint, cores, env, progress, log, field=True, mesh_ready=None, restart=None):
        calls.append({"alpha": p["alpha"], "wake": p["wake_alpha"], "ready": mesh_ready is not None,
                      "restart": restart.parent.name if restart else None, "iterations": p["iterations"]})
        if p["alpha"] == 4.0 and restart is not None:
            raise EngineError("SU2 diverged at every CFL tried")
        seconds = 180.0 if mesh_ready is None else (60.0 if restart is None else 30.0)
        clock["t"] += seconds
        (workdir / "restart.dat").write_text("x")
        return {"alpha": p["alpha"], "cl": p["alpha"] / 10, "cd": 0.01, "converged": True, "iterations": 1800 if mesh_ready is None else (600 if restart is None else 300),
                "mesh": {"cells": 1}, "transition": [[0.0, 0.0]]}

    monkeypatch.setattr(rans, "solve", fake_solve)
    out = rans.sweep({"alphas": [4, 0, 2, -2, -4], "time_limit": 300}, tmp_path, tmp_path / "m.su2", None, 1, None,
                     lambda *a: None, lambda *a, **k: None)
    # The middle angle first, from rest; then alternately above and below, each from its neighbour.
    assert [(c["alpha"], c["restart"]) for c in calls] == [
        (0.0, None), (2.0, "a0"), (-2.0, "a0"), (4.0, "a2"), (4.0, None)]
    assert calls[0]["ready"] is False and all(c["ready"] for c in calls[1:]) and all(c["wake"] == 0.0 for c in calls)
    # 180 (0) + 30 (2) + 30 (-2) + 60 (4, from rest after the restart failed) = 300 s: no time for -4.
    assert [r["alpha"] for r in out["rows"]] == [-2.0, 0.0, 2.0, 4.0] and out["skipped"] == [-4.0]
    # Iterations are capped by the time left at the slowest rate seen (0.1 s each).
    assert calls[1]["iterations"] == 1200 and calls[4]["iterations"] == 600


def test_a_restart_is_copied_in_under_a_short_name(monkeypatch, tmp_path):
    """SU2 aborts on a long solution path, so the engine copies the solution
    into the run folder and names it there."""
    from aeroengine.wing import su2 as m

    deep = tmp_path / ("a" * 60) / ("b" * 60)
    deep.mkdir(parents=True)
    (deep / "restart.dat").write_text("solution")
    seen = {}

    class Done(Exception):
        pass

    def stop_at_popen(cmd, cwd, **kw):
        seen["cfg"] = (Path(cwd) / "su2.cfg").read_text()
        raise Done

    monkeypatch.setattr(m.subprocess, "Popen", stop_at_popen)
    case = Case(speed=20, rho=1.2, mu=1.8e-5, alpha_deg=5, ref_chord=0.4, ref_point=(0.1, 0), walls=[],
                restart=str(deep / "restart.dat"))
    work = tmp_path / "w"
    work.mkdir()
    with pytest.raises(Done):
        m._run_once(case, work / "m.su2", work, tmp_path / "SU2_CFD", 1, None, None)
    assert "SOLUTION_FILENAME= start.dat" in seen["cfg"] and "RESTART_SOL= YES" in seen["cfg"]
    assert (work / "start.dat").read_text() == "solution"


def test_startup_crashes_escalate_to_a_named_component_then_one_core(monkeypatch, tmp_path):
    from aeroengine.wing import su2 as m

    tried = []

    def crash(case, mesh, workdir, su2, cores, progress, env):
        tried.append((cores, env.get("OMPI_MCA_osc")))
        if len(tried) < 3:
            raise m.StartupCrash("ompi_osc_base_select")
        return {"converged": True}

    monkeypatch.setattr(m, "_run_once", crash)
    monkeypatch.delenv("OMPI_MCA_osc", raising=False)
    case = Case(speed=20, rho=1.2, mu=1.8e-5, alpha_deg=5, ref_chord=0.4, ref_point=(0.1, 0), walls=[])
    assert m._start(case, tmp_path / "m.su2", tmp_path, tmp_path / "SU2_CFD", 4, None, None)["converged"]
    assert tried == [(4, None), (4, "rdma"), (1, "rdma")]


def test_a_rising_sweep_climbs_without_a_time_limit(monkeypatch, tmp_path):
    from aeroengine.wing import rans

    calls = []

    def fake_solve(p, workdir, mesh_file, su2_hint, cores, env, progress, log, field=True, mesh_ready=None, restart=None):
        calls.append((p["alpha"], restart.parent.name if restart else None))
        (workdir / "restart.dat").write_text("x")
        time.sleep(0.06)  # a real run takes time (rounded to 0.1 s), so the sweep works out a time per iteration
        return {"alpha": p["alpha"], "cl": 1.0, "cd": 0.01, "converged": True, "iterations": 100,
                "mesh": {"cells": 1}, "transition": [[0.0, 0.0]]}

    monkeypatch.setattr(rans, "solve", fake_solve)
    out = rans.sweep({"alphas": [8, 0, 4, 12, 16], "order": "rising", "time_limit": 0}, tmp_path, tmp_path / "m.su2",
                     None, 1, None, lambda *a: None, lambda *a, **k: None)
    assert calls == [(0.0, None), (4.0, "a0"), (8.0, "a4"), (12.0, "a8"), (16.0, "a12")]
    assert out["skipped"] == [] and out["time_limit"] == 0.0
    # Inverted, a bigger wing angle unloads the wing: it climbs from the top down.
    calls.clear()
    rans.sweep({"alphas": [0, -4, -8], "order": "rising", "time_limit": 0, "elements": [{"inverted": True}]}, tmp_path / "inv",
               tmp_path / "m.su2", None, 1, None, lambda *a: None, lambda *a, **k: None)
    assert calls == [(0.0, None), (-4.0, "a0"), (-8.0, "a-4")]


def test_reversed_flow_reaching_the_trailing_edge_is_separation_a_bubble_is_not():
    from aeroengine.wing.rans import SEPARATED_SHARE, separation

    s = np.linspace(0.0, 1.0, 200)

    def element(cf_upper, cf_lower):  # (distance along the chord / chord, skin friction along the flow, surface)
        return np.vstack([np.column_stack([s, cf_upper(s), np.ones_like(s)]),
                          np.column_stack([s, cf_lower(s), -np.ones_like(s)])])

    attached = element(lambda x: np.full_like(x, 0.004), lambda x: np.full_like(x, 0.004))
    # A long laminar bubble that reattaches well before the trailing edge: 29% of the S1223's whole surface
    # reversed at Re 200,000 (SST transition), every bit of it a bubble.
    bubble = element(lambda x: np.where((x > 0.15) & (x < 0.75), -0.001, 0.004), lambda x: np.full_like(x, 0.004))
    # Reversed from 33% to 97% chord, positive again in the trailing-edge corner (the stalled study wing).
    stalled = element(lambda x: np.full_like(x, 0.004), lambda x: np.where((x > 0.33) & (x < 0.97), -0.0006, 0.002))
    assert separation([attached]) == (False, None)
    assert separation([bubble]) == (False, None)
    sep, why = separation([attached, stalled])
    assert sep and why.startswith("Flap 1") and SEPARATED_SHARE < 0.6


@su2
def test_rans_says_the_stalled_study_wing_separates_and_an_attached_one_does_not(tmp_path):
    """Reversed flow past the first 5% of chord, on the quick mesh: the stalled
    study wing's main 33% at 30 mm (Cl -1.83, Cd 0.52), a NACA 4412 main alone
    3% at 100 mm (Cd 0.023, attached)."""
    from aeroengine.wing import rans
    from aeroengine.wing.design import layout

    w = json.loads((Path(__file__).parent / "data" / "stalled_wing.json").read_text())
    flow = {"alpha": 0.0, "mesh": "quick", "model": "sa", "transition": "auto", "n_crit": 5}
    p = {**{k: w[k] for k in ("elements", "speed", "rho", "mu", "ref_chord")}, **flow, "ride_height": 0.03}
    r = rans.solve(p, tmp_path / "s", tmp_path / "s" / "wing.su2", None, 6, None, lambda *a: None, lambda *a, **k: None,
                   field=False)
    assert r["converged"] and r["separated"] and r["separation"].startswith("Main")
    e = layout([naca4("4412")] * 2, 0.40, True).elements[0]
    one = [{"coords": e.placed().tolist(), "unit": e.unit.tolist(), "chord": e.chord, "angle": e.angle, "inverted": True}]
    q = {"elements": one, "speed": 15.0, "rho": 1.225, "mu": 1.81e-5, **flow, "ride_height": 0.10}
    r = rans.solve(q, tmp_path / "a", tmp_path / "a" / "wing.su2", None, 6, None, lambda *a: None, lambda *a, **k: None,
                   field=False)
    assert r["converged"] and not r["separated"] and r["separation"] is None


def test_default_model_is_fully_turbulent_sst():
    # Fully turbulent SST is the default: it converged where SST with transition
    # did not (UIUC Vol 1 check, 2026-11-05) and it is what STAR-CCM+ runs.
    case = Case(speed=20.0, rho=1.225, mu=1.81e-5, alpha_deg=0.0, ref_chord=0.3, ref_point=(0.075, 0.0), walls=["wall_0"])
    assert case.model == "sst"
    cfg = config(case, "wing.su2")
    assert "KIND_TURB_MODEL= SST" in cfg
    assert "KIND_TRANS_MODEL" not in cfg


def test_a_shape_gmsh_cannot_mesh_is_an_engine_error(tmp_path):
    # A figure-eight outline: gmsh fails inside generate(); the job must say so in words,
    # not crash with gmsh's own exception (it took down a whole UIUC benchmark run).
    t = np.linspace(0, 2 * np.pi, 81)
    eight = np.c_[0.5 + 0.5 * np.cos(t), 0.05 * np.sin(2 * t)]
    s = Settings(re=3e5, ref_chord=0.3, transition=[(0.4, 0.1)])
    with pytest.raises(EngineError, match="could not mesh"):
        build([eight * 0.3], s, tmp_path / "w.su2", [False])


def _crossed_trailing_edge() -> np.ndarray:
    # A NACA 0012 whose lower surface ends above its upper one, as measured tunnel
    # models' outlines sometimes do (UIUC SD7080, S6063, Clark-Y): the outline crosses itself.
    xy = np.asarray(naca4("0012"), float).copy()
    xy[-4:, 1] += np.array([0.001, 0.002, 0.003, 0.004])
    return xy


def test_a_trailing_edge_that_crosses_itself_is_trimmed(tmp_path):
    m = build([_crossed_trailing_edge() * 0.3], Settings(re=3e5, ref_chord=0.3, transition=[(1.0, 0.05)]),
              tmp_path / "w.su2", [False])
    assert m["cells"] > 0 and m["trailing_edge_trimmed"] == [True]


def test_wall_layers_are_thinned_when_gmsh_cannot_fit_them(tmp_path, monkeypatch):
    import gmsh

    from aeroengine.wing.mesh import boundary_layer_thickness
    real, calls = gmsh.model.mesh.generate, []

    def first_fails(dim):
        calls.append(dim)
        if len(calls) == 1:
            raise Exception("Edge not recovered: 1 2 444444")
        return real(dim)
    monkeypatch.setattr(gmsh.model.mesh, "generate", first_fails)
    m = build([np.asarray(naca4("0012"), float) * 0.3], Settings(re=3e5, ref_chord=0.3), tmp_path / "w.su2", [False])
    assert len(calls) == 2
    assert m["layer_thickness_m"] == pytest.approx(0.5 * 1.2 * boundary_layer_thickness(3e5, 0.3))
    assert m["layers"] >= 10


def test_a_mesh_gmsh_never_manages_is_an_engine_error(tmp_path, monkeypatch):
    import gmsh

    def never(dim):
        raise Exception("Edge not recovered: 1 2 444444")
    monkeypatch.setattr(gmsh.model.mesh, "generate", never)
    with pytest.raises(EngineError, match="could not mesh"):
        build([np.asarray(naca4("0012"), float) * 0.3], Settings(re=3e5, ref_chord=0.3), tmp_path / "w.su2", [False])


def test_a_surface_that_hooks_past_the_trailing_edge_is_trimmed():
    # UIUC S8037's lower surface runs past its trailing-edge point and turns back to it:
    # each surface must end at its aftmost point, which leaves a small blunt trailing edge.
    from aeroengine.wing.mesh import _untangle_trailing_edge
    xy = np.asarray(naca4("0012"), float).copy()
    xy[-2] = [1.0008, xy[-1, 1] - 0.0004]
    fixed, cut = _untangle_trailing_edge(xy, 1.0)
    assert cut and fixed[-1].tolist() == xy[-2].tolist() and len(fixed) == len(xy) - 1


def _oscillating(n=4000, cl=1.2, swing=0.01, drift=0.0, res_drop=3.0):
    it = np.arange(n)
    return {"rms[P]": -3 - res_drop * it / (n - 1), "CL": cl + swing * np.sin(0.05 * it) + drift * it,
            "CD": 0.02 + 0.02 * swing * np.cos(0.05 * it)}


def test_a_run_that_settles_on_average_counts_at_its_mean():
    # A steady solver wobbling about a steady answer (a laminar bubble, near stall): the strict
    # rule rejects it, but the mean of the last 300 iterations holds, and that mean is the result.
    h = _oscillating()
    case = Case(speed=10, rho=1.2, mu=1.8e-5, alpha_deg=0, ref_chord=1, ref_point=(0.25, 0), walls=["wall_0"])
    assert not judge(h, case)["converged"]
    s = settled(h)
    assert s["cl"] == pytest.approx(1.2, abs=0.002) and s["cd"] == pytest.approx(0.02, abs=0.0005)
    assert s["cl_swing"] == pytest.approx(0.01, rel=0.05)


def test_a_drifting_or_short_or_unconverging_run_does_not_settle():
    assert settled(_oscillating(drift=1e-4)) is None  # the mean creeps about 2% per 300 iterations
    assert settled(_oscillating(n=500)) is None  # too short to judge two windows
    assert settled(_oscillating(res_drop=1.0)) is None  # residuals never fell


def test_wing_mesh_writes_the_rans_mesh_and_runs_no_su2(tmp_path):
    """wing-mesh: the mesh wing-rans would use, kept in the job folder, without SU2."""
    els = _two()
    unit = naca4("4412").tolist()
    job = {"command": "wing-mesh", "options": {"cores": 2}, "params": {
        "elements": [{"coords": e.tolist(), "unit": unit, "angle": a, "inverted": False, "chord": c}
                     for e, a, c in zip(els, (0, 20), (1.0, 0.35))],
        "speed": 15.0, "alpha": 2.0, "model": "sa", "mesh": "quick", "transition": [[0.0, 0.0], [0.0, 0.0]]}}
    (tmp_path / "job.json").write_text(json.dumps(job))
    proc = subprocess.run(["aeroengine", "wing-mesh", "--input", str(tmp_path / "job.json"), "--workdir", str(tmp_path / "w")],
                          capture_output=True, text=True)
    assert proc.returncode == 0, proc.stdout[-2000:] + proc.stderr[-2000:]
    data = json.loads((tmp_path / "w" / "result.json").read_text())["data"]
    assert data["mesh_file"] == "wing.su2" and data["mesh"]["cells"] > 0
    cells, _ = _su2_cells(tmp_path / "w" / "wing.su2")
    assert len(cells) == data["mesh"]["cells"]
    assert not (tmp_path / "w" / "su2.cfg").exists()  # meshed only


def test_a_residual_that_climbs_is_divergence(tmp_path):
    """Car 2's strip at y 82 mm: the residual climbed 8 orders over 6000 iterations without SU2
    ever saying "has diverged" (no NaN), so the lower CFLs were never tried and its 1e21 N/m
    lift went into the car's totals. A residual 3 orders above where it started is divergence."""
    import stat
    import sys

    from aeroengine.wing import su2 as m

    fake = tmp_path / "SU2_CFD"
    fake.write_text(f"#!{sys.executable}\n"
                    "import time\n"
                    "for it in range(400):\n"
                    "    print(f'| {it} | {-4 + 0.02 * it:.3f} | 0.5 | 0.1 |', flush=True)\n"
                    "time.sleep(60)\n")
    fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
    case = Case(speed=20, rho=1.2, mu=1.8e-5, alpha_deg=5, ref_chord=0.4, ref_point=(0.1, 0), walls=["wall_0"])
    work = tmp_path / "w"
    work.mkdir()
    with pytest.raises(m.Diverged) as caught:
        m._run_once(case, work / "m.su2", work, fake, 1, None, None)
    assert 150 <= caught.value.iteration <= 160  # -4 + 3 = -1, reached at iteration 150


def test_an_upwind_run_that_diverges_tries_the_limiter_before_a_lower_cfl(monkeypatch, tmp_path):
    """Car 2's strip at y 82 mm diverged unlimited at CFL 10 and 4, and settled at CFL 10 with
    the Venkatakrishnan limiter; on clean strips the limiter stalled convergence and moved the
    lift, so it is the fallback, not the start."""
    from aeroengine.wing import su2 as m

    tried = []

    def fake(case, *a, **k):
        tried.append((case.scheme, case.cfl))
        if case.scheme == "fds":
            raise m.Diverged(42)
        return {"converged": True}

    monkeypatch.setattr(m, "_run_once", fake)
    case = Case(speed=20, rho=1.2, mu=1.8e-5, alpha_deg=0, ref_chord=1.0, ref_point=(0, 0), walls=["body"],
                scheme="fds", cfl=10.0)
    out = m.run(case, tmp_path / "m.su2", tmp_path, tmp_path / "SU2_CFD")
    assert tried == [("fds", 10.0), ("fds_limited", 10.0)] and out["scheme"] == "fds_limited"
    assert "SLOPE_LIMITER_FLOW= VENKATAKRISHNAN" in config(replace(case, scheme="fds_limited"), "m.su2")
