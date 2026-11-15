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
    # The suction surface is fine either way; a laminar pressure surface past its nose adds more.
    assert laminar["surface_nodes"][0] > 1.15 * turbulent["surface_nodes"][0]


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


def test_default_model_is_transition():
    # Transition RANS is the default: closest to the tunnel on lift and drag (validation README, root causes).
    case = Case(speed=20, rho=1.2, mu=1.8e-5, alpha_deg=5, ref_chord=0.4, ref_point=(0.1, 0), walls=["wall_0"])
    assert case.model == "sst-lm" and "KIND_TRANS_MODEL= LM" in config(case, "m.su2")


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


def test_a_sweep_over_a_ground_meshes_each_angle_and_starts_each_from_rest(monkeypatch, tmp_path):
    """Over a ground the wing turns against it: no shared mesh, no restart from a neighbour."""
    from aeroengine.wing import rans

    calls = []

    def fake_solve(p, workdir, mesh_file, su2_hint, cores, env, progress, log, field=True, mesh_ready=None, restart=None):
        calls.append((p["alpha"], mesh_ready, restart))
        (workdir / "restart.dat").write_text("x")
        return {"alpha": p["alpha"], "cl": -1.0, "cd": 0.05, "converged": True, "iterations": 500,
                "mesh": {"cells": 1}, "transition": [[0.0, 0.0]]}

    monkeypatch.setattr(rans, "solve", fake_solve)
    out = rans.sweep({"alphas": [0, 2, 4], "ride_height": 0.06}, tmp_path, tmp_path / "m.su2", None, 1, None,
                     lambda *a: None, lambda *a, **k: None)
    assert sorted(a for a, _, _ in calls) == [0.0, 2.0, 4.0]
    assert all(ready is None and restart is None for _, ready, restart in calls)
    assert [r["alpha"] for r in out["rows"]] == [0.0, 2.0, 4.0] and all(r["started_from"] is None for r in out["rows"])


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


def _element(cf_upper, cf_lower):
    """Columns of surface_cf: x/c, skin friction along the flow, side (1 upper, -1 lower), distance from the
    stagnation point over the chord; here the stagnation point sits on the nose."""
    s = np.linspace(0.0, 1.0, 400)
    return np.vstack([np.column_stack([s, cf_upper(s), np.ones_like(s), s]),
                      np.column_stack([s, cf_lower(s), -np.ones_like(s), s])])


def _attached(x):
    return np.full_like(x, 0.004)


def test_a_bubble_that_closes_is_reported_not_separated():
    from aeroengine.wing.rans import regions, separation

    r = regions([_element(lambda x: np.where((x > 0.30) & (x < 0.40), -0.001, 0.004), _attached)], [False])
    assert [(q["kind"], q["surface"], q["loaded"]) for q in r] == [("bubble", "upper", "suction")]
    assert r[0]["start"] == pytest.approx(0.30, abs=0.01) and r[0]["end"] == pytest.approx(0.40, abs=0.01)
    assert separation(r) == (False, None)


def test_reversed_flow_over_the_last_15_percent_is_separation():
    # Today's 15% bar measured up to 95% chord missed this (Flap 3 of frontwing#1).
    from aeroengine.wing.rans import regions, separation

    r = regions([_element(_attached, _attached), _element(_attached, lambda x: np.where(x > 0.85, -0.001, 0.004))],
                [True, True])
    assert [(q["element"], q["kind"], q["surface"], q["loaded"]) for q in r] == \
        [(1, "trailing-edge separation", "lower", "suction")]
    sep, why = separation(r)
    assert sep and why.startswith("Flap 1") and "85%" in why


def test_reversed_from_the_nose_is_a_leading_edge_stall_even_if_it_closes():
    from aeroengine.wing.rans import regions, separation

    to_edge = regions([_element(lambda x: np.where(x > 0.005, -0.001, 0.004), _attached)], [False])
    closes = regions([_element(_attached, lambda x: np.where((x > 0.01) & (x < 0.91), -0.001, 0.004))], [False])
    short = regions([_element(lambda x: np.where((x > 0.01) & (x < 0.04), -0.001, 0.004), _attached)], [False])
    assert [q["kind"] for q in to_edge] == ["leading-edge stall"]
    assert [(q["kind"], q["loaded"]) for q in closes] == [("leading-edge stall", "pressure")]
    assert [q["kind"] for q in short] == ["leading-edge bubble"]
    assert separation(to_edge)[0] and separation(closes)[0] and not separation(short)[0]
    assert "leading edge" in separation(closes)[1]


def _frontwing(run):
    from aeroengine.wing.rans import regions, surface_cf

    d = json.loads((Path(__file__).parent / "data" / "frontwing1_wall.json").read_text())
    placed = [np.asarray(e) for e in d["elements"]]
    return regions(surface_cf(np.asarray(d[run]), placed), d["inverted"])


def _spans(r, element, surface):
    return [(round(q["start"], 2), round(q["end"], 2), q["kind"]) for q in r
            if q["element"] == element and q["surface"] == surface]


