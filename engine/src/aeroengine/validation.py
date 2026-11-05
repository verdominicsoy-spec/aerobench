"""The quick methods against RANS and against published wind-tunnel data.

The quick estimate is meant to match RANS, and so the STAR-CCM+ run that
follows it (Dominic's call): against_rans() holds it to the SU2 runs its
corrections were fitted to, within TARGET_LIFT. The wind-tunnel cases
below say how far the estimate, and the RANS it matches, sit from
measurement; they are not tuned to.

Each case is a section measured in a wind tunnel at a known Reynolds number,
with the model's coordinates as built where the source gives them. The
viscous core of the quick estimate (NeuralFoil, which is the whole estimate
for a single element) is run at the measured angles and compared:

- lift over the attached range (up to STALL_BACKOFF short of the measured
  maximum lift), as a fraction of the measured lift; below LIFT_FLOOR the
  error is taken against LIFT_FLOOR, so a 0.02 miss near zero lift counts
  as 5% and not as infinity;
- drag over the same range, as a fraction;
- maximum lift and the angle it comes at.

Sources (only public ones):

- NACA 0012 at Re 6 million, tripped: Ladson, NASA TM-4074 (1988), as the
  NASA Langley Turbulence Modeling Resource tabulates it. Public domain, in
  data/validation.
- S1223, E387 (model A) and FX 63-137 (model B) at Re 200,000 to 300,000,
  the range an FS wing runs at: Selig, Guglielmo, Broeren and Giguere,
  Summary of Low-Speed Airfoil Data, Volume 1 (SoarTech, 1995), the
  University of Illinois low-speed tests. Released with the GNU GPL and
  under the authors' terms of use, so it is fetched from the source at run
  time (into data/validation/downloads, not committed) and cited here.

No public multi-element or ground-effect tables were reachable when this
was written (the NLR 7301 data are on the ECARP CD-ROM; Zerihan and Zhang's
are in papers behind a bot check), so those are checked against RANS only;
see docs/DECISIONS.md."""

from __future__ import annotations

import io
import json
import re
import urllib.request
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from .job import EngineError
from .wing.airfoils import data_dir, naca

UIUC_VOLUME = "https://m-selig.ae.illinois.edu/pd/pub/lsat/volume{:02d}.zip"
UIUC_VOLUME1 = UIUC_VOLUME.format(1)
SURVEY_RE = (150e3, 520e3)  # the survey's Reynolds numbers: what an FS wing runs at
UIUC_SOURCE = ("M. S. Selig, J. J. Guglielmo, A. P. Broeren and P. Giguere, Summary of Low-Speed Airfoil Data, "
               "Volume 1, SoarTech Publications, 1995 (UIUC Low-Speed Airfoil Tests, m-selig.ae.illinois.edu)")
LIFT_FLOOR = 0.4  # below this measured |Cl| the lift error is taken against it
STALL_BACKOFF = 2.0  # degrees short of the measured maximum lift: the attached range
TARGET_LIFT = 0.05
TARGET_DRAG = 0.15


@dataclass
class Case:
    key: str
    name: str
    source: str
    re: float
    coords: np.ndarray  # Selig order, unit chord
    rows: list[tuple[float, float, float]]  # alpha (deg), cl, cd
    n_crit: float = 9.0
    xtr: float = 1.0  # forced transition, x/c (1: free)
    notes: list[str] = field(default_factory=list)


def downloads() -> Path:
    return data_dir() / "validation" / "downloads"


