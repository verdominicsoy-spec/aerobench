"""Airfoil library: generators, parsing, normalisation and the index."""

from __future__ import annotations

import json
import sqlite3

import numpy as np
import pytest

from aeroengine.job import EngineError
from aeroengine.wing.airfoils import (POINTS, build_index, import_files, naca, naca4, naca5, normalise, parse_dat,
                                      section, surfaces)


def test_naca0012_is_symmetric_and_12_percent():
    sec = section("NACA 0012", naca4("0012"))
    assert len(sec.coords) == POINTS
    assert sec.thickness == pytest.approx(0.12, abs=1e-3)
    assert sec.thickness_x == pytest.approx(0.30, abs=0.02)
    assert abs(sec.camber) < 1e-6
    half = (POINTS + 1) // 2
    assert np.allclose(sec.coords[:half][::-1, 1], -sec.coords[half - 1:, 1], atol=1e-9)


def test_the_trailing_edge_is_recorded_not_closed():
    assert section("open", naca4("0012")).te_thickness == pytest.approx(0.00252, abs=2e-4)
    assert section("closed", naca4("0012", closed=True)).te_thickness < 1e-6


def test_naca4_camber():
    sec = section("NACA 2412", naca4("2412"))
    assert sec.camber == pytest.approx(0.02, abs=1e-3) and sec.camber_x == pytest.approx(0.4, abs=0.02)


def test_naca5_camber_and_reflex():
    sec = section("NACA 23012", naca5("23012"))
    # The 230 camber line peaks near 15% chord.
    assert sec.camber_x == pytest.approx(0.15, abs=0.02)
    assert sec.thickness == pytest.approx(0.12, abs=1e-3)
    x = np.linspace(0.85, 0.98, 6)
    yu, yl = surfaces(section("NACA 23112", naca5("23112")).coords, x)
    plain_u, plain_l = surfaces(sec.coords, x)
    assert np.all(0.5 * (yu + yl) < 0.5 * (plain_u + plain_l))  # reflexed: the aft camber line turns up less
    with pytest.raises(EngineError):
        naca5("27012")
    with pytest.raises(EngineError):
        naca("123")


def _lednicer(xy: np.ndarray) -> str:
    half = (len(xy) + 1) // 2
    upper, lower = xy[:half][::-1], xy[half - 1:]
    lines = ["NACA 2412 LEDNICER", f"{len(upper)}.  {len(lower)}.", ""]
    lines += [f"{x:.6f} {y:.6f}" for x, y in upper] + [""] + [f"{x:.6f} {y:.6f}" for x, y in lower]
    return "\n".join(lines)


def test_selig_and_lednicer_are_told_apart():
    xy = naca4("2412", n=81)
    selig = "NACA 2412\n" + "\n".join(f"{x:.6f} {y:.6f}" for x, y in xy)
    n1, p1, f1 = parse_dat(selig)
    n2, p2, f2 = parse_dat(_lednicer(xy))
    assert (f1, f2) == ("selig", "lednicer")
    assert n1 == "NACA 2412" and n2 == "NACA 2412 LEDNICER"
    assert np.allclose(normalise(p1)[0], normalise(p2)[0], atol=1e-5)


def test_normalising_undoes_scale_rotation_offset_and_order():
    base, _ = normalise(naca4("4415"))
    a = np.radians(8)
    rot = np.array([[np.cos(a), -np.sin(a)], [np.sin(a), np.cos(a)]])
    moved = (naca4("4415") * 0.3) @ rot.T + [1.2, -0.4]
    again, _ = normalise(moved[::-1])  # lower surface first, too
    assert np.allclose(again, base, atol=2e-4)


def test_not_an_airfoil():
    cowl = np.column_stack([np.linspace(1, 0, 20), np.ones(20)])
    cowl = np.vstack([cowl, np.column_stack([np.linspace(0, 1, 20), -np.ones(20) + 0.5 * np.linspace(0, 1, 20)])])
    with pytest.raises(EngineError):
        section("cowl", cowl)


def test_index_and_my_airfoils(tmp_path):
    uiuc = tmp_path / "airfoils" / "uiuc"
    uiuc.mkdir(parents=True)
    xy = naca4("6409")
    (uiuc / "test6409.dat").write_text("TEST 6409\n" + "\n".join(f"{x:.6f} {y:.6f}" for x, y in xy))
    (uiuc / "broken.dat").write_text("nothing here\n1 2\n")
    out = build_index(tmp_path)
    assert out["counts"]["uiuc"] == 1 and out["counts"]["naca"] > 200
    assert [f["file"] for f in out["failed"]] == ["uiuc/broken.dat"]
    mine = tmp_path / "mine.dat"
    mine.write_text(_lednicer(naca4("2412", n=81)))
    added = import_files([mine], tmp_path)
    assert added["added"][0]["key"] == "mine/mine"
    db = sqlite3.connect(tmp_path / "airfoils" / "index.sqlite")
    row = db.execute("SELECT name, family, source, thickness, coords FROM airfoils WHERE key = 'uiuc/test6409'").fetchone()
    assert row[:3] == ("TEST 6409", "TEST", "uiuc") and row[3] == pytest.approx(0.09, abs=1e-3)
    assert len(json.loads(row[4])) == POINTS
    assert db.execute("SELECT source FROM airfoils WHERE key = 'mine/mine'").fetchone() == ("mine",)
    # A rebuild keeps My Airfoils.
    assert build_index(tmp_path)["counts"]["mine"] == 1


def test_commands(tmp_path):
    import os
    import subprocess

    job = tmp_path / "job.json"
    job.write_text(json.dumps({"command": "airfoil-naca", "params": {"code": "NACA 2412"}}))
    out = subprocess.run(["aeroengine", "airfoil-naca", "--input", str(job), "--workdir", str(tmp_path / "w")],
                         capture_output=True, text=True, env=os.environ)
    assert out.returncode == 0, out.stderr
    result = json.loads((tmp_path / "w" / "result.json").read_text())["data"]
    assert result["name"] == "NACA 2412" and len(result["coords"]) == POINTS