def test_frontwing_as_run_reports_every_region():
    from aeroengine.wing.rans import separation

    r = _frontwing("as_run")
    assert _spans(r, 0, "upper") == []  # the strip between nose and stagnation point is not reversed flow
    assert [k for _, _, k in _spans(r, 0, "lower")] == ["leading-edge bubble"]  # a small laminar bubble at the suction peak
    assert [k for _, _, k in _spans(r, 1, "lower")] == ["trailing-edge separation"] and _spans(r, 1, "lower")[0][0] == pytest.approx(0.74, abs=0.02)
    f2 = _spans(r, 2, "lower")
    assert f2[0][2] == "bubble" and f2[0][0] == pytest.approx(0.42, abs=0.02) and f2[0][1] == pytest.approx(0.68, abs=0.02)
    f3 = _spans(r, 3, "lower")
    assert f3[0][2] == "bubble" and f3[0][0] == pytest.approx(0.39, abs=0.02)
    assert f3[-1][2] == "trailing-edge separation" and f3[-1][0] == pytest.approx(0.85, abs=0.02)
    assert all(q["loaded"] == "suction" for q in r if q["surface"] == "lower")
    sep, why = separation(r)
    assert sep and "Flap 1" in why and "Flap 3" in why and "Main" not in why


def test_frontwing_at_plus_10_stalls_the_main_on_its_pressure_surface():
    # What STAR-CCM+ showed on the car: the main's upper surface separated.
    from aeroengine.wing.rans import separation

    r = _frontwing("plus10")
    main = _spans(r, 0, "upper")
    assert len(main) == 1 and main[0][2] == "leading-edge stall" and main[0][0] < 0.03 and main[0][1] > 0.85
    sep, why = separation(r)
    assert sep and why.startswith("Main") and "upper (pressure)" in why


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


def test_sst_option_is_fully_turbulent():
    # The faster option, and what STAR-CCM+ runs: SST with no transition model.
    case = Case(speed=20.0, rho=1.225, mu=1.81e-5, alpha_deg=0.0, ref_chord=0.3, ref_point=(0.075, 0.0), walls=["wall_0"],
                model="sst")
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


def test_wall_y_plus_is_read_from_the_walls_only(monkeypatch, tmp_path):
    """SU2 writes y+ zero away from the walls: those points are not part of the wall's numbers."""
    import numpy as np

    from aeroengine.wing import field, rans

    yp = np.array([0.0, 0.0, 0.5, 1.0, 1.5, 4.0] + [0.0] * 10)
    monkeypatch.setattr(field, "_read_vtu", lambda path: (None, None, {"Y_Plus": yp}))
    out = rans.y_plus(tmp_path / "flow.vtu")
    assert out["max"] == 4.0 and out["mean"] == pytest.approx(1.75) and 1.5 < out["p95"] < 4.0
    monkeypatch.setattr(field, "_read_vtu", lambda path: (None, None, {}))
    assert rans.y_plus(tmp_path / "flow.vtu") is None


def test_a_wing_command_refuses_a_density_that_is_not_air():
    from aeroengine.commands.wing import estimate_from_params

    unit = naca4("4412").tolist()
    p = {"elements": [{"coords": _two()[0].tolist(), "unit": unit, "angle": 0, "inverted": False, "chord": 1.0}],
         "speed": 15.0, "rho": 1184.0}
    with pytest.raises(EngineError, match=r"Air density 1184 kg/m³ is not air"):
        estimate_from_params(p)
    with pytest.raises(EngineError, match=r"Air viscosity 0\.5 Pa s is not air"):
        estimate_from_params({**p, "rho": 1.2, "mu": 0.5})


def test_typed_transition_checks_the_reynolds_number_before_meshing(monkeypatch):
    from aeroengine.wing import rans

    def no_mesh(*a, **k):
        raise AssertionError("meshed a wing whose Reynolds number is out of range")

    monkeypatch.setattr(rans, "build", no_mesh)
    unit = naca4("4412").tolist()
    p = {"elements": [{"coords": e.tolist(), "unit": unit, "angle": a, "inverted": False, "chord": c}
                      for e, a, c in zip(_two(), (0, 20), (1.0, 0.35))],
         "speed": 1e6, "alpha": 2.0, "model": "sa", "mesh": "quick", "transition": [[0.1, 0.2], [0.1, 0.2]]}
    with pytest.raises(EngineError, match="Reynolds number .* is outside 1e3 to 1e8"):
        rans.solve(p, Path("/nonexistent"), Path("/nonexistent/wing.su2"), None, 1, None, lambda *a: None,
                   lambda *a, **k: None)


def test_kill_all_su2_ends_every_live_group_and_empties_the_registry():
    from aeroengine.wing import su2 as su2mod

    proc = subprocess.Popen(["sleep", "30"], start_new_session=True)
    with su2mod._live_lock:
        su2mod._live.add(proc)
    t0 = time.monotonic()
    su2mod.kill_all_su2()
    assert proc.wait(timeout=2) != 0 and time.monotonic() - t0 < 1.5
    assert not su2mod._live