def fetch_uiuc(folder: Path | None = None, url: str = UIUC_VOLUME1, volume: int = 1) -> Path:
    """A UIUC volume's text files (volumes 1 to 3 share one format),
    downloaded once and kept."""
    v = f"{volume:02d}"
    if volume != 1 and url == UIUC_VOLUME1:
        url = UIUC_VOLUME.format(volume)
    folder = folder or downloads() / f"uiuc_volume{v}"
    if (folder / f"DRAG{v}.TXT").exists() and (folder / f"COORD{v}.TXT").exists():
        return folder
    try:
        with urllib.request.urlopen(url, timeout=60) as r:
            raw = r.read()
    except OSError as exc:
        raise EngineError("could not download the UIUC low-speed airfoil data", f"{url}: {exc}") from None
    folder.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(raw)) as z:
        for name in z.namelist():
            base = Path(name).name
            if base in (f"DRAG{v}.TXT", f"COORD{v}.TXT", "GPL.TXT", f"BOOK{v}.TXT"):
                (folder / base).write_bytes(z.read(name))
    if not (folder / f"DRAG{v}.TXT").exists():
        raise EngineError(f"the UIUC download did not hold DRAG{v}.TXT", url)
    return folder


def parse_coords(text: str) -> dict[str, np.ndarray]:
    """COORD01.TXT: blocks of '::::' / file name / '::::' / title / x y lines."""
    out: dict[str, np.ndarray] = {}
    parts = re.split(r"^:{6,}\s*$", text, flags=re.M)
    for name, body in zip(parts[1::2], parts[2::2]):
        pts = []
        for line in body.splitlines()[1:]:
            v = line.split()
            if len(v) == 2:
                try:
                    pts.append((float(v[0]), float(v[1])))
                except ValueError:
                    continue
        if len(pts) > 10:
            out[name.strip()] = np.asarray(pts, float)
    return out


def parse_runs(text: str) -> list[dict]:
    """DRAG01.TXT: per airfoil a name, builder and comment, then runs, each an
    average Reynolds number and rows of alpha, Cl, Cd (and spanwise Cds)."""
    runs: list[dict] = []
    airfoil = comment = ""
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith("Airfoil:"):
            airfoil = line.split(":", 1)[1].strip()
        elif line.startswith("Comment:"):
            comment = line.split(":", 1)[1].strip()
        elif line.startswith("Average Reynolds"):
            re_ = float(lines[i + 1].split()[0])
            rows = []
            j = i + 2
            while j < len(lines) and not lines[j].strip().startswith(("Tabulated", "Average", "Airfoil")):
                v = lines[j].split()
                if len(v) >= 3:
                    try:
                        rows.append((float(v[0]), float(v[1]), float(v[2])))
                    except ValueError:
                        pass
                j += 1
            runs.append({"airfoil": airfoil, "comment": comment, "re": re_, "rows": rows})
            i = j
            continue
        i += 1
    return runs


def _unit(xy: np.ndarray) -> np.ndarray:
    """Leading edge at the origin, unit chord (the files are already near it)."""
    le = xy[int(np.argmin(xy[:, 0]))]
    chord = float(xy[:, 0].max() - le[0])
    return (xy - le) / chord


# (airfoil as the drag file names it, coordinate file of the model tested, Reynolds numbers, key)
UIUC_CASES = [
    ("S1223", "s1223.dap", (200_000, 250_000, 300_000), "s1223"),
    ("E387 (A)", "e387a.dap", (200_000, 300_000), "e387"),
    ("FX 63-137 (B)", "fx63b.dap", (200_000, 250_000, 300_000), "fx63137"),
]


def ladson_case(path: Path | None = None) -> Case:
    path = path or data_dir() / "validation" / "naca0012_ladson.json"
    d = json.loads(path.read_text())
    rows = [tuple(r) for s in d["series"] for r in s["rows"]]
    return Case("naca0012", "NACA 0012", d["source"], float(d["reynolds"]), naca("0012"), sorted(rows), n_crit=9.0,
                xtr=0.05, notes=["tripped: forced transition at 5% chord on both surfaces is assumed for the grit strip",
                                 "the three grit sizes (80, 120, 180) pooled: their spread is the measurement's own"])


