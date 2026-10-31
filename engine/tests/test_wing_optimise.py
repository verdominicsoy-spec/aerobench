"""Wing geometry (the app's rules, in Python) and the optimiser loop, with a
stand-in for the RANS run so the loop's bookkeeping is tested in seconds."""

from __future__ import annotations

import json

import numpy as np
import optuna
import pytest

from aeroengine.job import EngineError
from aeroengine.wing import optimise
from aeroengine.wing.airfoils import naca4
from aeroengine.wing.geometry import Element, Variable, Wing, apply


def _area(p):
    return 0.5 * np.sum(p[:-1, 0] * p[1:, 1] - p[1:, 0] * p[:-1, 1])


def _starter() -> Wing:
    s = naca4("4412")
    w = Wing([Element(s, 0.30, 3.0, np.zeros(2), True), Element(s, 0.14, 25.0, np.array([0.27, 0.025]), True)])
    w.set_gap(0.012, 1)
    return w


def test_placing_matches_the_app():
    s = naca4("4412")
    up = Element(s, 0.5, 0.0, np.array([1.0, 2.0]), False)
    assert np.allclose(up.placed(), s * 0.5 + (1, 2))
    down = Element(s, 0.5, 0.0, np.array([1.0, 2.0]), True)
    assert np.allclose(down.placed(), s[::-1] * (0.5, -0.5) + (1, 2))
    # Counter-clockwise (Selig) either way up.
    assert _area(up.placed()) > 0 and _area(down.placed()) > 0
    # A bigger angle: trailing edge down upright, up when inverted.
    assert Element(s, 1, 10, np.zeros(2), False).trailing_edge[1] < -0.15
    assert Element(s, 1, 10, np.zeros(2), True).trailing_edge[1] > 0.15
    assert np.allclose(np.linalg.norm(Element(s, 1, 10, np.zeros(2), True).chord_direction), 1)


def test_gap_and_overlap_setters():
    w = _starter()
    assert w.gap(1) == pytest.approx(0.012, abs=1e-9)
    w.set_overlap(0.02, 1)
    assert w.overlap(1) == pytest.approx(0.02, abs=1e-12)
    before = w.elements[1].leading_edge.copy()
    w2 = apply(w, {"gap_1": 0.015, "overlap_1": 0.01})
    assert w2.gap(1) == pytest.approx(0.015, abs=1e-6) and w2.overlap(1) == pytest.approx(0.01, abs=1e-6)
    assert np.array_equal(w.elements[1].leading_edge, before)  # the base is untouched


def test_turning_a_flap_keeps_its_slot():
    w = _starter()
    w2 = apply(w, {"angle_1": 35.0})
    assert w2.elements[1].angle == 35.0
    assert w2.gap(1) == pytest.approx(w.gap(1), abs=1e-6) and w2.overlap(1) == pytest.approx(w.overlap(1), abs=1e-6)
    # Turning the main element carries the flap round with the slot intact.
    w3 = apply(w, {"angle_0": 8.0})
    assert w3.issues() == []
    assert w3.gap(1) == pytest.approx(w.gap(1), abs=1e-6) and w3.overlap(1) == pytest.approx(w.overlap(1), abs=1e-6)


def test_issues():
    w = _starter()
    assert w.issues() == []
    assert any("intersect" in m for m in apply(w, {"overlap_1": 0.12}).issues())
    w.min_gap = 0.02
    assert any("under the minimum gap" in m for m in w.issues())
    w.min_gap = 0.005
    w.rules_box = (-0.01, -0.2, 0.35, 0.2)
    assert any("outside the rules box" in m for m in w.issues())


def test_scores_and_penalties():
    spec = optimise.Spec([Variable(1, "angle", 0, 40)], objective="max_cl_cd_cap", cd_cap=0.05)
    assert optimise.score(spec, 2.0, 0.04) == (2.0, True)
    v, ok = optimise.score(spec, 2.0, 0.055)  # 10 % over the cap costs 1
    assert v == pytest.approx(1.0) and not ok
    spec = optimise.Spec([Variable(1, "angle", 0, 40)], objective="min_cd_cl_target", cl_target=2.0)
    assert spec.direction == "minimize"
    assert optimise.score(spec, 2.1, 0.04) == (0.04, True)
    v, ok = optimise.score(spec, 1.8, 0.04)
    assert v == pytest.approx(0.08) and not ok
    with pytest.raises(EngineError):
        optimise.Spec([Variable(1, "angle", 0, 40)], objective="max_cl_cd_cap")
    with pytest.raises(EngineError):
        optimise.Spec([Variable(1, "angle", 10, 5)])