def test_laminar_saving_is_the_flat_plate_friction_difference():
    """A fully turbulent model has no laminar runs. Over a run of x chords the
    saving is x (0.074 / Re_x^0.2 - 1.328 / Re_x^0.5), on the reference chord."""
    from aeroengine.wing.rans import laminar_saving

    x, re = 0.5, 3e5
    one = x * (0.074 / (re * x) ** 0.2 - 1.328 / (re * x) ** 0.5)
    assert laminar_saving([(x, x)], [0.3], 0.3, [re]) == pytest.approx(2 * one)
    # An element of half the reference chord counts half; no run, no saving.
    assert laminar_saving([(x, 0.0)], [0.15], 0.3, [re]) == pytest.approx(0.5 * one)
    assert laminar_saving([(0.0, 0.0)], [0.3], 0.3, [re]) == 0.0


def test_config_sustains_freestream_turbulence():
    # Without SU2's sustaining terms SST decays the far field's 1% to 0.14% by the
    # time it reaches the wing, 50 chords in (frontwing#1, 12 Nov 2026).
    case = Case(speed=20.0, rho=1.2, mu=1.8e-5, alpha_deg=0.0, ref_chord=0.4, ref_point=(0.1, 0), walls=["wall_0"])
    for model in ("sst", "sst-lm"):
        case.model = model
        assert "SST_OPTIONS= SUSTAINING" in config(case, "m.su2")
    case.model = "sa"
    assert "SST_OPTIONS" not in config(case, "m.su2")


@su2
def test_tu_at_wing_reads_the_set_value(tmp_path):
    """The turbulence intensity typed in is the one the wing sees."""
    from aeroengine.wing import rans

    c = naca4("0012")
    one = [{"coords": c.tolist(), "unit": c.tolist(), "chord": 1.0, "angle": 0.0, "inverted": False}]
    p = {"elements": one, "speed": 20.0, "rho": 1.2, "mu": 1.8e-5, "alpha": 2.0, "mesh": "quick", "model": "sst",
         "transition": "auto", "turbulence_intensity": 0.01, "iterations": 300}
    r = rans.solve(p, tmp_path / "s", tmp_path / "s" / "wing.su2", None, 6, None, lambda *a: None,
                   lambda *a, **k: None, field=False)
    assert 0.008 < r["tu_at_wing"] < 0.012
    assert r["rans_version"] == 3


def _wall_edges(path, marker):
    lines = path.read_text().splitlines()
    npoin = next(i for i, l in enumerate(lines) if l.startswith("NPOIN"))
    n = int(lines[npoin].split("=")[1].split()[0])
    pts = np.array([list(map(float, l.split()[:2])) for l in lines[npoin + 1:npoin + 1 + n]])
    at = lines.index(f"MARKER_TAG= {marker}")
    m = int(lines[at + 1].split("=")[1])
    edges = np.array([list(map(int, l.split()[1:3])) for l in lines[at + 2:at + 2 + m]])
    return pts[edges[:, 0]], pts[edges[:, 1]]


def test_suction_surface_is_fine_everywhere(tmp_path):
    # NeuralFoil, on each flap alone at its own angle, put frontwing#1's Flap 2 transition at 3.6% of chord;
    # its bubble sat at 42-68%, on the coarse spacing. Every suction surface is now fine to the trailing edge.
    d = json.loads((Path(__file__).parent / "data" / "frontwing1_wall.json").read_text())
    placed = [np.asarray(e) for e in d["elements"]]
    zones = [(1.0, 0.013), (0.669, 1.0), (0.0357, 1.0), (0.0466, 1.0)]  # NeuralFoil's, as the run had them
    s = Settings(re=9e5, ref_chord=0.682, transition=zones)
    build(placed, s, tmp_path / "w.su2", d["inverted"])
    for i, e in enumerate(placed):
        lead = int(np.argmin(e[:, 0]))
        chord = float(np.linalg.norm(0.5 * (e[0] + e[-1]) - e[lead]))
        a, b = _wall_edges(tmp_path / "w.su2", f"wall_{i}")
        mid = 0.5 * (a + b)
        # the suction side of these inverted elements is the half of the outline after the nose (Selig order)
        near = np.argmin(np.linalg.norm(mid[:, None] - e[None], axis=2), axis=1)
        suction = near > lead
        assert np.linalg.norm(b - a, axis=1)[suction].max() <= 1.05 * s.surface_fine * chord, i


def _fake_solver(calls, cl_of_alpha):
    def fake(p, workdir, mesh_file, su2_hint, cores, env, progress, log, field=True, mesh_ready=None, restart=None):
        calls.append({"alpha": p["alpha"], "ready": mesh_ready is not None, "restart": restart})
        workdir.mkdir(parents=True, exist_ok=True)
        (workdir / "restart.dat").write_text("x")
        (workdir / "history.csv").write_text("x")
        cl = cl_of_alpha(p["alpha"], len(calls))
        return {"alpha": p["alpha"], "cl": cl, "cd": 0.03, "converged": True, "separated": False, "separation": None,
                "regions": [], "mesh": {"cells": 1}, "transition": [[0.0, 0.0]], "elements": [{"cl": cl, "cd": 0.03}]}
    return fake


