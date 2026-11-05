"""The quick methods against published wind-tunnel data (aeroengine.validation).

These pin how accurate the viscous core is today, so a change that makes it
worse shows up. The UIUC cases download the data from the University of
Illinois the first time (it is not committed); without a connection they
are skipped and say so."""

from __future__ import annotations

import json

import numpy as np
import pytest

from aeroengine import validation as v
from aeroengine.job import EngineError

SAMPLE_RUNS = """Airfoil: E387 (C)
Builder: J. Robertson
Comment: clean

Number of Reynolds #'s:
 2

Average Reynolds #:
 59700
Number of angles of attack:
 3
 alpha /   Cl   /  Cd   /  Spanwise Cd's >>>
 -6.16  -0.356   0.0657   0.0542   0.0561
  0.06   0.270   0.0230   0.0223   0.0190
 10.26   1.232   0.0318   0.0333   0.0292
Tabulated from data in file CL01573.DAT & reduced using program Q05.01D

Average Reynolds #:
 459200
Number of angles of attack:
 1
 alpha /   Cl   /  Cd   /  Spanwise Cd's >>>
  0.02   0.336   0.0071   0.0073   0.0073
"""

SAMPLE_COORDS = """::::::::::::::
e387a.dap
::::::::::::::
  E387 (A)
""" + "\n".join(f"  {1 - k / 20:.5f}  {0.01 * (1 - k / 20) * k / 20:.5f}" for k in range(21)) + "\n" + \
    "\n".join(f"  {k / 20:.5f}  {-0.005 * k / 20 * (1 - k / 20):.5f}" for k in range(1, 21)) + "\n"


def test_reading_the_uiuc_files():
    runs = v.parse_runs(SAMPLE_RUNS)
    assert [r["re"] for r in runs] == [59700, 459200]
    assert runs[0]["airfoil"] == "E387 (C)" and runs[0]["comment"] == "clean"
    assert runs[0]["rows"] == [(-6.16, -0.356, 0.0657), (0.06, 0.270, 0.0230), (10.26, 1.232, 0.0318)]
    coords = v.parse_coords(SAMPLE_COORDS)
    assert list(coords) == ["e387a.dap"] and coords["e387a.dap"].shape == (41, 2)
    assert v._model("E387 (A)", coords) == "e387a.dap"


def test_naca0012_against_ladson():
    """Re 6 million, tripped (NASA TM-4074): the viscous core within 5% of
    the measured lift and drag up to 2 degrees short of maximum lift."""
    r = v.compare(v.ladson_case())
    assert r["lift_error_mean"] <= 0.05 and r["drag_error_mean"] <= 0.05
    assert r["stalled"] and r["cl_max"] == pytest.approx(1.63, abs=0.01)


def _uiuc_or_skip():
    try:
        return v.uiuc_cases()
    except EngineError as exc:
        pytest.skip(f"UIUC data not available here: {exc.msg}")


def test_high_lift_sections_at_fs_reynolds_numbers():
    """Where the quick estimate stands on FS-type sections at Re 200,000 to
    300,000 (the numbers are what it gets today; docs/DECISIONS.md has the
    whole table). It reads lift high on every one, most on the most cambered."""
    cases = {c.key: v.compare(c) for c in _uiuc_or_skip()}
    assert {"s1223_200k", "s1223_250k", "s1223_300k", "e387_200k", "e387_300k", "fx63137_300k"} <= set(cases)
    assert all(c["lift_error_signed"] > 0 for c in cases.values())
    assert cases["e387_300k"]["lift_error_mean"] <= 0.06
    assert 0.12 <= cases["s1223_300k"]["lift_error_mean"] <= 0.22  # S1223's lift reads high by about a sixth
    # Drag within 25% except E387's, 28 to 37% off: its laminar separation
    # bubble's drag is what the viscous core gets worst.
    assert all(c["drag_error_mean"] <= 0.25 for k, c in cases.items() if not k.startswith("e387"))
    assert all(c["drag_error_mean"] <= 0.40 for c in cases.values())