def _fake(fail_every=0):
    """Downforce peaks at a flap angle of 30 degrees and a 12 mm gap."""
    calls = {"n": 0}

    def evaluate(wing: Wing, folder):
        calls["n"] += 1
        assert folder.is_dir()
        if fail_every and calls["n"] % fail_every == 0:
            raise EngineError("SU2 diverged at every CFL tried")
        a, g = wing.elements[1].angle, wing.gap(1)
        load = 2.5 - ((a - 30) / 10) ** 2 - ((g - 0.012) / 0.004) ** 2
        return {"cl": -load, "cd": 0.05, "cm": -0.2, "converged": not (fail_every and calls["n"] % fail_every == 1 and calls["n"] > 1),
                "reason": "Cl still moving", "elements": [{"cl": -0.6 * load}, {"cl": -0.4 * load}], "mesh": {"cells": 1}}

    return evaluate, calls


def test_finds_the_optimum_and_records_everything(tmp_path):
    spec = optimise.Spec([Variable(1, "angle", 15, 40), Variable(1, "gap", 0.006, 0.02)], trials=30, seed=1)
    evaluate, _ = _fake()
    out = optimise.run(_starter(), spec, evaluate, tmp_path / "s.db", "s", tmp_path / "work")
    assert out["base_sections"] is None  # no shape variables: nothing to keep
    assert out["complete"] == 30 and out["failed"] == 0
    first = out["trials"][0]
    assert first["params"] == pytest.approx({"angle_1": 25.0, "gap_1": 0.012}, abs=1e-6)  # the wing as drawn
    best = out["trials"][out["best"]]
    assert best["load"] > 2.3 and best["load"] == pytest.approx(-best["cl"])
    assert best["placement"][1]["angle"] == pytest.approx(best["params"]["angle_1"])
    assert best["gaps"][0] == pytest.approx(best["params"]["gap_1"], abs=1e-6)
    assert json.loads((tmp_path / "s.json").read_text())["best"] == out["best"]
    assert not any((tmp_path / "work").iterdir())  # trial folders are removed


def test_failures_are_recorded_and_the_study_carries_on(tmp_path):
    spec = optimise.Spec([Variable(1, "angle", 15, 40)], trials=12, seed=2)
    evaluate, _ = _fake(fail_every=4)
    out = optimise.run(_starter(), spec, evaluate, tmp_path / "s.db", "s", tmp_path / "w")
    states = [t["state"] for t in out["trials"] if t["state"] != "invalid"]  # invalid wings are never run
    assert len(states) == 12 and out["failed"] >= 4
    reasons = {t["reason"] for t in out["trials"] if t["state"] == "fail"}
    assert any("diverged" in r for r in reasons) and any("not converged" in r for r in reasons)
    assert out["best"] is not None and out["trials"][out["best"]]["state"] == "complete"


def test_invalid_wings_are_never_run_and_do_not_count(tmp_path):
    # Wide angle bounds: big flap angles hit the main element.
    spec = optimise.Spec([Variable(1, "angle", 15, 60), Variable(1, "gap", 0.003, 0.02)], trials=15, seed=1)
    evaluate, calls = _fake()
    out = optimise.run(_starter(), spec, evaluate, tmp_path / "s.db", "s", tmp_path / "w")
    assert out["complete"] == 15 == calls["n"] and out["invalid"] > 0
    bad = [t for t in out["trials"] if t["state"] == "invalid"]
    assert all(t["value"] is None and "Main and Flap 1" in t["reason"] for t in bad)
    assert out["trials"][out["best"]]["state"] == "complete"


def test_bounds_with_no_valid_wing_stop_the_study(tmp_path):
    spec = optimise.Spec([Variable(1, "overlap", 0.10, 0.14)], trials=4, seed=3)
    evaluate, calls = _fake()
    with pytest.raises(EngineError, match="broke a constraint"):
        optimise.run(_starter(), spec, evaluate, tmp_path / "s.db", "s", tmp_path / "w")
    assert calls["n"] == 0