def _estimate(monkeypatch, cl_of_alpha):
    from aeroengine.wing import rans

    monkeypatch.setattr(rans, "_estimate_polar", lambda p, alphas: [(a, cl_of_alpha(a, 0)) for a in alphas])


def _finite_params(**extra):
    e = {"coords": [[1, 0], [0, 0], [1, 0]], "unit": [[1, 0], [0, 0], [1, 0]], "angle": 0, "inverted": True, "chord": 1.0}
    return {"elements": [e], "alpha": 0.0, "ref_chord": 1.0, "finite": {"span": 2.0, "endplate": 0.0}, **extra}


def test_finite_wing_runs_at_the_induced_angle(monkeypatch, tmp_path):
    from aeroengine.wing import rans

    calls = []
    # A downforce wing losing 0.08 of Cl per degree the flow turns up, zero lift at +12 deg.
    monkeypatch.setattr(rans, "solve", _fake_solver(calls, lambda a, n: -0.08 * (12 - a)))
    _estimate(monkeypatch, lambda a, n: -0.09 * (13 - a))  # the quick estimate: a little more lift
    r = rans.solve_finite(_finite_params(), tmp_path, tmp_path / "m.su2", None, 1, None, lambda *a: None,
                          lambda *a, **k: None)
    # Fixed point a = (0.08 * 180/pi / (pi * 2)) * (12 - a): 5.061 deg.
    f = r["finite"]
    assert f["converged"] and f["solves"] <= 4 and f["alpha_effective"] == pytest.approx(5.061, abs=0.1)
    # The first solve at the estimate's own fixed point (0.8207 (13 - a) = a: 5.86 deg), not at the full angle.
    assert calls[0]["alpha"] == pytest.approx(5.86, abs=0.02) and len(calls) >= 2
    assert all(c["ready"] and c["restart"] is not None for c in calls[1:])  # free air: one mesh, each from the last
    assert r["cl"] == pytest.approx(-0.08 * (12 - calls[-1]["alpha"]))
    assert r["cd"] == pytest.approx(0.03 + f["cd_induced"]) and f["cd_induced"] == pytest.approx(r["cl"] ** 2 / (np.pi * 2), rel=0.005)  # the lattice: AR 2 at e 0.999


def test_finite_wing_that_never_settles_stops_at_six_solves(monkeypatch, tmp_path):
    from aeroengine.wing import rans

    calls = []
    monkeypatch.setattr(rans, "solve", _fake_solver(calls, lambda a, n: -2.0 if n % 2 else -0.5))
    _estimate(monkeypatch, lambda a, n: -0.08 * (12 - a))
    r = rans.solve_finite(_finite_params(), tmp_path, tmp_path / "m.su2", None, 1, None, lambda *a: None,
                          lambda *a, **k: None)
    assert len(calls) == 6 and not r["finite"]["converged"]


def test_finite_wing_over_a_ground_meshes_each_angle(monkeypatch, tmp_path):
    from aeroengine.wing import rans

    calls = []
    monkeypatch.setattr(rans, "solve", _fake_solver(calls, lambda a, n: -0.08 * (12 - a)))
    _estimate(monkeypatch, lambda a, n: -0.09 * (13 - a))
    r = rans.solve_finite(_finite_params(ride_height=0.1), tmp_path, tmp_path / "m.su2", None, 1, None,
                          lambda *a: None, lambda *a, **k: None)
    assert all(not c["ready"] and c["restart"] is None for c in calls)
    assert r["finite"]["ground_factor"] < 1


def test_finite_wing_needs_span_and_endplate(tmp_path):
    from aeroengine.wing import rans

    with pytest.raises(EngineError, match="span"):
        rans.solve_finite(_finite_params(finite={"endplate": 0.1}), tmp_path, tmp_path / "m.su2", None, 1, None,
                          lambda *a: None, lambda *a, **k: None)


def test_surface_points_carry_skin_friction_along_the_flow():
    from aeroengine.wing.rans import add_cf, surface_cf

    d = json.loads((Path(__file__).parent / "data" / "frontwing1_wall.json").read_text())
    placed = [np.asarray(e) for e in d["elements"]]
    pts = np.asarray(d["as_run"])
    cf = surface_cf(pts, placed)
    # The surface file's points are the same wall points: here, Flap 3's.
    flap3 = pts[np.argmin([np.min(np.linalg.norm(pts[:, None, :2] - e[None], axis=2), axis=1) for e in placed], axis=0) == 3]
    surface = [{"x": flap3[:, 0].tolist(), "y": flap3[:, 1].tolist(), "cp": flap3[:, 4].tolist()}]
    out = add_cf(surface, cf[3:4])
    assert len(out[0]["cf"]) == len(out[0]["x"])
    x = np.asarray(out[0]["x"]); c = np.asarray(out[0]["cf"])
    lead, te = placed[3][int(np.argmin(placed[3][:, 0]))], 0.5 * (placed[3][0] + placed[3][-1])
    xc = (np.column_stack([x, out[0]["y"]]) - lead) @ ((te - lead) / np.linalg.norm(te - lead)) / np.linalg.norm(te - lead)
    assert (c[(xc > 0.88) & (xc < 0.94)] < 0).any()  # its trailing-edge separation from 85%
    assert (c[(xc > 0.15) & (xc < 0.25)] > 0).all()