def uiuc_cases(folder: Path | None = None) -> list[Case]:
    folder = fetch_uiuc(folder)
    coords = parse_coords((folder / "COORD01.TXT").read_text(errors="replace"))
    runs = [r for r in parse_runs((folder / "DRAG01.TXT").read_text(errors="replace")) if r["comment"].lower() == "clean"]
    out = []
    for airfoil, coord_file, reynolds, key in UIUC_CASES:
        if coord_file not in coords:
            raise EngineError(f"no coordinates {coord_file} in the UIUC volume")
        unit = _unit(coords[coord_file])
        for target in reynolds:
            near = [r for r in runs if r["airfoil"] == airfoil and abs(r["re"] / target - 1) < 0.05]
            if not near:
                continue
            run = max(near, key=lambda r: len(r["rows"]))
            out.append(Case(f"{key}_{target // 1000}k", f"{airfoil.split(' (')[0]} at Re {run['re']:,.0f}",
                            UIUC_SOURCE, run["re"], unit, sorted(run["rows"]),
                            notes=[f"model {coord_file} (coordinates as built)", "free transition, Ncrit 9"]))
    return out


def _model(name: str, coords: dict[str, np.ndarray]) -> str | None:
    """The coordinate file of the model a run names ("E387 (A)" -> e387a.dap),
    else any as-built model of that section, else its design coordinates."""
    m = re.match(r"(.+?)\s*\((\w)\)$", name)
    base = (m.group(1) if m else name).lower().replace(" ", "").replace("-", "")
    cands = [k for k in coords if k.lower().replace("-", "").startswith(base)]
    return (next((k for k in cands if m and k.lower().endswith(f"{m.group(2).lower()}.dap")), None)
            or next((k for k in cands if k.endswith(".dap")), None) or next((k for k in cands if k.endswith(".dat")), None))


# The ten sections the accuracy window compares against, heavy camber to light
# (docs/superpowers/specs/2026-11-05-uiuc-validation-section-design.md):
# (airfoil as the drag file names it, volume, key).
UIUC_BENCHMARK = [
    ("S1223", 1, "s1223"), ("E423", 2, "e423"), ("S1210", 1, "s1210"), ("SG6043", 3, "sg6043"),
    ("SD7062 (B)", 3, "sd7062"), ("E387 (A)", 1, "e387"), ("SD7037 (B)", 1, "sd7037"),
    ("Clark-Y (B)", 3, "clarky"), ("SA7038", 3, "sa7038"), ("S8037", 3, "s8037"),
]
BENCHMARK_RE = 300_000  # an FS wing's Reynolds number


def pick_run(runs: list[dict], airfoil: str, target: float = BENCHMARK_RE) -> dict | None:
    """The airfoil's clean run (comment exactly "clean": never flapped or
    tripped) within 5% of target: the most angles, then the nearest Re."""
    near = [r for r in runs if r["airfoil"] == airfoil and r["comment"].strip().lower() == "clean"
            and abs(r["re"] / target - 1) < 0.05]
    return min(near, key=lambda r: (-len(r["rows"]), abs(r["re"] - target)), default=None)


def benchmark_cases(folders: dict[int, Path] | None = None) -> list[Case]:
    """The benchmark's cases, each on the tunnel model's coordinates as tested."""
    folders = folders or {}
    files: dict[int, tuple[list[dict], dict]] = {}
    out = []
    for airfoil, vol, key in UIUC_BENCHMARK:
        if vol not in files:
            folder, v = folders.get(vol) or fetch_uiuc(volume=vol), f"{vol:02d}"
            files[vol] = (parse_runs((folder / f"DRAG{v}.TXT").read_text(errors="replace")),
                          parse_coords((folder / f"COORD{v}.TXT").read_text(errors="replace")))
        runs, coords = files[vol]
        run, model = pick_run(runs, airfoil), _model(airfoil, coords)
        if run is None or model is None:
            raise EngineError(f"UIUC volume {vol} has no clean run near Re {BENCHMARK_RE:,} with coordinates for {airfoil}")
        out.append(Case(key, f"{airfoil.split(' (')[0]} at Re {run['re']:,.0f}",
                        f"UIUC low-speed airfoil tests, Summary of Low-Speed Airfoil Data, Volume {vol} (m-selig.ae.illinois.edu)",
                        run["re"], _unit(coords[model]), sorted(run["rows"]), notes=[f"volume {vol}", model]))
    return out