def test_resume_and_interrupted_trials(tmp_path):
    spec = optimise.Spec([Variable(1, "angle", 15, 40)], trials=5, seed=4)
    evaluate, calls = _fake()
    optimise.run(_starter(), spec, evaluate, tmp_path / "s.db", "s", tmp_path / "w")
    # A trial cut off mid-run (the app quit): left running in the file.
    study = optuna.load_study(study_name="s", storage=f"sqlite:///{tmp_path / 's.db'}")
    cut = study.ask({"angle_1": optuna.distributions.FloatDistribution(15, 40)})
    spec.trials = 8
    out = optimise.run(_starter(), spec, evaluate, tmp_path / "s.db", "s", tmp_path / "w")
    assert out["complete"] == 8 and calls["n"] == 8
    assert out["trials"][cut.number]["reason"] == "interrupted"
    assert any(t["params"] == cut.params for t in out["trials"][cut.number + 1:])  # run again
    other = optimise.Spec([Variable(1, "gap", 0.005, 0.02)], trials=9)
    with pytest.raises(EngineError, match="other design variables"):
        optimise.run(_starter(), other, evaluate, tmp_path / "s.db", "s", tmp_path / "w")


@pytest.mark.parametrize("sampler", ["tpe", "cmaes"])
def test_parallel_trials(tmp_path, sampler):
    spec = optimise.Spec([Variable(1, "angle", 15, 40), Variable(1, "gap", 0.006, 0.02)], trials=16, parallel=4,
                         sampler=sampler, seed=5)
    evaluate, calls = _fake()
    out = optimise.run(_starter(), spec, evaluate, tmp_path / "s.db", "s", tmp_path / "w")
    assert out["complete"] == 16 and calls["n"] == 16
    assert sum(t["state"] == "complete" for t in out["trials"]) == 16  # plus any invalid wings, never run


def test_fallback_scheme_trials_are_failed(tmp_path):
    spec = optimise.Spec([Variable(1, "angle", 20, 35)], trials=3, seed=6)
    evaluate, _ = _fake()

    def on_fallback(wing, folder):
        return {**evaluate(wing, folder), "scheme": "fds"}

    out = optimise.run(_starter(), spec, on_fallback, tmp_path / "s.db", "s", tmp_path / "w")
    assert out["failed"] == 3 and all("fallback" in t["reason"] for t in out["trials"])


def test_a_resumed_seeded_study_does_not_replay_its_proposals(tmp_path):
    spec = optimise.Spec([Variable(1, "angle", 15, 40), Variable(1, "gap", 0.006, 0.02)], trials=4, seed=7)
    evaluate, _ = _fake()
    for total in (4, 8, 12):  # three sessions, each a fresh process in real use
        spec.trials = total
        out = optimise.run(_starter(), spec, evaluate, tmp_path / "s.db", "s", tmp_path / "w")
    points = [tuple(round(v, 9) for v in t["params"].values()) for t in out["trials"] if t["state"] != "invalid"]
    assert len(points) == len(set(points))


def test_unsettled_runs_are_failed_but_steer_the_sampler(tmp_path):
    spec = optimise.Spec([Variable(1, "angle", 15, 45)], trials=10, seed=3)
    evaluate, _ = _fake()

    def separating(wing, folder):
        res = evaluate(wing, folder)
        if wing.elements[1].angle > 34:  # the flap separates: the run never settles
            res.update(converged=False, reason="Cl still moving")
        return res

    out = optimise.run(_starter(), spec, separating, tmp_path / "s.db", "s", tmp_path / "w")
    bad = [t for t in out["trials"] if t["params"]["angle_1"] > 34 and t["state"] != "invalid"]
    assert bad and all(t["state"] == "fail" and t["value"] is None and "not converged" in t["reason"] for t in bad)
    assert out["complete"] + out["failed"] == 10 and out["trials"][out["best"]]["params"]["angle_1"] <= 34
    # The sampler saw each as worse than every real result before it (and
    # nothing until there were two to measure by).
    study = optuna.load_study(study_name="s", storage=f"sqlite:///{tmp_path / 's.db'}")
    told = 0
    for t in study.trials:
        if not t.user_attrs.get("unsettled"):
            continue
        before = [o.value for o in study.trials[:t.number] if o.state.name == "COMPLETE"
                  and not o.user_attrs.get("unsettled") and not o.user_attrs.get("invalid")]
        if len(before) < 2:
            assert t.value is None
        else:
            told += 1
            assert t.value < min(before)
    assert told