def test_bracket_reruns_fully_turbulent_from_the_transition_solution(monkeypatch, tmp_path):
    from aeroengine.wing import rans

    calls = []

    def fake(p, workdir, mesh_file, su2_hint, cores, env, progress, log, field=True, mesh_ready=None, restart=None):
        calls.append({"model": p["model"], "alpha": p["alpha"], "ready": mesh_ready is not None, "restart": restart})
        sep = p["model"] == "sst"
        return {"cl": -2.2, "cd": 0.035, "converged": True, "separated": sep, "separation": "Flap 3 ..." if sep else None,
                "regions": [], "mesh": {"cells": 1}, "transition": [[0, 0]]}

    monkeypatch.setattr(rans, "solve", fake)
    (tmp_path / "restart.dat").write_text("x")
    first = {"cl": -2.37, "cd": 0.030, "converged": True, "separated": False, "separation": None, "regions": [],
             "mesh": {"cells": 1}, "transition": [[0, 0]], "model": "sst-lm"}
    p = {"model": "sst-lm", "alpha": 0.0, "elements": [{}]}
    r = rans.bracket(p, first, tmp_path, tmp_path / "m.su2", None, 1, None, lambda *a: None, lambda *a, **k: None)
    assert calls == [{"model": "sst", "alpha": 0.0, "ready": True, "restart": (tmp_path / "restart.dat").resolve()}]
    assert r["bracket"]["sst"]["cl"] == -2.2 and r["bracket"]["sst"]["separated"]
    assert r["transition_decides"]  # one separates, the other does not
    # At the induced angle when the run was as on the car; over a ground, a fresh mesh and no restart.
    calls.clear()
    rans.bracket({**p, "ride_height": 0.05}, {**first, "finite": {"alpha_effective": 4.2}}, tmp_path, tmp_path / "m.su2",
                 None, 1, None, lambda *a: None, lambda *a, **k: None)
    assert calls == [{"model": "sst", "alpha": 4.2, "ready": False, "restart": None}]
    # As on the car, the turbulent Cd carries the same induced drag, from its own Cl.
    car = rans.bracket(p, {**first, "finite": {"alpha_effective": 4.2, "aspect_ratio_effective": 2.0, "ground_factor": 0.5}},
                       tmp_path, tmp_path / "m.su2", None, 1, None, lambda *a: None, lambda *a, **k: None)
    assert car["bracket"]["sst"]["cd"] == pytest.approx(0.035 + 2.2**2 / (np.pi * 2.0) * 0.5)


def test_bracket_says_when_transition_does_not_decide(monkeypatch, tmp_path):
    from aeroengine.wing import rans

    monkeypatch.setattr(rans, "solve", lambda p, *a, **k: {"cl": -2.30, "cd": 0.034, "converged": True, "separated": False,
                                                            "separation": None, "regions": []})
    first = {"cl": -2.37, "cd": 0.030, "converged": True, "separated": False, "regions": [], "mesh": {}, "transition": []}
    r = rans.bracket({"model": "sst-lm", "alpha": 0.0}, first, tmp_path, tmp_path / "m.su2", None, 1, None,
                     lambda *a: None, lambda *a, **k: None)
    assert not r["transition_decides"]  # same verdict, lift within 5%


def test_finite_wing_settles_where_lift_falls_steeply(monkeypatch, tmp_path):
    # frontwing#1 as on the car: past +10 deg the main stalls and Cl moves 0.16 a degree,
    # so relaxing towards the induced angle swings about it; a secant step lands on it.
    from aeroengine.wing import rans

    calls = []
    monkeypatch.setattr(rans, "solve", _fake_solver(calls, lambda a, n: -2.38 if a == 0 else -1.37 + 0.161 * (a - 10.45)))
    _estimate(monkeypatch, lambda a, n: -2.4 + 0.1 * a)  # the estimate misses the stall: its angle is well off
    r = rans.solve_finite(_finite_params(finite={"span": 1.0, "endplate": 0.25}, ref_chord=0.682), tmp_path, tmp_path / "m.su2",
                          None, 1, None, lambda *a: None, lambda *a, **k: None)
    assert r["finite"]["converged"] and r["finite"]["solves"] <= 4


