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
    assert 0 < data["transition"][0][0] < 1  # predicted, not left at the default
    assert not (tmp_path / "w" / "mesh").exists()  # the mesh is not kept unless asked
