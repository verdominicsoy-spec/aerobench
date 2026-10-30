"""Meshing and SU2 runs. The SU2 tests are skipped where SU2 is not installed."""

from __future__ import annotations

import json
import os
import shutil
import subprocess

import numpy as np
import pytest

from aeroengine.job import EngineError
from aeroengine.wing.airfoils import naca4
from aeroengine.wing.mesh import Settings, boundary_layer_thickness, build, first_cell_height, layers_for
from aeroengine.wing.su2 import Case, config, judge


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
    case = Case(speed=20, rho=1.2, mu=1.8e-5, alpha_deg=5, ref_chord=0.4, ref_point=(0.1, 0), walls=["wall_0", "wall_1"])
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
                      "restart": restart.parent.name if restart else None})
        if p["alpha"] == 2.0 and restart is not None:
            raise EngineError("SU2 diverged at every CFL tried")
        clock["t"] += 100.0 if mesh_ready is None else 60.0
        (workdir / "restart.dat").write_text("x")
        return {"alpha": p["alpha"], "cl": p["alpha"] / 10, "cd": 0.01, "converged": True,
                "mesh": {"cells": 1}, "transition": [[0.0, 0.0]]}

    monkeypatch.setattr(rans, "solve", fake_solve)
    out = rans.sweep({"alphas": [4, 0, 2, -2, 6], "time_limit": 300}, tmp_path, tmp_path / "m.su2", None, 1, None,
                     lambda *a: None, lambda *a, **k: None)
    # Rising order, one mesh (wakes on the middle angle), each angle from the one before.
    assert [c["alpha"] for c in calls[:2]] == [-2.0, 0.0] and all(c["wake"] == 2.0 for c in calls)
    assert calls[0]["ready"] is False and calls[0]["restart"] is None
    assert calls[1]["ready"] and calls[1]["restart"] == "a-2"
    # 2 degrees would not settle from 0 degrees' solution: tried again from rest.
    assert [c["restart"] for c in calls if c["alpha"] == 2.0] == ["a0", None]
    # 100 + 60 + 60 = 220 s so far; the next, at about 60 s more, still fits; the one after does not.
    assert [r["alpha"] for r in out["rows"]] == [-2.0, 0.0, 2.0, 4.0] and out["skipped"] == [6.0]