def test_finite_wing_stops_at_a_solve_that_did_not_converge(monkeypatch, tmp_path):
    # frontwing#1 at 80 mm: the 2D solve did not converge (Cl -6.3 and swinging), the loop steered by it
    # to +12.5 deg and that solve failed outright. An unconverged Cl is not a result to steer by.
    from aeroengine.wing import rans

    calls = []
    fake = _fake_solver(calls, lambda a, n: -6.3)

    def unconverged(*a, **k):
        r = fake(*a, **k)
        return {**r, "converged": False, "reason": "residual fell 3.2 orders"}

    monkeypatch.setattr(rans, "solve", unconverged)
    _estimate(monkeypatch, lambda a, n: -0.08 * (12 - a))
    r = rans.solve_finite(_finite_params(ride_height=0.08), tmp_path, tmp_path / "m.su2", None, 1, None,
                          lambda *a: None, lambda *a, **k: None)
    assert len(calls) == 2 and calls[1]["alpha"] == calls[0]["alpha"]  # one more go from itself, then stop
    assert not r["converged"] and not r["finite"]["converged"]
    assert "did not converge" in r["finite"]["stopped"]


def test_finite_wing_gives_an_unsettled_solve_one_more_go_from_itself(monkeypatch, tmp_path):
    # Zerihan's wing at +1.97 deg: residual down 3.8 orders of 4.0 after 4,000 iterations from rest.
    # SST-LM often needs longer: the same angle again from its own solution before the loop gives up.
    from aeroengine.wing import rans

    calls = []
    fake = _fake_solver(calls, lambda a, n: -0.08 * (12 - a))

    def slow(*a, **k):
        r = fake(*a, **k)
        return {**r, "converged": len(calls) != 1, "reason": "residual fell 3.8 orders, needs 4.0"}

    starts = []
    monkeypatch.setattr(rans, "solve", lambda p, *a, **k: (starts.append(p.get("residual_start")), slow(p, *a, **k))[1])
    _estimate(monkeypatch, lambda a, n: -0.08 * (12 - a))
    real = rans.su2.read_history
    monkeypatch.setattr(rans.su2, "read_history", lambda f: {"rms[P]": np.array([0.8, 0.5, -3.0])})
    r = rans.solve_finite(_finite_params(ride_height=0.1), tmp_path, tmp_path / "m.su2", None, 1, None,
                          lambda *a: None, lambda *a, **k: None)
    assert calls[1]["alpha"] == calls[0]["alpha"] and calls[1]["ready"] and calls[1]["restart"] is not None
    assert starts[0] is None and starts[1] == 0.8  # judged from where the first run began
    assert real is not None
    assert r["finite"]["converged"] and r["finite"]["stopped"] is None


def test_a_continued_run_measures_its_residual_from_where_the_first_began():
    # Zerihan's wing as on the car: 4,000 iterations from rest took the residual down 3.8 orders; the
    # continuation from that solution wobbles about the same answer and fell only 0.1 more. Judged on its
    # own it never "converged" and could not settle; from where the first run began it fell 3.9 orders.
    cont = _oscillating(res_drop=0.1)  # starts at -3, the first run having begun at +0.8
    case = Case(speed=10, rho=1.2, mu=1.8e-5, alpha_deg=0, ref_chord=1, ref_point=(0.25, 0), walls=["wall_0"])
    assert settled(cont) is None
    case.residual_start = 0.8
    assert judge(cont, case)["residual_drop"] == pytest.approx(3.9, abs=0.01)
    assert settled(cont, start=0.8)["cl"] == pytest.approx(1.2, abs=0.002)


def test_a_slow_oscillation_settles_over_whole_periods():
    # Zerihan's wing at h/c 0.448: Cl -0.918 +-0.013 with a 500-iteration period (trailing-edge shedding off
    # its 0.7%-chord base), the mean steady to 0.002 over 4,000 iterations. Means over 300 iterations, less
    # than a period, swing by more than the 1% allowed; over whole periods they hold.
    it = np.arange(4000)
    h = {"rms[P]": np.full(4000, -5.0), "CL": -0.918 + 0.013 * np.sin(2 * np.pi * it / 500),
         "CD": 0.03 + 0.002 * np.cos(2 * np.pi * it / 500)}
    s = settled(h, start=-1.0)
    assert s is not None and s["cl"] == pytest.approx(-0.918, abs=0.002) and s["window"] >= 1000


def test_an_unsteady_run_gives_its_mean_and_swing_not_a_result_or_nothing():
    # Zerihan's wing at h/c 0.224 as on the car: residual down 4.4 orders, Cl wandering 1.24-1.37 with
    # 500-iteration means 1.27-1.33. No steady answer to settle on; the mean of the last half is 1.28
    # (the balance read 1.269). Reported as unsteady, mean and swing; a drifting run still is not.
    from aeroengine.wing.su2 import unsteady

    rng = np.random.default_rng(1)
    it = np.arange(4000)
    cl = -1.29 + 0.03 * np.sin(2 * np.pi * it / 730) + 0.02 * np.sin(2 * np.pi * it / 310 + 1) + 0.005 * rng.standard_normal(4000)
    h = {"rms[P]": np.linspace(-8.6, -9.3, 4000), "CL": cl, "CD": 0.05 + 0.1 * (cl + 1.29)}
    assert settled(h, start=-4.9) is None
    u = unsteady(h, start=-4.9)
    assert u["cl"] == pytest.approx(-1.29, abs=0.01) and 0.03 < u["cl_swing"] < 0.07
    assert unsteady({**h, "CL": cl + 1e-4 * it}, start=-4.9) is None  # drifting 0.2 over the run: not a mean
    assert unsteady(h, start=-7.0) is None  # residual barely fell