def _attached_to(case: Case) -> float:
    """The last measured angle that counts: STALL_BACKOFF short of the
    maximum lift, or every angle when the run stops before the lift peaks."""
    alphas = [r[0] for r in case.rows]
    k = int(np.argmax([r[1] for r in case.rows]))
    return alphas[k] - STALL_BACKOFF if k < len(alphas) - 1 else alphas[-1]


def errors(case: Case, alphas, cl, cd) -> dict:
    """Mean relative errors at the given tunnel angles over the attached
    range: lift against LIFT_FLOOR near zero lift, drag against itself."""
    measured = {r[0]: r for r in case.rows}
    upto = _attached_to(case)
    pts = [(measured[a], c, d) for a, c, d in zip(alphas, cl, cd) if a in measured and a <= upto]
    if not pts:
        return {"lift": None, "drag": None, "lift_signed": None}
    signed = np.array([(c - m[1]) / max(abs(m[1]), LIFT_FLOOR) for m, c, _ in pts])
    drag = np.array([abs(d - m[2]) / m[2] for m, _, d in pts])
    return {"lift": float(np.abs(signed).mean()), "drag": float(drag.mean()), "lift_signed": float(signed.mean())}


def rans_at_tunnel(case: Case, rans_rows) -> tuple[list, list, list]:
    """RANS at the tunnel's angles: linear between neighbouring converged
    angles, and nothing outside the converged range."""
    good = sorted((r[0], r[1], r[2]) for r in rans_rows if r[3])
    if not good:
        return [], [], []
    ra, rcl, rcd = (np.array(c) for c in zip(*good))
    a = [r[0] for r in case.rows if ra[0] <= r[0] <= ra[-1]]
    return a, [float(x) for x in np.interp(a, ra, rcl)], [float(x) for x in np.interp(a, ra, rcd)]


def survey(volumes=(1, 2, 3), progress=lambda pct, msg: None) -> dict:
    """The viscous core against every clean run in the UIUC volumes at FS
    Reynolds numbers: how far off it is across many sections, not one."""
    errors, sections, skipped = [], set(), []
    for n, vol in enumerate(volumes):
        try:
            folder = fetch_uiuc(volume=vol)
        except EngineError as exc:
            skipped.append(f"volume {vol}: {exc.msg}")
            continue
        v = f"{vol:02d}"
        coords = parse_coords((folder / f"COORD{v}.TXT").read_text(errors="replace"))
        runs = [r for r in parse_runs((folder / f"DRAG{v}.TXT").read_text(errors="replace"))
                if r["comment"].lower().startswith("clean") and SURVEY_RE[0] <= r["re"] <= SURVEY_RE[1] and len(r["rows"]) >= 8]
        for k, r in enumerate(runs):
            progress(100 * (n + k / max(len(runs), 1)) / len(volumes), f"volume {vol}: {r['airfoil']}")
            model = _model(r["airfoil"], coords)
            if not model:
                continue
            try:
                c = compare(Case(model, r["airfoil"], UIUC_SOURCE, r["re"], _unit(coords[model]), sorted(r["rows"])),
                            sweep_max=False)
            except EngineError:
                continue
            if c["lift_error_mean"] is None:
                continue
            sections.add(r["airfoil"].split(" (")[0])
            errors.append({"airfoil": r["airfoil"], "re": r["re"], "volume": vol, "lift": c["lift_error_mean"],
                           "lift_signed": c["lift_error_signed"], "drag": c["drag_error_mean"]})
    lift = np.array([e["lift"] for e in errors]) if errors else np.zeros(0)
    drag = np.array([e["drag"] for e in errors]) if errors else np.zeros(0)
    signed = np.array([e["lift_signed"] for e in errors]) if errors else np.zeros(0)
    return {"runs": len(errors), "sections": len(sections), "skipped": skipped, "errors": errors,
            "lift_median": float(np.median(lift)) if errors else None,
            "lift_signed_median": float(np.median(signed)) if errors else None,
            "lift_within_target": float(np.mean(lift <= TARGET_LIFT)) if errors else None,
            "lift_within_double": float(np.mean(lift <= 2 * TARGET_LIFT)) if errors else None,
            "drag_median": float(np.median(drag)) if errors else None,
            "drag_within_target": float(np.mean(drag <= TARGET_DRAG)) if errors else None}