def test_survey_of_every_clean_uiuc_run():
    _uiuc_or_skip()
    s = v.survey()
    if s["skipped"]:
        pytest.skip("; ".join(s["skipped"]))
    assert s["runs"] >= 150 and s["sections"] >= 45
    assert s["lift_median"] <= 0.09 and s["lift_signed_median"] > 0  # reads high, by about 8% in the middle
    assert s["drag_median"] <= 0.10 and s["drag_within_target"] >= 0.8


def test_the_estimate_matches_rans():
    """The estimate is held to RANS (and so to the STAR-CCM+ run after it),
    not to the tunnel: lift within 5% on every SU2 reference run that
    converged, drag within 10%, and the ones that never settled called
    separating."""
    r = v.against_rans()
    assert r["all_agree"] and r["lift_error_max"] <= 0.05 and r["drag_error_max"] <= 0.10
    assert sum(c["cl_rans"] is None for c in r["cases"]) == 2


# The ten-section benchmark the accuracy window shows ----------------------------------------------

def test_pick_run_takes_the_clean_run_with_most_angles():
    runs = [{"airfoil": "SG6043", "comment": "clean", "re": 299_100, "rows": [(0, .5, .01)] * 11},
            {"airfoil": "SG6043", "comment": "clean", "re": 299_700, "rows": [(0, .5, .01)] * 20},
            {"airfoil": "SG6043", "comment": "clean: flap = 10 degs", "re": 300_000, "rows": [(0, .5, .01)] * 30},
            {"airfoil": "SG6043", "comment": "clean", "re": 200_000, "rows": [(0, .5, .01)] * 40}]
    assert v.pick_run(runs, "SG6043")["re"] == 299_700
    assert v.pick_run(runs, "E387 (A)") is None


def test_rans_errors_use_only_converged_angles_inside_their_range():
    case = v.Case("t", "t", "", 3e5, np.zeros((3, 2)), [(-1.0, 0.4, 0.010), (1.0, 0.6, 0.012), (5.0, 1.0, 0.020)])
    rows = [(0.0, 0.5, 0.011, True), (2.0, 0.7, 0.013, True), (4.0, 0.9, 0.030, False)]
    a, cl, cd = v.rans_at_tunnel(case, rows)
    assert a == [1.0] and cl == pytest.approx([0.6]) and cd == pytest.approx([0.012])


def test_a_section_with_no_converged_rans_has_no_rans_errors():
    case = v.Case("t", "t", "", 3e5, np.zeros((3, 2)), [(0.0, 0.5, 0.01), (2.0, 0.7, 0.012)])
    assert v.errors(case, *v.rans_at_tunnel(case, [(0.0, 0.5, 0.01, False)])) == {"lift": None, "drag": None, "lift_signed": None}


def test_errors_follow_the_attached_range_and_lift_floor():
    # The lift peaks at 10 degrees, so above 8 is left out; near zero lift the error is against LIFT_FLOOR.
    case = v.Case("t", "t", "", 3e5, np.zeros((3, 2)),
                  [(0.0, 0.0, 0.01), (4.0, 0.8, 0.02), (9.0, 1.25, 0.035), (10.0, 1.3, 0.04), (12.0, 1.1, 0.06)])
    e = v.errors(case, [0.0, 4.0, 9.0], [0.04, 0.88, 2.0], [0.01, 0.022, 0.09])
    assert e["lift"] == pytest.approx((0.04 / 0.4 + 0.08 / 0.8) / 2)
    assert e["drag"] == pytest.approx((0.0 + 0.1) / 2)


def test_the_benchmark_cases():
    try:
        cases = v.benchmark_cases()
    except EngineError as exc:
        pytest.skip(f"UIUC data not available here: {exc.msg}")
    assert [c.key for c in cases] == [k for _, _, k in v.UIUC_BENCHMARK]
    assert all(abs(c.re / 300_000 - 1) < 0.05 and any(n.endswith(".dap") for n in c.notes) for c in cases)