def test_a_runs_verdict_and_numbers_come_from_one_place():
    from aeroengine.wing.su2 import verdict

    case = Case(speed=10, rho=1.2, mu=1.8e-5, alpha_deg=0, ref_chord=1, ref_point=(0.25, 0), walls=["wall_0"])
    rng = np.random.default_rng(1)
    it = np.arange(4000)
    wander = -1.29 + 0.03 * np.sin(2 * np.pi * it / 730) + 0.02 * np.sin(2 * np.pi * it / 310 + 1) + 0.005 * rng.standard_normal(4000)
    h = {"rms[P]": np.linspace(-8.6, -9.3, 4000), "CL": wander, "CD": 0.05 + 0.1 * (wander + 1.29)}
    case.residual_start = -4.9
    v, final = verdict(h, case)
    assert not v["converged"] and v["unsteady"] and "unsteady" in v["reason"]
    assert final(h["CL"]) == pytest.approx(-1.29, abs=0.01)  # the mean, not the last iteration
    swing = _oscillating()  # a clean swing still settles, and counts as converged on average
    v, final = verdict(swing, Case(speed=10, rho=1.2, mu=1.8e-5, alpha_deg=0, ref_chord=1, ref_point=(0.25, 0), walls=["w"]))
    assert v["converged"] and v["averaged"] and not v["unsteady"]


def test_finite_wing_steers_by_an_unsteady_mean(monkeypatch, tmp_path):
    from aeroengine.wing import rans

    calls = []
    fake = _fake_solver(calls, lambda a, n: -0.08 * (12 - a))
    monkeypatch.setattr(rans, "solve", lambda *a, **k: {**fake(*a, **k), "converged": False, "unsteady": True})
    _estimate(monkeypatch, lambda a, n: -0.09 * (13 - a))
    r = rans.solve_finite(_finite_params(), tmp_path, tmp_path / "m.su2", None, 1, None, lambda *a: None,
                          lambda *a, **k: None)
    assert r["finite"]["stopped"] is None and r["finite"]["alpha_effective"] == pytest.approx(5.061, abs=0.1)
    assert r["unsteady"] and not r["converged"]


def test_finite_wing_secant_steps_are_bounded(monkeypatch, tmp_path):
    # Two solves with nearly the same miss (a flat stretch of Cl near the main's stall): the secant
    # would jump tens of degrees and spend a solve there. Each step is held to FINITE_STEP.
    from aeroengine.wing import rans

    calls = []
    monkeypatch.setattr(rans, "solve", _fake_solver(calls, lambda a, n: {1: -2.0, 2: -1.99}.get(n, -1.0)))
    _estimate(monkeypatch, lambda a, n: -0.08 * (12 - a))
    rans.solve_finite(_finite_params(), tmp_path, tmp_path / "m.su2", None, 1, None, lambda *a: None,
                      lambda *a, **k: None)
    steps = [abs(b["alpha"] - a["alpha"]) for a, b in zip(calls, calls[1:])]
    assert len(calls) >= 3 and max(steps) <= rans.FINITE_STEP + 1e-9


def test_finite_wing_stopped_later_reports_the_last_converged_solve(monkeypatch, tmp_path):
    # Solve 1 converged; solve 2 (and its second go) did not. The result is solve 1's, flagged as stopped.
    from aeroengine.wing import rans

    calls = []
    fake = _fake_solver(calls, lambda a, n: -2.0 if n == 1 else -6.3)

    def second_fails(*a, **k):
        r = fake(*a, **k)
        return r if len(calls) == 1 else {**r, "converged": False, "reason": "residual fell 2.1 orders"}

    monkeypatch.setattr(rans, "solve", second_fails)
    _estimate(monkeypatch, lambda a, n: -0.08 * (12 - a))
    r = rans.solve_finite(_finite_params(), tmp_path, tmp_path / "m.su2", None, 1, None, lambda *a: None,
                          lambda *a, **k: None)
    f = r["finite"]
    assert r["converged"] and r["cl"] == pytest.approx(-2.0)
    assert f["alpha_effective"] == pytest.approx(calls[0]["alpha"], abs=1e-3) and not f["converged"]
    assert "did not converge" in f["stopped"]