def compare(case: Case, model_size: str = "large", sweep_max: bool = True) -> dict:
    """The viscous core at the measured angles, and its errors."""
    from .wing.viscous import polar

    alphas = np.array([r[0] for r in case.rows])
    cl_m, cd_m = np.array([r[1] for r in case.rows]), np.array([r[2] for r in case.rows])
    est = polar(case.coords, alphas, case.re, case.n_crit, model_size=model_size, xtr=case.xtr)["rows"]
    cl_e, cd_e = np.array([r["cl"] for r in est]), np.array([r["cd"] for r in est])
    k_max = int(np.argmax(cl_m))
    # A run that stops before the lift peaks never stalled: all of it counts.
    peaked = k_max < len(alphas) - 1
    attached = alphas <= alphas[k_max] - STALL_BACKOFF if peaked else np.ones(len(alphas), bool)
    lift_err = np.abs(cl_e - cl_m) / np.maximum(np.abs(cl_m), LIFT_FLOOR)
    drag_err = np.abs(cd_e - cd_m) / cd_m
    means = errors(case, alphas.tolist(), cl_e.tolist(), cd_e.tolist())
    # The estimate's own maximum lift, on a fine sweep past the measured range.
    fine = np.arange(alphas.min(), alphas.max() + 4.0, 0.25) if sweep_max else alphas
    sweep = polar(case.coords, fine, case.re, case.n_crit, model_size=model_size, xtr=case.xtr)["rows"] if sweep_max else est
    j = int(np.argmax([r["cl"] for r in sweep]))
    a = attached
    return {
        "key": case.key, "name": case.name, "source": case.source, "re": case.re, "notes": case.notes,
        "rows": [{"alpha": float(al), "cl": float(m), "cl_estimate": float(e), "cd": float(dm), "cd_estimate": float(de),
                  "attached": bool(at)} for al, m, e, dm, de, at in zip(alphas, cl_m, cl_e, cd_m, cd_e, attached)],
        "attached_to": float(alphas[k_max] - STALL_BACKOFF if peaked else alphas[-1]), "stalled": bool(peaked),
        "lift_error_mean": means["lift"],
        "lift_error_max": float(lift_err[a].max()) if a.any() else None,
        "lift_error_signed": means["lift_signed"],  # + reads high
        "drag_error_mean": means["drag"],
        "drag_error_max": float(drag_err[a].max()) if a.any() else None,
        # Measured maximum lift only when the run went past it.
        "cl_max": float(cl_m[k_max]) if peaked else None, "alpha_cl_max": float(alphas[k_max]) if peaked else None,
        "cl_max_estimate": float(sweep[j]["cl"]), "alpha_cl_max_estimate": float(fine[j]),
        "lift_ok": bool(a.any() and lift_err[a].mean() <= TARGET_LIFT),
        "drag_ok": bool(a.any() and drag_err[a].mean() <= TARGET_DRAG),
    }


