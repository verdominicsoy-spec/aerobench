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
    body = (X < synthetic.BODY[0]) & (np.abs(Y) < synthetic.BODY[1]) & (Z > synthetic.BODY[2]) & (Z < synthetic.BODY[3])
    near_body = binary_dilation(body, iterations=2)
    edge = (np.abs(Y) > synthetic.Y_HALF - 0.02) | (Z < 0.02) | (Z > synthetic.Z_TOP - 0.02) | \
           (X < synthetic.X0 + 0.02) | (X > synthetic.X1 - 0.02)
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
    # The crop reaches below the ground (for ground tracking), so cut there.
    mesh = object_surface(vol, ground_z=0.0)
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


# Views, ground tracking and detail ------------------------------------------------

def _max_error(vol: Volume) -> float:
    truth, ok = _clean_region(vol)
    rec = vol.values[ok]
    assert np.isfinite(rec).mean() > 0.99
    return float(np.nanmax(np.abs(rec - np.clip(truth[ok], -1, 1))))


# The rear view looks along -x, so the body and the narrowest wake are at the
# far, smallest end of the sweep (about 4 mm a pixel): the steepest part of the
# wake core blurs there, though 99.9% of cells stay within 1.6%.
@pytest.mark.parametrize("view, tolerance", [("rear", 0.05), ("side", 0.03)])
def test_other_perpendicular_views(tmp_path, view, tolerance):
    cal = synthetic.make_sweep(tmp_path / "v.mp4", frames=61, view=view, perspective=True)
    vol, _ = reconstruct(tmp_path / "v.mp4", Calibration(cal))
    assert vol.sweep_axis == ("y" if view == "side" else "x")
    assert np.all(np.diff(vol.x) > 0) and np.all(np.diff(vol.y) > 0) and np.all(np.diff(vol.z) > 0)
    assert _max_error(vol) <= tolerance * RANGE


def test_ground_tracking_needs_one_frame_and_beats_a_misclicked_second(tmp_path):
    cal = synthetic.make_sweep(tmp_path / "p.mp4", frames=61, perspective=True)
    # The second calibration frame clicked 4 px too high: the planes drift.
    sloppy = json.loads(json.dumps(cal))
    for pt in sloppy["spatial"]["frames"][1]["points"]:
        pt["px"][1] -= 4
    drifted, _ = reconstruct(tmp_path / "p.mp4", Calibration(sloppy))
    # Ground tracking with only the first frame calibrated.
    tracked_cal = json.loads(json.dumps(cal))
    tracked_cal["spatial"]["frames"] = tracked_cal["spatial"]["frames"][:1]
    tracked_cal["ground"] = {"track": True}
    tracked, summary = reconstruct(tmp_path / "p.mp4", Calibration(tracked_cal))
    assert summary["ground"]["camera"] == "pinhole"
    assert summary["ground"]["residual_median_px"] < 1.0
    assert _max_error(tracked) <= 0.03 * RANGE
    assert _max_error(tracked) < _max_error(drifted)


def test_ground_tracking_on_a_fixed_camera(tmp_path):
    cal = synthetic.make_sweep(tmp_path / "o.mp4", frames=31)
    cal["ground"] = {"track": True}
    vol, summary = reconstruct(tmp_path / "o.mp4", Calibration(cal))
    assert summary["ground"]["camera"] == "constant"
    assert _max_error(vol) <= 0.03 * RANGE


def test_ground_fit_recovers_a_pinhole_camera():
    from aeroengine.flow.reconstruct import fit_ground

    rng = np.random.default_rng(3)
    for d, vh, k, a in [(1, 540.0, 184000.0, 386.0), (-1, 300.0, 50000.0, 600.0)]:
        f = np.arange(0, 300, 5, dtype=float)
        rows = vh + k / (a + d * f) + rng.normal(0, 0.5, f.size)
        rows[7] += 40  # one outlier (the car touching the ground)
        kind, fit, resid = fit_ground(f, rows)
        assert kind == "pinhole" and fit[3] == d
        pred = fit[0] + fit[1] / (fit[2] + d * f)
        truth = vh + k / (a + d * f)
        assert np.max(np.abs(pred - truth)) < 1.0