def test_the_best_designs_are_checked_with_another_solver(tmp_path):
    spec = optimise.Spec([Variable(1, "angle", 15, 40), Variable(1, "gap", 0.006, 0.02)], trials=20, seed=8,
                         solver="estimate")
    evaluate, _ = _fake()
    optimise.run(_starter(), spec, evaluate, tmp_path / "s.db", "s", tmp_path / "w")
    checked = []

    def rans(wing, folder):
        checked.append(round(wing.elements[1].angle, 6))
        load = 2.0 if len(checked) == 2 else 1.5  # RANS prefers the second-best estimate
        return {"cl": -load, "cd": 0.05, "converged": True}

    out = optimise.check(_starter(), spec, tmp_path / "s.db", "s", rans, 3, tmp_path / "w")
    assert len(out["checks"]) == 3 and len(set(checked)) == 3  # three distinct designs
    best_by_estimate = sorted([t for t in out["trials"] if t["state"] == "complete"], key=lambda t: -t["value"])[:3]
    assert [c["number"] for c in out["checks"]] == [t["number"] for t in best_by_estimate]
    assert out["checks"][1]["value"] == 2.0 and out["checks"][1]["converged"]
    assert out["solver"] == "estimate"
    # Checking again does not rerun what is already checked.
    optimise.check(_starter(), spec, tmp_path / "s.db", "s", rans, 3, tmp_path / "w")
    assert len(checked) == 3
    # And the study cannot be resumed with another solver.
    with pytest.raises(EngineError, match="another solver"):
        optimise.run(_starter(), optimise.Spec(spec.variables, trials=25, solver="rans"), evaluate, tmp_path / "s.db", "s",
                     tmp_path / "w")


def test_reshaping_a_section():
    from aeroengine.wing.geometry import reshape

    s = naca4("0012")
    assert reshape(s) is s
    cambered = reshape(s, camber=0.02)
    i = int(np.argmin(s[:, 0]))
    up, lo = cambered[: i + 1][::-1], cambered[i:]
    x = np.linspace(0.05, 0.95, 19)
    mean = 0.5 * (np.interp(x, up[:, 0], up[:, 1]) + np.interp(x, lo[:, 0], lo[:, 1]))
    assert mean == pytest.approx(0.02 * 4 * x * (1 - x), abs=2e-4)  # the camber added, the thickness kept
    assert np.interp(0.3, up[:, 0], up[:, 1]) - np.interp(0.3, lo[:, 0], lo[:, 1]) == pytest.approx(0.12, abs=0.002)
    thin = reshape(naca4("2412"), thickness=0.75)
    t = lambda p, k: np.interp(0.3, p[: k + 1][::-1, 0], p[: k + 1][::-1, 1]) - np.interp(0.3, p[k:, 0], p[k:, 1])
    k = int(np.argmin(thin[:, 0]))
    assert t(thin, k) == pytest.approx(0.75 * t(naca4("2412"), k), rel=0.01)
    assert thin.shape == s.shape and thin[k] == pytest.approx(s[k])  # same points, leading edge in place


def test_shape_variables_with_the_quick_estimate(tmp_path):
    """More camber on the flap means more downforce until it separates: the
    estimate-driven search finds it, and the trial's wing carries the shape."""
    from aeroengine.wing.estimate import estimate

    def evaluate(wing, folder):
        els = [{"coords": e.placed().tolist(), "unit": e.unit.tolist(), "chord": e.chord, "angle": e.angle,
                "inverted": e.inverted} for e in wing.elements]
        r = estimate(els, [0.0], 15.0)["rows"][0]
        return {"cl": r["cl"], "cd": r["cd"], "cm": 0.0, "converged": not r["separating"], "reason": "separating",
                "elements": r["elements"]}

    spec = optimise.Spec([Variable(1, "camber", 0.0, 0.03), Variable(1, "thickness", 0.8, 1.2)],
                         trials=16, seed=5, solver="estimate")
    out = optimise.run(_starter(), spec, evaluate, tmp_path / "s.db", "s", tmp_path / "work")
    assert out["trials"][0]["params"] == {"camber_1": 0.0, "thickness_1": 1.0}
    best = out["trials"][out["best"]]
    assert best["params"]["camber_1"] > 0.01 and best["load"] > out["trials"][0]["load"]
    # The sections the shapes are relative to go with the study, for the app.
    assert np.allclose(out["base_sections"][1], _starter().elements[1].unit, atol=1e-6)
    with pytest.raises(EngineError, match="above zero"):
        optimise.Spec([Variable(1, "thickness", 0.0, 1.2)])
