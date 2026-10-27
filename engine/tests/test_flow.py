"""Flow Field Viewer. The spec's acceptance check is the synthetic regression:
frames rendered from a known analytic field, encoded as H.264, reconstructed,
values within 3% of the colour range and isosurface volumes within 5%."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest
from scipy.ndimage import binary_dilation

from aeroengine.flow import colormap, synthetic
from aeroengine.flow.calibration import Calibration
from aeroengine.flow.iso import enclosed_volume, isosurface, write_vti
from aeroengine.flow.reconstruct import FrameSource, Volume, reconstruct
from aeroengine.job import EngineError

RANGE = 2.0  # value range of the synthetic sweeps, -1..1


@pytest.fixture(scope="module", params=[False, True], ids=["fixed", "perspective"])
def sweep(request, tmp_path_factory):
    d = tmp_path_factory.mktemp("sweep")
    cal = synthetic.make_sweep(d / "sweep.mp4", perspective=request.param)
    vol, summary = reconstruct(d / "sweep.mp4", Calibration(cal))
    return d / "sweep.mp4", cal, vol, summary


def _clean_region(vol: Volume):
    """Voxels away from the body and the domain edges, where colours blend."""
    X, Y, Z = np.meshgrid(vol.x, vol.y, vol.z, indexing="ij")
    truth = synthetic.field(X, Y, Z)
    near_body = binary_dilation(np.isnan(truth), iterations=2)
    edge = (np.abs(Y) > synthetic.Y_HALF - 0.02) | (Z < 0.02) | (Z > synthetic.Z_TOP - 0.02)
    return truth, ~near_body & ~edge


# Acceptance check ------------------------------------------------------------

def test_values_recovered_within_3_percent_of_range(sweep):
    _, _, vol, _ = sweep
    truth, ok = _clean_region(vol)
    rec = vol.values[ok]
    assert np.isfinite(rec).mean() > 0.999
    err = np.abs(rec - np.clip(truth[ok], -1, 1))
    assert np.nanmax(err) <= 0.03 * RANGE, np.nanpercentile(err, [50, 99, 100])


@pytest.mark.parametrize("level", [0.0, 0.3, 0.6])
def test_isosurface_volume_within_5_percent(sweep, level):
    _, _, vol, _ = sweep
    mesh = isosurface(vol, level)
    assert mesh.triangle_count > 1000
    assert enclosed_volume(mesh) == pytest.approx(synthetic.wake_volume(level), rel=0.05)


# Reconstruction details ------------------------------------------------------

def test_body_and_background_are_empty_not_guessed(sweep):
    _, _, vol, summary = sweep
    X, Y, Z = np.meshgrid(vol.x, vol.y, vol.z, indexing="ij")
    deep_in_body = (X < synthetic.BODY[0] - 0.05) & (np.abs(Y) < synthetic.BODY[1] - 0.03) & \
                   (Z > synthetic.BODY[2] + 0.02) & (Z < synthetic.BODY[3] - 0.02)
    assert deep_in_body.any()
    assert np.isnan(vol.values[deep_in_body]).all()
    assert summary["median_dE"] < 3


def test_legend_sampling_matches_the_preset(sweep):
    path, cal, _, _ = sweep
    frame = FrameSource(path).frame(0)
    h, w = frame.shape[:2]
    sampled = colormap.sample_legend(frame, [w - 330, h - 29], [w - 30, h - 29])
    lut = colormap.ColorLUT(sampled, -1, 1)
    true_rgb = (colormap.preset("star_blue_yellow_red", 64) * 255).round().astype(np.uint8)
    values, dist = lut.invert(true_rgb[None])
    assert np.abs(values[0] - np.linspace(-1, 1, 64)).max() < 0.06
    assert np.median(dist) < 3


def test_reconstruct_with_legend_colormap(tmp_path):
    cal = synthetic.make_sweep(tmp_path / "s.mp4", frames=31)
    w, h = cal["source_size"]
    cal["colormap"] = {"legend": {"frame": 0, "p0": [w - 330, h - 29], "p1": [w - 30, h - 29]}}
    vol, _ = reconstruct(tmp_path / "s.mp4", Calibration(cal))
    truth, ok = _clean_region(vol)
    err = np.abs(vol.values[ok] - np.clip(truth[ok], -1, 1))
    assert np.nanpercentile(err, 99) <= 0.03 * RANGE


def test_perspective_scale_follows_the_pinhole_model():
    cam = synthetic.Camera(perspective=True)
    xs = np.linspace(synthetic.X0, synthetic.X1, 121)
    cal = Calibration(json.loads(json.dumps(_cal_for(cam, xs))))
    for f in (0, 17, 60, 103, 120):
        s = cal.scale_at(f)
        assert s.sx == pytest.approx(cam.scale(xs[f]), rel=1e-9)
        assert (s.cu, s.cv) == pytest.approx(cam.centre(xs[f]), rel=1e-9)


def _cal_for(cam, xs):
    def pts(f):
        s = cam.scale(xs[f])
        cu, cv = cam.centre(xs[f])
        return {"frame": f, "points": [{"px": [cu, cv], "world": [0, 0]}, {"px": [cu + s * 0.5, cv - s * 0.3], "world": [0.5, 0.3]}]}
    return {"crop": [0, 0, 960, 540], "spatial": {"mode": "points", "frames": [pts(0), pts(len(xs) - 1)]},
            "planes": {"mode": "linear", "start": 0, "end": 2}}


def test_extent_options_and_window(tmp_path):
    cal = synthetic.make_sweep(tmp_path / "p.mp4", frames=21, perspective=True)
    common, _ = reconstruct(tmp_path / "p.mp4", Calibration({**cal, "extent": "common"}))
    everything, _ = reconstruct(tmp_path / "p.mp4", Calibration({**cal, "extent": "all"}))
    window, _ = reconstruct(tmp_path / "p.mp4", Calibration({**cal, "window": [-0.3, 0.3, 0.0, 0.6]}))
    assert everything.y[-1] - everything.y[0] >= common.y[-1] - common.y[0]
    assert window.y[0] == pytest.approx(-0.3) and window.y[-1] == pytest.approx(0.3)
    assert len(window.y) == cal["working_width"]


def test_plane_positions_from_csv_and_reversed_sweeps(tmp_path):
    cal = synthetic.make_sweep(tmp_path / "s.mp4", frames=21)
    cal["planes"] = {"mode": "csv", "positions": list(np.linspace(2.0, 0.0, 21)), "stride": 2}
    vol, _ = reconstruct(tmp_path / "s.mp4", Calibration(cal))
    assert np.all(np.diff(vol.x) > 0)  # stored increasing even when the sweep runs backwards
    assert len(vol.x) == 11


def test_image_sequence_source(tmp_path):
    import cv2

    cal = synthetic.make_sweep(tmp_path / "s.mp4", frames=11)
    seq = tmp_path / "frames"
    seq.mkdir()
    src = FrameSource(tmp_path / "s.mp4")
    for i, f in src.frames(list(range(11))):
        cv2.imwrite(str(seq / f"frame_{i:03d}.png"), f[:, :, ::-1])
    vol, _ = reconstruct(seq, Calibration(cal))
    assert vol.values.shape[0] == 11


@pytest.mark.parametrize("bad, match", [
    ({"crop": [0, 0, 2, 2]}, "crop"),
    ({"value_range": [1, -1]}, "value_range"),
    ({"spatial": {"mode": "points", "frames": []}}, "one frame"),
    ({"planes": {"mode": "linear", "start": 1, "end": 1}}, "differ"),
    ({"colormap": {"preset": "nope"}}, None),
])
def test_bad_calibrations_are_engine_errors(tmp_path, bad, match):
    cal = {**synthetic.make_sweep(tmp_path / "s.mp4", frames=5), **bad}
    with pytest.raises(EngineError, match=match):
        reconstruct(tmp_path / "s.mp4", Calibration(cal))


def test_isosurface_outside_the_data_is_empty(sweep):
    _, _, vol, _ = sweep
    assert isosurface(vol, 5.0).triangle_count == 0


def test_vti_export(sweep, tmp_path):
    _, _, vol, _ = sweep
    path = tmp_path / "v.vti"
    write_vti(vol, path)
    text = path.read_bytes()
    assert b'type="ImageData"' in text and b"np.float64" not in text
    vtk = pytest.importorskip("vtkmodules.vtkIOXML")
    from vtkmodules.util.numpy_support import vtk_to_numpy

    reader = vtk.vtkXMLImageDataReader()
    reader.SetFileName(str(path))
    reader.Update()
    img = reader.GetOutput()
    assert img.GetDimensions() == vol.values.shape
    data = vtk_to_numpy(img.GetPointData().GetArray("Cp0")).reshape(vol.values.shape[::-1]).transpose(2, 1, 0)
    assert np.allclose(data, vol.values, equal_nan=True)


# Commands end to end --------------------------------------------------------

def test_flow_commands_end_to_end(engine, tmp_path):
    demo = tmp_path / "demo"
    code, events, err = engine.run("flow-demo", {"params": {"frames": 31, "perspective": True}}, demo, timeout=180)
    assert code == 0, (events, err)
    cal = json.loads((demo / "demo_calibration.json").read_text())
    video = str(demo / "demo.mp4")

    code, events, err = engine.run("flow-preview", {"params": {"source": video, "calibration": cal, "frame": 10}}, tmp_path / "pv")
    assert code == 0, (events, err)
    assert (tmp_path / "pv" / "preview.png").exists()

    rec = tmp_path / "rec"
    code, events, err = engine.run("flow-reconstruct", {"params": {"source": video, "calibration": cal}}, rec, timeout=180)
    assert code == 0, (events, err)
    data = json.loads((rec / "result.json").read_text())["data"]
    meta = json.loads((rec / "volume.json").read_text())
    nx, ny, nz = meta["shape"]
    assert (rec / "volume.bin").stat().st_size == 4 * nx * ny * nz
    assert data["planes"] == nx == 31

    iso = tmp_path / "iso"
    code, events, err = engine.run("flow-iso", {"params": {"volume": str(rec / "volume.npz"), "levels": [0.0, 0.5]}}, iso)
    assert code == 0, (events, err)
    levels = json.loads((iso / "result.json").read_text())["data"]["levels"]
    assert [lv["triangles"] > 0 for lv in levels] == [True, True]
    assert (iso / "iso.glb").exists() and (iso / "iso.obj").exists()

    code, events, err = engine.run("flow-export", {"params": {"volume": str(rec / "volume.npz")}}, tmp_path / "ex")
    assert code == 0 and (tmp_path / "ex" / "volume.vti").exists()


def test_reconstruct_reports_a_bad_calibration(engine, tmp_path):
    cal = synthetic.make_sweep(tmp_path / "s.mp4", frames=5)
    cal["spatial"] = {"mode": "points", "frames": []}
    code, events, _ = engine.run("flow-reconstruct", {"params": {"source": str(tmp_path / "s.mp4"), "calibration": cal}}, tmp_path / "job")
    assert code == 1 and events[-1]["type"] == "error"


# The object (no-fluid region) ----------------------------------------------

def test_object_surface_recovers_the_body(sweep):
    from aeroengine.flow.iso import object_surface

    _, _, vol, _ = sweep
    mesh = object_surface(vol, ground_z=None)
    assert mesh.triangle_count > 100
    lo, hi = mesh.positions.min(0), mesh.positions.max(0)
    x_end, half_y, z0, z1 = synthetic.BODY
    cell = vol.y[1] - vol.y[0]
    assert hi[0] == pytest.approx(x_end, abs=3 * (vol.x[1] - vol.x[0]))
    assert hi[1] == pytest.approx(half_y, abs=2 * cell) and lo[1] == pytest.approx(-half_y, abs=2 * cell)
    assert lo[2] == pytest.approx(z0, abs=2 * cell) and hi[2] == pytest.approx(z1, abs=2 * cell)
    exact = x_end * 2 * half_y * (z1 - z0)
    assert enclosed_volume(mesh) == pytest.approx(exact, rel=0.15)


def test_object_ignores_the_ground_slab(tmp_path):
    from aeroengine.flow.iso import object_surface

    cal = synthetic.make_sweep(tmp_path / "p.mp4", frames=21, perspective=True)
    # A window reaching below the ground, where the frames are white.
    cal["window"] = [-0.5, 0.5, -0.15, 0.6]
    vol, _ = reconstruct(tmp_path / "p.mp4", Calibration(cal))
    with_ground = object_surface(vol, ground_z=None)
    without = object_surface(vol, ground_z=0.0)
    assert without.positions[:, 2].min() > 0
    assert enclosed_volume(without) < enclosed_volume(with_ground)


def test_exclusions_and_frame_borders_are_not_solid(sweep):
    _, cal, vol, _ = sweep
    # Nothing outside the synthetic body (and ground) was drawn white.
    X, Y, Z = np.meshgrid(vol.x, vol.y, vol.z, indexing="ij")
    x_end, half_y, z0, z1 = synthetic.BODY
    # (The outermost cells sample the crop edge, which in the synthetic scene
    # is the white surround; object_surface drops that layer.)
    inner = (np.abs(Y) < synthetic.Y_HALF - 0.02) & (Z > 0.03) & (Z < synthetic.Z_TOP - 0.02)
    far_from_body = (X > x_end + 0.1) & inner
    assert vol.solid[far_from_body].sum() == 0


def test_flow_object_command(engine, tmp_path):
    cal = synthetic.make_sweep(tmp_path / "s.mp4", frames=21)
    rec = tmp_path / "rec"
    code, events, err = engine.run("flow-reconstruct", {"params": {"source": str(tmp_path / "s.mp4"), "calibration": cal}}, rec, timeout=180)
    assert code == 0, (events, err)
    code, events, err = engine.run("flow-object", {"params": {"volume": str(rec / "volume.npz")}}, tmp_path / "obj")
    assert code == 0, (events, err)
    data = json.loads((tmp_path / "obj" / "result.json").read_text())["data"]
    assert data["triangles"] > 0 and (tmp_path / "obj" / "object.glb").exists()