def test_detail_sets_the_cell_size(tmp_path):
    cal = synthetic.make_sweep(tmp_path / "d.mp4", frames=21)
    low, s_low = reconstruct(tmp_path / "d.mp4", Calibration({**cal, "detail": "low"}))
    high, s_high = reconstruct(tmp_path / "d.mp4", Calibration({**cal, "detail": "high"}))
    # About 1.5 px of the 600 px/m frames: 2.5 mm, unless the voxel budget says otherwise.
    assert s_high["cell_mm"] == pytest.approx(2.5, rel=0.05)
    assert s_low["cell_mm"] >= s_high["cell_mm"]
    assert low.values.size <= 8_000_000 * 1.05


# Detection, square pixels, plane positions from the camera -------------------

@pytest.mark.parametrize("perspective", [True, False])
def test_detect_finds_the_calibration_a_person_would_draw(tmp_path, perspective):
    from aeroengine.flow.detect import detect
    from aeroengine.flow.reconstruct import FrameSource

    cal = synthetic.make_sweep(tmp_path / "s.mp4", frames=41, perspective=perspective)
    found = detect(FrameSource(tmp_path / "s.mp4"), {})
    assert found["found"] and found["ground_visible"]
    # The plot region, and a strip below the ground for tracking.
    assert np.allclose(found["crop"], cal["crop"], atol=6)
    # The legend sits outside the plot here, so nothing needs excluding...
    assert found["exclude"] == []
    # ...but its bar is found, low end first.
    legend = found["legend"]
    assert legend["p0"][0] == pytest.approx(630, abs=2) and legend["p1"][0] == pytest.approx(930, abs=2)
    assert legend["p0"][1] == pytest.approx(legend["p1"][1])


def test_detected_calibration_reconstructs(tmp_path):
    from aeroengine.flow.detect import detect
    from aeroengine.flow.reconstruct import FrameSource

    cal = synthetic.make_sweep(tmp_path / "s.mp4", frames=41, perspective=True)
    found = detect(FrameSource(tmp_path / "s.mp4"), {})
    auto = {**cal, "crop": found["crop"], "exclude": found["exclude"],
            "colormap": {"legend": {k: found["legend"][k] for k in ("frame", "p0", "p1", "half_width")}},
            "ground": {"track": True}}
    auto["spatial"] = {"mode": "points", "frames": cal["spatial"]["frames"][:1]}
    vol, summary = reconstruct(tmp_path / "s.mp4", Calibration(auto))
    # The sampled legend has to match the plot's colours closely, not just
    # within the rejection threshold (decoders differ a little).
    assert summary["median_dE"] < 3
    assert _max_error(vol) <= 0.04 * RANGE


def test_detect_excludes_an_overlay_on_the_flow(tmp_path):
    from aeroengine.flow.detect import detect
    from aeroengine.flow.reconstruct import FrameSource

    cal = synthetic.make_sweep(tmp_path / "s.mp4", frames=31, perspective=True)
    # Burn a static label into the middle of the plot, as STAR does with titles.
    import cv2

    src = FrameSource(tmp_path / "s.mp4")
    out = tmp_path / "frames"
    out.mkdir()
    for i, f in src.frames(list(range(src.count))):
        f = f.copy()
        f[100:130, 300:420] = 255
        cv2.putText(f, "Cp0", (310, 125), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 0, 0), 2)
        cv2.imwrite(str(out / f"{i:04d}.png"), f[:, :, ::-1])
    found = detect(FrameSource(out), {})
    assert any(x0 <= 300 and y0 <= 100 and x1 >= 420 and y1 >= 130 for x0, y0, x1, y1 in found["exclude"])
    assert np.allclose(found["crop"], cal["crop"], atol=6)


def test_crop_size_keeps_pixels_square(tmp_path):
    base = {"crop": [0, 0, 200, 100], "planes": {"start": 0, "end": 1}}
    cal = Calibration({**base, "spatial": {"mode": "size", "width": 2.0}})
    s = cal.scale_at(0)
    assert s.sx == s.sy == pytest.approx(100)
    Calibration({**base, "spatial": {"mode": "size", "width": 2.0, "height": 1.0}})  # agrees
    with pytest.raises(EngineError, match="1000 mm tall"):
        Calibration({**base, "spatial": {"mode": "size", "width": 2.0, "height": 1.5}})