def _two_cases():
    from aeroengine.wing.airfoils import naca4
    c = np.asarray(naca4("2412"), float)
    return [v.Case("a", "A", "", 3e5, c, [(0.0, 0.25, 0.008), (2.0, 0.47, 0.009), (4.0, 0.69, 0.010)], notes=["volume 1", "a.dap"]),
            v.Case("b", "B", "", 3e5, c, [(0.0, 0.25, 0.008), (2.0, 0.47, 0.009)], notes=["volume 3", "b.dap"])]


def _rans(case, workdir):
    return [(0.0, 0.26, 0.009, True), (2.0, 0.48, 0.010, True)]


def _run(tmp_path, **kw):
    kw.setdefault("rans_fn", _rans)
    return v.run_benchmark(tmp_path / "work", cores=1, su2_hint=None, progress=lambda *a: None,
                           results=tmp_path / "uiuc_results.json", cases=_two_cases(), **kw)


def test_missing_results_file_starts_a_new_history(tmp_path):
    run = _run(tmp_path)
    saved = json.loads((tmp_path / "uiuc_results.json").read_text())
    assert saved["runs"] == [run]
    assert [c["key"] for c in run["cases"]] == ["a", "b"] and run["cases"][1]["volume"] == 3
    assert run["settings"]["model"] == v.current_settings()["model"] and run["cores"] == 1
    assert run["cases"][0]["rans"] == [[0.0, 0.26, 0.009, True], [2.0, 0.48, 0.010, True]]
    assert run["summary"]["converged"] == 1.0 and run["summary"]["rans"]["lift"] is not None
    assert not (tmp_path / "uiuc_partial.json").exists()


def test_a_run_is_appended_newest_first(tmp_path):
    first = _run(tmp_path)
    second = _run(tmp_path, rans_fn=lambda case, wd: [(0.0, 0.30, 0.009, True), (2.0, 0.50, 0.010, True)])
    runs = json.loads((tmp_path / "uiuc_results.json").read_text())["runs"]
    assert runs == [second, first]


def test_summary_skips_cases_without_rans_errors_but_counts_their_angles(tmp_path):
    def rans(case, wd):
        return _rans(case, wd) if case.key == "a" else [(0.0, 0.3, 0.01, False), (2.0, 0.5, 0.01, False)]
    run = _run(tmp_path, rans_fn=rans)
    a, b = run["cases"]
    assert b["errors"]["rans"]["lift"] is None
    assert run["summary"]["rans"]["lift"] == pytest.approx(a["errors"]["rans"]["lift"])
    assert run["summary"]["converged"] == pytest.approx(2 / 4)


def test_a_cancelled_run_resumes_with_the_same_settings(tmp_path):
    def fails_on_b(case, wd):
        if case.key == "b":
            raise KeyboardInterrupt
        return _rans(case, wd)
    with pytest.raises(KeyboardInterrupt):
        _run(tmp_path, rans_fn=fails_on_b)
    partial = json.loads((tmp_path / "uiuc_partial.json").read_text())
    assert [c["key"] for c in partial["cases"]] == ["a"]
    seen = []
    run = _run(tmp_path, rans_fn=lambda case, wd: seen.append(case.key) or _rans(case, wd))
    assert seen == ["b"] and [c["key"] for c in run["cases"]] == ["a", "b"]


def test_a_partial_with_other_settings_is_discarded(tmp_path):
    other = dict(v.current_settings(), model="sa")
    (tmp_path / "uiuc_partial.json").write_text(json.dumps({"settings": other, "cases": [{"key": "a"}]}))
    seen = []
    _run(tmp_path, rans_fn=lambda case, wd: seen.append(case.key) or _rans(case, wd))
    assert seen == ["a", "b"]