def test_finite_wing_on_a_stall_cliff_reports_the_cliff(monkeypatch, tmp_path):
    # frontwing#1.02 as STAR ran it: the section holds Cl -3.2 to +8.6 deg and has lost it all past there, so
    # the induced angle's answer is on the cliff and no angle settles. The loop narrows it and says so.
    from aeroengine.wing import rans

    calls = []
    section = lambda a, n: -3.2 if a < 8.6 else 0.05  # noqa: E731
    monkeypatch.setattr(rans, "solve", _fake_solver(calls, section))
    _estimate(monkeypatch, section)
    r = rans.solve_finite(_finite_params(), tmp_path, tmp_path / "m.su2", None, 1, None, lambda *a: None,
                          lambda *a, **k: None)
    f = r["finite"]
    assert not f["converged"] and f["solves"] <= 6
    c = f["cliff"]
    assert c["low"] < 8.6 < c["high"] and c["high"] - c["low"] <= 0.25
    assert c["cl_low"] == -3.2 and c["cl_high"] == 0.05


def test_finite_wing_that_settles_has_no_cliff(monkeypatch, tmp_path):
    from aeroengine.wing import rans

    monkeypatch.setattr(rans, "solve", _fake_solver([], lambda a, n: -0.08 * (12 - a)))
    _estimate(monkeypatch, lambda a, n: -0.09 * (13 - a))
    r = rans.solve_finite(_finite_params(), tmp_path, tmp_path / "m.su2", None, 1, None, lambda *a: None,
                          lambda *a, **k: None)
    assert r["finite"]["converged"] and r["finite"]["cliff"] is None


def _drawn_element():
    return naca4("4412", 41) * 0.2 + np.array([0.3, 0.05])  # Selig order: trailing edge, upper, nose, lower


def test_zero_turns_leave_the_elements_as_drawn():
    from aeroengine.wing.rans import turn_elements

    e = _drawn_element()
    assert np.array_equal(turn_elements([e], [0.0])[0], e)


def test_an_element_turns_about_its_quarter_chord_as_alpha_turns_the_wing():
    from aeroengine.wing.estimate import in_ground_effect
    from aeroengine.wing.rans import turn_elements

    e = _drawn_element()
    te = 0.5 * (e[0] + e[-1])
    nose = e[int(np.argmax(np.linalg.norm(e - te, axis=1)))]
    quarter = nose + 0.25 * (te - nose)
    t = turn_elements([e], [5.0])[0]
    # the quarter-chord point stays put: the turned outline's own quarter chord is where it was
    te2 = 0.5 * (t[0] + t[-1])
    nose2 = t[int(np.argmax(np.linalg.norm(t - te2, axis=1)))]
    assert nose2 + 0.25 * (te2 - nose2) == pytest.approx(quarter, abs=1e-12)
    # the same turn the wing gets from alpha 5 over a ground, up to where it sits
    g = in_ground_effect([e], 5.0, 0.1)[0][0]
    assert t - t.mean(axis=0) == pytest.approx(g - g.mean(axis=0), abs=1e-12)


def test_element_turns_need_one_per_drawn_element():
    from aeroengine.wing.rans import turn_elements

    with pytest.raises(EngineError, match="one turn per element"):
        turn_elements([_drawn_element(), _drawn_element()], [1.0])


def test_finite_wing_turns_each_element_by_its_own_induced_angle(monkeypatch, tmp_path):
    from aeroengine.wing import rans

    calls = []

    def fake(p, workdir, mesh_file, su2_hint, cores, env, progress, log, field=True, mesh_ready=None, restart=None):
        calls.append({"alpha": p["alpha"], "turns": list(p.get("element_turns") or []), "ready": mesh_ready is not None})
        workdir.mkdir(parents=True, exist_ok=True)
        (workdir / "restart.dat").write_text("x")
        cl = -0.08 * (12 - p["alpha"])
        return {"alpha": p["alpha"], "cl": cl, "cd": 0.03, "converged": True, "separated": False, "separation": None,
                "regions": [], "mesh": {"cells": 1}, "transition": [[0.0, 0.0]] * 2,
                "elements": [{"cl": 0.6 * cl, "cd": 0.02}, {"cl": 0.4 * cl, "cd": 0.01}]}

    monkeypatch.setattr(rans, "solve", fake)
    _estimate(monkeypatch, lambda a, n: -0.09 * (13 - a))
    front = {"coords": [[0.5, 0], [0, 0], [0.5, 0]], "unit": [[1, 0], [0, 0], [1, 0]], "angle": 0, "inverted": True, "chord": 0.5}
    back = {**front, "coords": [[1.0, 0], [0.5, 0], [1.0, 0]]}
    r = rans.solve_finite(_finite_params(elements=[front, back]), tmp_path, tmp_path / "m.su2", None, 1, None,
                          lambda *a: None, lambda *a, **k: None)
    # a downforce wing: the element behind meets a steeper flow, turned the unloading way (alpha's sense)
    assert all(len(c["turns"]) == 2 and c["turns"][0] < 0 < c["turns"][1] for c in calls)
    assert r["finite"]["element_turns"] == pytest.approx(calls[-1]["turns"], abs=1e-3)