# The synthetic perspective camera: focal length s0 * distance = 900 px on a
# 540 px tall frame.
SYNTH_VIEW_ANGLE = float(np.degrees(2 * np.arctan(270 / 900)))


def test_reconstruct_reports_the_implied_camera(tmp_path):
    cal = synthetic.make_sweep(tmp_path / "p.mp4", frames=41, perspective=True)
    cal["ground"] = {"track": True}
    cal["spatial"]["frames"] = cal["spatial"]["frames"][:1]
    _, summary = reconstruct(tmp_path / "p.mp4", Calibration(cal))
    cam = summary["ground"]["implied_camera"]
    assert cam["view_angle_vertical_deg"] == pytest.approx(SYNTH_VIEW_ANGLE, abs=0.5)
    assert cam["distance_to_first_plane_m"] == pytest.approx(1.5, rel=0.03)
    assert cam["planes_run_away_from_camera"]
    # Plane positions entered the wrong way round show up.
    cal["planes"]["start"], cal["planes"]["end"] = cal["planes"]["end"], cal["planes"]["start"]
    _, summary = reconstruct(tmp_path / "p.mp4", Calibration(cal))
    assert not summary["ground"]["implied_camera"]["planes_run_away_from_camera"]


def test_plane_positions_from_the_camera(tmp_path):
    cal = synthetic.make_sweep(tmp_path / "p.mp4", frames=41, perspective=True)
    truth_start, truth_end = cal["planes"]["start"], cal["planes"]["end"]
    cal["ground"] = {"track": True}
    cal["spatial"]["frames"] = cal["spatial"]["frames"][:1]
    cal["planes"] = {"mode": "camera", "start": truth_start, "view_angle": SYNTH_VIEW_ANGLE}
    vol, _ = reconstruct(tmp_path / "p.mp4", Calibration(cal))
    # The far end hangs on the ground line's few pixels below the horizon
    # there (about 80 px), so allow 2% of the sweep.
    span = abs(truth_end - truth_start)
    assert vol.x[0] == pytest.approx(min(truth_start, truth_end), abs=0.02 * span)
    assert vol.x[-1] == pytest.approx(max(truth_start, truth_end), abs=0.02 * span)
    assert _max_error(vol) <= 0.04 * RANGE


def test_camera_planes_need_tracking():
    with pytest.raises(EngineError, match="ground tracking"):
        Calibration({"crop": [0, 0, 100, 100], "spatial": {"mode": "size", "width": 1},
                     "planes": {"mode": "camera", "start": 0, "view_angle": 30}})


@pytest.mark.parametrize("bands, worst", [(16, 9.0), (32, 2.0), (None, 4.5)])
def test_legend_sampling_reaches_the_map_ends(bands, worst):
    """A banded legend shows band-centre colours, but the field is drawn out
    to the map's end colours (clipped values); sampling extends half a band
    beyond the last centres. Without that the red end of a 16-band STAR map is
    22 dE off, past the 12 dE rejection threshold. A smooth legend's ends are
    its own."""
    cmap = colormap.preset("star_blue_yellow_red")
    width = 320
    t = (np.arange(width) + 0.5) / width
    shown = t if bands is None else (np.floor(t * bands) + 0.5) / bands
    strip = cmap[np.round(shown * (len(cmap) - 1)).astype(int)]
    img = np.full((40, width + 40, 3), 255, np.uint8)
    img[10:30, 20:20 + width] = (strip * 255).round().astype(np.uint8)
    prof = colormap.sample_legend(img, [20.5, 20], [20 + width - 0.5, 20], half_width=4)
    ends = (np.array([[prof[0], prof[-1]]]) * 255).round().astype(np.uint8)
    low = colormap.lab_distance(ends, cmap[0] * 255)[0, 0]
    high = colormap.lab_distance(ends, cmap[-1] * 255)[0, 1]
    assert max(low, high) < worst, (low, high)