def test_uiuc_results_without_the_tunnel_data_says_why(tmp_path, monkeypatch):
    def offline(folders=None):
        raise EngineError("could not download the UIUC low-speed airfoil data")
    monkeypatch.setattr(v, "benchmark_cases", offline)
    out = v.results_view(tmp_path / "none.json")
    assert out["runs"] == [] and out["tunnel"] == {}
    assert out["tunnel_error"] == "could not download the UIUC low-speed airfoil data"
    assert out["current"] == v.current_settings()


def test_uiuc_results_reads_the_history(tmp_path, monkeypatch):
    monkeypatch.setattr(v, "benchmark_cases", lambda folders=None: _two_cases())
    run = _run(tmp_path)
    out = v.results_view(tmp_path / "uiuc_results.json")
    assert out["runs"] == [run] and out["tunnel_error"] is None
    assert out["tunnel"]["b"] == {"name": "B", "re": 3e5, "rows": [[0.0, 0.25, 0.008], [2.0, 0.47, 0.009]]}


def test_the_warm_engine_serves_the_uiuc_results():
    from aeroengine import serve
    assert "uiuc-results" in serve.HANDLERS


def test_the_benchmark_shapes_mesh_like_any_library_section(tmp_path):
    """Measured outlines come re-panelled as the library stores every section;
    raw, the S1223's open trailing edge and the Clark-Y's crossing points
    broke the mesher once a laminar zone was in (2026-11-05)."""
    from aeroengine.wing import rans
    from aeroengine.wing.airfoils import POINTS
    from aeroengine.wing.mesh import Settings, build
    try:
        cases = v.benchmark_cases()
    except EngineError as exc:
        pytest.skip(f"UIUC data not available here: {exc.msg}")
    scale, growth = rans.MESH_LEVELS["fine"]
    for c in cases:
        assert len(c.coords) == POINTS
        st = Settings(re=c.re, ref_chord=0.3, surface_fine=0.0025 * scale, surface_coarse=0.008 * scale,
                      edge=0.0015 * scale, wake_size=0.01 * scale, growth=growth, alpha_deg=7.0,
                      transition=[(0.467, 0.0606)], ground=None)
        assert build([c.coords * 0.3], st, tmp_path / f"{c.key}.su2", [False])["cells"] > 0, c.key


def test_a_section_whose_rans_fails_is_recorded_and_the_run_finishes(tmp_path):
    def rans(case, wd):
        if case.key == "b":
            raise EngineError("gmsh produced no cells")
        return _rans(case, wd)
    run = _run(tmp_path, rans_fn=rans)
    b = run["cases"][1]
    assert b["rans"] == [] and b["rans_error"] == "gmsh produced no cells"
    assert b["errors"]["rans"]["lift"] is None
    # b's two planned angles (0 and 2 degrees) count as not converged.
    assert run["summary"]["converged"] == pytest.approx(2 / 4)


def test_rans_angles_bracket_the_whole_tunnel_range():
    case = v.Case("t", "t", "", 3e5, np.zeros((3, 2)), [(-2.68, 0.6, 0.04), (5.0, 1.5, 0.03), (16.38, 2.1, 0.05)])
    assert v.rans_alphas(case) == [float(a) for a in range(-4, 19, 2)]


def test_settings_name_the_engine_commit_not_every_commit(monkeypatch):
    import subprocess

    class Done:
        def __init__(self, out):
            self.stdout = out

    def fake(args, **kw):
        if "log" in args and "engine/src" in args:
            return Done("abc1234\n")
        if "status" in args and "engine/src" in args:
            return Done(" M engine/src/aeroengine/validation.py\n")
        return Done("fffffff\n")
    monkeypatch.setattr(subprocess, "run", fake)
    assert v.current_settings()["commit"] == "abc1234+"


def test_a_download_that_is_not_a_zip_is_an_engine_error(tmp_path, monkeypatch):
    import io
    import urllib.request
    monkeypatch.setattr(urllib.request, "urlopen", lambda url, timeout=60: io.BytesIO(b"<html>sign in to the wifi</html>"))
    with pytest.raises(EngineError):
        v.fetch_uiuc(tmp_path / "vol", volume=2)