# The estimate against SU2 RANS (Spalart-Allmaras, quick mesh, 15 m/s) on the
# NACA 6212 main-and-flap starting wing that the design search lays out: the
# runs its corrections were fitted to and checked on. The estimate is meant
# to match RANS (and so the STAR-CCM+ run that follows it), not the tunnel.
# (name, wing angle, ride height m or None, design values or None, RANS Cl, Cd, or None if RANS never settled)
RANS_REFERENCES = [
    ("starting wing, 0°", 0.0, None, None, -2.1677, 0.03468),
    ("starting wing, 0°, SST (STAR-CCM+'s usual model)", 0.0, None, None, -2.1058, 0.03451),
    ("starting wing, -3°", -3.0, None, None, -2.4104, 0.04433),
    ("starting wing, -6°", -6.0, None, None, -2.5037, 0.06419),
    ("starting wing, -9°", -9.0, None, None, None, None),
    ("300 mm over a ground", 0.0, 0.30, None, -2.8274, 0.04758),
    ("150 mm over a ground", 0.0, 0.15, None, -3.4836, 0.07074),
    ("60 mm over a ground", 0.0, 0.06, None, None, None),
    ("design check (main 7.3°, flap 32.1°, 21 mm gap)", 0.0, None,
     {"angle_0": 7.2759, "angle_1": 32.0653, "gap_1": 0.0213, "overlap_1": 0.0073}, -2.4377, 0.05448),
]


def against_rans() -> dict:
    """The estimate against the RANS reference runs: lift and drag errors
    where RANS converged, and whether the estimate called the rest separating."""
    from .wing.airfoils import naca4
    from .wing.design import layout
    from .wing.estimate import estimate
    from .wing.geometry import apply

    base = layout([naca4("6212")] * 2, 0.44, True)
    out = []
    for name, alpha, height, values, cl, cd in RANS_REFERENCES:
        w = apply(base, values) if values else base
        els = [{"coords": e.placed().tolist(), "unit": e.unit.tolist(), "chord": e.chord, "angle": e.angle,
                "inverted": e.inverted} for e in w.elements]
        r = estimate(els, [alpha], 15.0, ride_height=height)["rows"][0]
        row = {"name": name, "cl_rans": cl, "cd_rans": cd, "cl": r["cl"], "cd": r["cd"], "separating": r["separating"],
               "why": r["why"]}
        if cl is not None:
            row["lift_error"] = abs(r["cl"] / cl - 1)
            row["drag_error"] = abs(r["cd"] / cd - 1)
        row["agrees"] = (not r["separating"] and row["lift_error"] <= TARGET_LIFT) if cl is not None else r["separating"]
        out.append(row)
    held = [x for x in out if x["cl_rans"] is not None]
    return {"cases": out, "lift_error_max": max(x["lift_error"] for x in held),
            "drag_error_max": max(x["drag_error"] for x in held), "all_agree": all(x["agrees"] for x in out)}


def run(keys: list[str] | None = None, progress=lambda pct, msg: None, uiuc_folder: Path | None = None,
        with_survey: bool = True) -> dict:
    cases = [ladson_case()]
    skipped = []
    try:
        cases += uiuc_cases(uiuc_folder)
    except EngineError as exc:
        skipped.append(f"UIUC cases: {exc.msg}" + (f" ({exc.detail})" if exc.detail else ""))
    if keys:
        cases = [c for c in cases if c.key in keys or c.key.split("_")[0] in keys]
    results = []
    for k, c in enumerate(cases):
        progress(100 * k / max(len(cases), 1), f"{c.name}")
        results.append(compare(c))
    out = {"cases": results, "skipped": skipped, "targets": {"lift": TARGET_LIFT, "drag": TARGET_DRAG},
           "lift_floor": LIFT_FLOOR, "stall_backoff": STALL_BACKOFF}
    if not keys:
        out["rans"] = against_rans()
    if with_survey and not keys:
        out["survey"] = survey(progress=lambda pct, msg: progress(50 + pct / 2, msg))
    return out