@pytest.mark.parametrize("view", ["front", "rear", "side"])
def test_detect_reads_the_axis_triad(tmp_path, view):
    from aeroengine.flow.detect import detect

    cal = synthetic.make_sweep(tmp_path / "t.mp4", frames=15, perspective=True, view=view)
    found = detect(FrameSource(tmp_path / "t.mp4"), {})
    assert found["axes"] == cal["axes"]
    assert "triad_box" in found and len(found["triad_box"]) == 4


def test_triad_needs_two_arrows():
    from aeroengine.flow.detect import read_triad

    img = np.full((100, 100, 3), 255, np.uint8)
    import cv2

    cv2.arrowedLine(img, (50, 50), (90, 50), (30, 190, 30), 3, tipLength=0.35)  # only y, pointing right
    assert read_triad(img, (0, 0, 100, 100)) is None
    cv2.arrowedLine(img, (50, 50), (50, 10), (30, 30, 220), 3, tipLength=0.35)  # z up
    assert read_triad(img, (0, 0, 100, 100)) == {"right": "+y", "up": "+z"}


def test_one_frame_tracking_with_the_camera_off_the_axis_origin(tmp_path):
    """In a side view the camera sits partway along the car, so planes shrink
    towards the frame's centre, not towards x = 0: the sideways position has
    to follow the vanishing point, not stay put."""
    cal = synthetic.make_sweep(tmp_path / "s.mp4", frames=41, perspective=True, view="side")
    cal["ground"] = {"track": True}
    cal["spatial"]["frames"] = cal["spatial"]["frames"][:1]
    vol, summary = reconstruct(tmp_path / "s.mp4", Calibration(cal))
    # Two calibrated frames reach 2.9% here; the worst cells for both are in
    # the steep wake core at the far planes.
    truth, ok = _clean_region(vol)
    err = np.abs(vol.values[ok] - np.clip(truth[ok], -1, 1))
    report = (f"max {np.nanmax(err) / RANGE:.1%}, 99.9% {np.nanpercentile(err, 99.9) / RANGE:.1%}, "
              f"dE {summary['median_dE']:.2f}, ground {summary['ground']}")
    assert _max_error(vol) <= 0.04 * RANGE, report


def test_auto_region_spends_the_cells_on_the_flow(tmp_path):
    cal = synthetic.make_sweep(tmp_path / "a.mp4", frames=41, perspective=True)
    cal["detail"] = "low"
    everything, s_all = reconstruct(tmp_path / "a.mp4", Calibration({**cal, "extent": "all"}))
    auto, s_auto = reconstruct(tmp_path / "a.mp4", Calibration({**cal, "extent": "auto"}))
    # The wake and body sit inside a smaller box, so its cells are finer...
    assert s_auto["cell_mm"] < s_all["cell_mm"]
    # ...and nothing that is not free stream is cut off.
    X, Y, Z = np.meshgrid(everything.x, everything.y, everything.z, indexing="ij")
    busy = np.isfinite(everything.values) & (everything.values < 0.9)
    assert Y[busy].min() >= auto.y[0] and Y[busy].max() <= auto.y[-1]
    assert Z[busy].max() <= auto.z[-1]
    assert _max_error(auto) <= 0.04 * RANGE


def test_planes_are_spaced_like_the_cells(tmp_path):
    cal = synthetic.make_sweep(tmp_path / "p.mp4", frames=121, perspective=True)
    # Planes typed 0.4 mm apart, much closer than low detail's cells (about
    # 3 mm): not every frame is worth a plane. (Wrong positions for this
    # video, but the spacing is all this checks.)
    cal["planes"].update(start=0.0, end=0.05)
    vol, summary = reconstruct(tmp_path / "p.mp4", Calibration({**cal, "detail": "low"}))
    assert summary["plane_step"] > 1
    assert len(vol.x) == len(range(0, 121, summary["plane_step"]))
    spacing = (vol.x[-1] - vol.x[0]) / (len(vol.x) - 1)
    assert spacing <= summary["cell_mm"] / 1000 * 1.01
