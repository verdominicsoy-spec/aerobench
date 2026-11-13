"""One RANS run of a multi-element wing: laminar zones, mesh, SU2, surface Cp.
Used by the wing-rans command and by every optimiser trial."""

from __future__ import annotations

import csv
from pathlib import Path
from typing import Callable

import numpy as np

from ..job import EngineError, check_air
from . import su2
from .mesh import Settings, build
from .viscous import check_re, polar, reynolds

MESH_LEVELS = {  # surface and wake spacing scale, wall layer growth
    "quick": (1.6, 1.2),
    "coarse": (1.6, 1.2),
    "medium": (1.0, 1.15),
    "fine": (0.6, 1.1),
}


# The quick level answers to three figures: lift and drag still for 0.1%
# over 100 iterations and the residual down 3 orders, rather than 0.01% over
# 200 and 4 orders.
CONVERGENCE = {"quick": {"tolerance": 1e-3, "window": 100, "residual_drop": 3.0}}


def solve(p: dict, workdir: Path, mesh_file: Path, su2_hint: str | None, cores: int, env: dict | None,
          progress: Callable[[float, str], None], log: Callable[..., None], field: bool = True,
          mesh_ready: dict | None = None, restart: Path | None = None) -> dict:
    """p holds elements (coords placed in m, unit, angle, inverted, chord),
    speed, rho, mu, alpha, model, mesh level, transition and the rest of the
    wing-rans parameters. The mesh goes to mesh_file, SU2's files to workdir.
    mesh_ready: mesh_file already holds this wing's mesh (its statistics and
    transition zones, from an earlier solve), so it is not built again.
    restart: start SU2 from this solution (same mesh) rather than from rest."""
    raw = p.get("elements")
    if not isinstance(raw, list) or not raw:
        raise EngineError("params.elements must list the elements: coords (placed, m), unit, angle, inverted, chord")
    placed = [np.asarray(e["coords"], float) for e in raw]
    inverted = [bool(e.get("inverted", False)) for e in raw]
    chords = [float(e["chord"]) for e in raw]
    speed, rho, mu = float(p.get("speed", 15)), float(p.get("rho", 1.225)), float(p.get("mu", 1.81e-5))
    check_air(rho, mu)
    alpha = float(p.get("alpha", 0.0))
    # A ground must lie along the flow: the wing is turned by its angle instead
    # (as in the estimate) and the flow runs along x over a slip wall that far
    # below the wing's lowest point.
    ground = None
    flow_alpha = alpha
    if p.get("ride_height") is not None:
        from .estimate import in_ground_effect

        height = float(p["ride_height"])
        if not height > 0:
            raise EngineError("the ride height must be above zero")
        placed, ground = in_ground_effect(placed, alpha, height)
        flow_alpha = 0.0
    ref_chord = float(p.get("ref_chord", sum(chords)))
    model = str(p.get("model", su2.DEFAULT_MODEL))
    if model not in su2.MODELS:
        raise EngineError(f"unknown model '{model}'", f"one of {', '.join(su2.MODELS)}")
    level = str(p.get("mesh", "fine"))  # extra-fine moves lift and drag under 3%
    if level not in MESH_LEVELS:
        raise EngineError(f"mesh must be one of {', '.join(MESH_LEVELS)}")
    re_ref = reynolds(speed, ref_chord, rho, mu)

    # Laminar zones: typed per element, or predicted by the quick viscous
    # solver at each element's own angle, in isolation.
    transition = p.get("transition", "auto")
    zones = []
    if mesh_ready is not None:
        zones = [tuple(z) for z in mesh_ready["transition"]]
    elif transition == "auto":
        progress(2, "predicting where each element's flow turns turbulent")
        for e, c in zip(raw, chords):
            sense = -1 if e.get("inverted") else 1
            a = float(e.get("angle", 0)) + sense * alpha
            row = polar(np.asarray(e["unit"], float), [a], reynolds(speed, c, rho, mu),
                        float(p.get("n_crit", 9.0)), bool(e.get("inverted", False)))["rows"][0]
            zones.append((row["transition_suction"], row["transition_pressure"]))
    elif isinstance(transition, list) and len(transition) == len(raw):
        for c in chords:  # before any meshing, as polar() does for "auto"
            check_re(reynolds(speed, c, rho, mu))
        zones = [(float(t[0]), float(t[1])) for t in transition]
    else:
        raise EngineError("params.transition must be \"auto\" or one [suction, pressure] pair per element")
    if model in ("sa", "sst") and transition == "auto" and mesh_ready is None:
        log("fully turbulent model: the laminar zones only refine the mesh there")

    scale, growth = MESH_LEVELS[level]
    settings = Settings(re=re_ref, ref_chord=ref_chord, surface_fine=0.0025 * scale, surface_coarse=0.008 * scale,
                        edge=0.0015 * scale, wake_size=0.01 * scale, growth=growth, alpha_deg=flow_alpha,
                        transition=zones, ground=ground)
    if mesh_ready is not None:
        mesh = mesh_ready["mesh"]
    else:
        progress(5, "meshing")
        if ground is None:
            settings.alpha_deg = float(p.get("wake_alpha", alpha))  # a sweep aligns the wakes with its middle angle
        mesh = build(placed, settings, mesh_file, inverted)
        log(f"mesh: {mesh['cells']} cells ({mesh['quads']} quads, {mesh['triangles']} triangles), "
            f"{mesh['layers']} wall layers")
    if p.get("mesh_only"):  # wing-mesh: the mesh to look at, no SU2
        return {"mesh": mesh, "mesh_level": level, "transition": zones, "mesh_file": mesh_file.name,
                "frame_turn": -alpha if ground is not None else 0.0}
    ref_point = p.get("ref_point")
    if ref_point is None:
        main = placed[0]
        half = (len(main) - 1) // 2
        le, te = main[half], 0.5 * (main[0] + main[-1])
        ref_point = (le + 0.25 * (te - le)).tolist()
    case = su2.Case(speed=speed, rho=rho, mu=mu, alpha_deg=flow_alpha, ref_chord=ref_chord, ground=ground is not None,
                    ref_point=(float(ref_point[0]), float(ref_point[1])), walls=[f"wall_{i}" for i in range(len(raw))],
                    model=model, turbulence_intensity=float(p.get("turbulence_intensity", 0.01)),
                    iterations=int(p.get("iterations", 4000)), restart=str(restart) if restart else None,
                    **CONVERGENCE.get(level, {}))
    result = su2.run(case, mesh_file, workdir, su2.find_su2(su2_hint), cores=cores,
                     progress=lambda pct, msg: progress(10 + 0.88 * pct, msg), env=env)
    result.pop("history_columns", None)
    surface = surface_cp(workdir / "surface.csv", placed)
    separated, why, wall_y_plus, tu, found = False, None, None, None, None
    if (workdir / "flow.vtu").exists():
        try:
            cf_by_element = surface_cf(wall_points(workdir / "flow.vtu"), placed)
            found = regions(cf_by_element, inverted)
            separated, why = separation(found)
            surface = add_cf(surface, cf_by_element)
        except Exception as exc:  # noqa: BLE001 - the run's numbers stand without the verdict
            log(f"no separation check: {exc}", level="warning")
        try:
            wall_y_plus = y_plus(workdir / "flow.vtu")
        except Exception as exc:  # noqa: BLE001 - the run's numbers stand without it
            log(f"no y+ check: {exc}", level="warning")
        if model != "sa":
            try:
                tu = tu_at_wing(workdir / "flow.vtu", placed, flow_alpha, ref_chord)
                if tu < 0.8 * case.turbulence_intensity:
                    log(f"turbulence at the wing {tu:.2%}, set {case.turbulence_intensity:.2%}", level="warning")
            except Exception as exc:  # noqa: BLE001 - the run's numbers stand without it
                log(f"no turbulence check: {exc}", level="warning")
    if not result["converged"]:
        log(f"not converged: {result['reason']}", level="warning")
    cd_laminar = None  # a transition model has its laminar runs already
    if model in ("sa", "sst") and zones:
        cd_laminar = result["cd"] - laminar_saving(zones, chords, ref_chord, [reynolds(speed, c, rho, mu) for c in chords])
    view = None
    if field and (workdir / "flow.vtu").exists():
        from .field import extract

        progress(98, "sampling the flow field")
        try:
            extract(workdir / "flow.vtu", placed, workdir)
            view = "field.json"
        except Exception as exc:  # noqa: BLE001 - the run's numbers stand without the picture
            log(f"no field view: {exc}", level="warning")
    # frame_turn: degrees the wing was turned before meshing (over a ground,
    # by minus its angle): the surface and field are in that turned frame.
    return {"alpha": alpha, "frame_turn": -alpha if ground is not None else 0.0,
            "re": re_ref, "mesh": mesh, "mesh_level": level, "transition": zones, "model": model,
            "model_name": su2.MODELS[model], **result, "cd_laminar": cd_laminar, "surface": surface, "separated": separated, "separation": why, "regions": found,
            "y_plus": wall_y_plus, "tu_at_wing": tu, "rans_version": su2.RANS_VERSION,
            "field": "flow.vtu" if (workdir / "flow.vtu").exists() else None, "field_view": view}


def laminar_saving(zones: list, chords: list[float], ref_chord: float, res: list[float]) -> float:
    """Drag coefficient a fully turbulent model adds by having no laminar runs:
    over each surface's run to its transition point, turbulent less laminar
    flat-plate friction (Schlichting's 0.074 / Re^0.2, Blasius's 1.328 / Re^0.5).
    No fitted constants. On ten UIUC sections at Re 300,000, SST's 45% high drag
    becomes 20% high; the NLR 7301 at 6 degrees goes from 21% to 6%.
    shortcut: flat-plate, so high-camber sections stay 20 to 55% high; replace with a transition model that converges."""
    def one(x: float, re: float) -> float:
        rx = re * x
        return x * (0.074 / rx**0.2 - 1.328 / rx**0.5) if x > 2e-3 else 0.0
    return sum((one(s, re) + one(p, re)) * c / ref_chord for (s, p), c, re in zip(zones, chords, res))


def y_plus(vtu: Path) -> dict | None:
    """The wall cells' y+ as SU2 reports it (zero away from the walls): the
    largest, the 95th percentile and the mean over the wall points. The mesh
    aims its first cell at y+ 1 from a flat-plate estimate; suction peaks run
    faster than that, so this says how close it came."""
    from .field import _read_vtu

    _, _, arrays = _read_vtu(vtu)
    yp = arrays.get("Y_Plus")
    if yp is None:
        return None
    wall = np.asarray(yp, float).ravel()
    wall = wall[wall > 0]
    if wall.size == 0:
        return None
    return {"max": round(float(wall.max()), 3), "p95": round(float(np.percentile(wall, 95)), 3),
            "mean": round(float(wall.mean()), 3)}


def tu_at_wing(vtu: Path, placed: list[np.ndarray], flow_alpha: float, ref_chord: float) -> float:
    """Turbulence intensity sqrt(2k/3)/|V| half a reference chord ahead of the
    most forward leading edge, along the flow. SU2 writes k and V nondimensional
    (INC_NONDIM= INITIAL_VALUES), so their ratio needs no scaling."""
    from .field import _read_vtu

    pts, _, arrays = _read_vtu(vtu)
    nose = min((e[int(np.argmin(e[:, 0]))] for e in placed), key=lambda q: q[0])
    a = np.radians(flow_alpha)
    at = nose - 0.5 * ref_chord * np.array([np.cos(a), np.sin(a)])
    i = int(np.argmin(np.linalg.norm(pts[:, :2] - at, axis=1)))
    k = float(np.asarray(arrays["Turb_Kin_Energy"])[i])
    v = float(np.linalg.norm(np.asarray(arrays["Velocity"])[i, :2]))
    return float(np.sqrt(2 * k / 3) / v)


# Reversed flow is reported region by region. A run reaching the trailing edge
# (TRAILING_EDGE: the last few % read positive in the trailing-edge corner) is
# trailing-edge separation; one starting at the nose (within NOSE of the
# stagnation point) is a leading-edge bubble, or a leading-edge stall when it
# reaches the trailing edge or runs past STALL_LENGTH of the chord before it
# closes; anything else that closes is a bubble. The wing counts as separated
# on any leading-edge stall or a trailing-edge separation longer than
# SEPARATED_SHARE: shorter ones barely move the load (a NACA 4412 main alone,
# SA quick mesh, 100 mm ride height: reversed from 93%, Cd 0.022) and still
# show in the regions. frontwing#1 (12 Nov 2026) is the case the old check (95% to
# 15% only, the first 5% skipped) got wrong: Flap 3 reversed from 85%, and at
# +10 deg the main reversed 1-91% on its pressure surface, both missed.
# Converged is not attached: the stalled study wing converged.
SEPARATED_SHARE = 0.10
TRAILING_EDGE = 0.95
NOSE = 0.05
STALL_LENGTH = 0.30
MERGE = 0.005  # reversed runs closer than this (of the chord) are one
SHORTEST = 0.005  # runs shorter than this are the wall's noise


def wall_points(vtu: Path) -> np.ndarray:
    """SU2's wall points from flow.vtu as (x, y, Cf_x, Cf_y, Cp); the CSV
    surface file holds no skin friction in SU2 8.5."""
    from .field import _read_vtu

    pts, _, arrays = _read_vtu(vtu)
    cf = np.asarray(arrays.get("Skin_Friction_Coefficient"))
    if cf.ndim != 2:
        return np.zeros((0, 5))
    wall = np.linalg.norm(cf[:, :2], axis=1) > 0  # zero away from the walls
    return np.column_stack([pts[wall, :2], cf[wall, :2], np.asarray(arrays["Pressure_Coefficient"])[wall]])


def surface_cf(points: np.ndarray, placed: list[np.ndarray]) -> list[np.ndarray]:
    """Each element's wall points as rows (x/c along its chord, skin friction
    along the flow, side: 1 upper / -1 lower on screen, distance from the
    stagnation point over the chord, x, y), each side ordered from the stagnation
    point to the trailing edge. Upper is left of the nose-to-tail line, the way
    the flow runs. The stagnation point is the wall point of highest Cp near
    the nose, so the strip between the nose and it belongs to the surface its
    flow goes on to."""
    p, cf, cp = points[:, :2], points[:, 2:4], points[:, 4]
    owner = np.argmin([np.min(np.linalg.norm(p[:, None, :] - e[None, :, :], axis=2), axis=1) for e in placed], axis=0)
    out = []
    for i, e in enumerate(placed):
        lead = int(np.argmin(e[:, 0]))
        le, te = e[lead], 0.5 * (e[0] + e[-1])
        chord = max(float(np.linalg.norm(te - le)), 1e-12)
        along = (te - le) / chord
        arc = np.concatenate([[0.0], np.cumsum(np.linalg.norm(np.diff(e, axis=0), axis=1))])  # tail, round the nose, tail
        q, cq, pq = p[owner == i], cf[owner == i], cp[owner == i]
        if not len(q):
            out.append(np.zeros((0, 6)))
            continue
        # Each point onto its nearest outline segment: its arc length and the segment's direction.
        seg = np.diff(e, axis=0)
        length = np.maximum(np.linalg.norm(seg, axis=1), 1e-30)
        t = np.clip(np.einsum("nsk,sk->ns", q[:, None, :] - e[None, :-1, :], seg) / length**2, 0.0, 1.0)
        foot = e[None, :-1, :] + t[:, :, None] * seg[None]
        near = np.argmin(np.linalg.norm(q[:, None, :] - foot, axis=2), axis=1)
        s_arc = arc[near] + t[np.arange(len(q)), near] * length[near]
        tangent = seg[near] / length[near][:, None]
        xc = (q - le) @ along / chord
        nose = np.abs(s_arc - arc[lead]) < 0.1 * chord
        stag = s_arc[nose][np.argmax(pq[nose])] if nose.any() else arc[lead]
        left = along[0] * (e[:, 1] - le[1]) - along[1] * (e[:, 0] - le[0])  # cambered sections can lie wholly to one side
        first_half_upper = float(left[:lead + 1].mean()) > float(left[lead:].mean())
        rows = []
        for after in (False, True):  # the surface from the stagnation point towards index 0, then towards the end
            m = s_arc > stag if after else s_arc <= stag
            d = np.abs(s_arc[m] - stag) / chord
            ct = np.sum(cq[m] * tangent[m], axis=1) * (1 if after else -1)
            upper = first_half_upper != after
            side = np.full(m.sum(), 1.0 if upper else -1.0)
            o = np.argsort(d)
            rows.append(np.column_stack([xc[m], ct, side, d, q[m]])[o])
        out.append(np.vstack(rows))
    return out


def add_cf(surface: list[dict], cf_by_element: list[np.ndarray]) -> list[dict]:
    """surface_cp's elements with "cf": the skin friction along the flow at
    each point (negative where the flow is reversed), from the nearest wall point."""
    out = []
    for s, a in zip(surface, cf_by_element):
        xy = np.column_stack([s["x"], s["y"]])
        if not len(a) or not len(xy):
            out.append(s)
            continue
        near = np.argmin(np.linalg.norm(xy[:, None, :] - a[None, :, 4:6], axis=2), axis=1)
        out.append({**s, "cf": np.round(a[near, 1], 7).tolist()})
    return out


def regions(cf_by_element: list[np.ndarray], inverted: list[bool]) -> list[dict]:
    """Every reversed-flow region from surface_cf, in element order."""
    found = []
    for i, a in enumerate(cf_by_element):
        for side, surface in ((1.0, "upper"), (-1.0, "lower")):
            rows = a[a[:, 2] == side]
            rows = rows[np.argsort(rows[:, 3])]
            runs = []  # [first row, last row] of each reversed run
            for k in np.nonzero(rows[:, 1] < 0)[0]:
                if runs and rows[k, 3] - rows[runs[-1][1], 3] <= MERGE:
                    runs[-1][1] = k
                else:
                    runs.append([k, k])
            loaded = "suction" if (surface == "lower") == bool(inverted[i]) else "pressure"
            for j, k in runs:
                start, end = float(rows[j, 0]), float(rows[k, 0])
                length = rows[k, 3] - rows[j, 3]
                to_edge = end >= TRAILING_EDGE
                if length < SHORTEST:  # one point, or the trailing-edge corner
                    continue
                at_nose = rows[j, 3] <= NOSE or rows[j, 0] <= NOSE  # near the stagnation point or the nose itself
                if at_nose and (to_edge or length > STALL_LENGTH):
                    kind = "leading-edge stall"
                elif at_nose:
                    kind = "leading-edge bubble"
                elif to_edge:
                    kind = "trailing-edge separation"
                else:
                    kind = "bubble"
                found.append({"element": i, "surface": surface, "loaded": loaded, "kind": kind,
                              "start": round(max(start, 0.0), 4), "end": round(min(1.0 if to_edge else end, 1.0), 4)})
    return found


def separation(found: list[dict]) -> tuple[bool, str | None]:
    """Whether the wing separates in RANS, and where, in words, from regions."""
    from .geometry import label

    parts = []
    for r in found:
        where = f"{label(r['element'])} separates on its {r['surface']} ({r['loaded']}) surface"
        if r["kind"] == "leading-edge stall":
            parts.append(f"{where} from the leading edge to {r['end'] * 100:.0f}% of its chord")
        elif r["kind"] == "trailing-edge separation" and 1.0 - r["start"] > SEPARATED_SHARE:
            parts.append(f"{where} from {r['start'] * 100:.0f}% of its chord to the trailing edge")
    if not parts:
        return False, None
    return True, "; ".join(parts) + " (RANS)."


def surface_cp(path: Path, placed: list[np.ndarray]) -> list[dict]:
    """Cp along each element from SU2's surface file (all walls in one file:
    each point goes to the nearest element)."""
    if not path.exists():
        return []
    with open(path, newline="") as f:
        rows = list(csv.reader(f))
    names = [h.strip().strip('"') for h in rows[0]]
    if "x" not in names or "y" not in names:
        return []
    ix, iy = names.index("x"), names.index("y")
    if "Pressure_Coefficient" in names:
        icp, factor = names.index("Pressure_Coefficient"), 1.0
    elif "Pressure" in names:
        # SU2 8.5's CSV surface file holds only the solution variables. Its
        # incompressible pressure is non-dimensional by rho V^2 (INC_NONDIM=
        # INITIAL_VALUES) and zero in the free stream, so Cp is twice it
        # (checked against the Pressure_Coefficient in flow.vtu).
        icp, factor = names.index("Pressure"), 2.0
    else:
        return []
    pts = np.array([[float(r[ix]), float(r[iy]), factor * float(r[icp])] for r in rows[1:] if len(r) == len(names)])
    owner = np.argmin([np.min(np.linalg.norm(pts[:, None, :2] - e[None, :, :], axis=2), axis=1) for e in placed], axis=0)
    out = []
    for i, e in enumerate(placed):
        sel = pts[owner == i]
        # In order around the element (Selig: trailing edge, upper, leading
        # edge, lower), by the nearest point of its outline.
        near = np.argmin(np.linalg.norm(sel[:, None, :2] - e[None, :, :], axis=2), axis=1)
        order = np.argsort(near, kind="stable")
        sel, near = sel[order], near[order]
        half = (len(e) - 1) // 2
        out.append({"x": np.round(sel[:, 0], 6).tolist(), "y": np.round(sel[:, 1], 6).tolist(),
                    "cp": np.round(sel[:, 2], 5).tolist(),
                    "side": ["upper" if k <= half else "lower" for k in near]})
    return out


FINITE_SOLVES = 4  # the 2D solve and up to three at the induced angle
FINITE_TOLERANCE = 0.1  # degrees: the induced angle has settled
FINITE_RELAX = 0.7


def solve_finite(p: dict, workdir: Path, mesh_file: Path, su2_hint: str | None, cores: int, env: dict | None,
                 progress: Callable[[float, str], None], log: Callable[..., None], field: bool = True) -> dict:
    """The wing as it runs on the car: its section at the angle the flow meets
    it there. p["finite"] holds span and endplate height (m). A 2D solve
    first; then the flow is turned by the induced angle (lifting line, with
    the ground's image cutting it over a ground) and solved again, each from
    the last solution in free air, until that angle settles within
    FINITE_TOLERANCE or FINITE_SOLVES solves. cl, cd (with induced drag),
    regions and the field are the last solve's; finite holds the angles and
    the 2D answer. No car upwash, endplate vortex or spanwise variation:
    the mid-span section on the car."""
    import shutil

    from .finite import effective_aspect_ratio, ground_factor, induced_angle

    fin = p.get("finite") or {}
    for key in ("span", "endplate"):
        if not isinstance(fin.get(key), (int, float)) or fin[key] < 0 or (key == "span" and fin[key] <= 0):
            raise EngineError(f"params.finite needs the wing's {key} in metres",
                              "set the span and endplate height under Into the Lap Sim")
    span, endplate = float(fin["span"]), float(fin["endplate"])
    chord = float(p.get("ref_chord") or sum(float(e["chord"]) for e in p["elements"]))
    ride = p.get("ride_height")
    ar = effective_aspect_ratio(span, chord, endplate)
    alpha = float(p.get("alpha", 0.0))
    ground = ride is not None
    q = {k: v for k, v in p.items() if k != "finite"}
    ready, prev, a, r, two_d, settled, tried = None, None, alpha, None, None, False, []
    for n in range(1, FINITE_SOLVES + 1):
        folder = workdir / f"s{n}"
        folder.mkdir(parents=True, exist_ok=True)
        report = lambda pct, msg, n=n, a=a: progress(100 * (n - 1 + pct / 100) / FINITE_SOLVES, f"{a:+.1f}°: {msg}")
        r = solve({**q, "alpha": a}, folder, mesh_file, su2_hint, cores, env, report, log, field=field,
                  mesh_ready=ready, restart=prev)
        if n == 1:
            two_d = {k: r.get(k) for k in ("cl", "cd", "separated", "separation", "converged")}
            target = alpha + induced_angle(r["cl"] * ar / (ar + 2), span, chord, endplate, ride)  # linear first guess
        else:
            target = alpha + induced_angle(r["cl"], span, chord, endplate, ride)
            log(f"solve {n} at {a:+.2f}°: Cl {r['cl']:.4f}, induced angle wants {target:+.2f}°")
            if abs(target - a) < FINITE_TOLERANCE:
                settled = True
                break
        if not ground:
            ready = {"mesh": r["mesh"], "transition": r["transition"]}
            prev = (folder / "restart.dat").resolve() if (folder / "restart.dat").exists() else None
        tried.append((a, target - a))
        if n < FINITE_SOLVES:
            if n == 1:
                a = target
            elif len(tried) >= 3 and tried[-1][1] != tried[-2][1]:
                # Secant on (target - angle) over the last two at the induced angle: where the main
                # stalls Cl moves fast with angle and relaxing swings about the answer (frontwing#1).
                (a0, f0), (a1, f1) = tried[-2], tried[-1]
                a = a1 - f1 * (a1 - a0) / (f1 - f0)
            else:
                a = a + FINITE_RELAX * (target - a)
    if not settled:
        log(f"the induced angle had not settled after {FINITE_SOLVES} solves", level="warning")
    # The last solve's files are the run's: the app reads the field and surface from the job folder.
    for f in folder.iterdir():
        if f.is_file():
            shutil.copy2(f, workdir / f.name)
    gf = ground_factor(ride, span)
    cd_induced = r["cl"] ** 2 / (np.pi * ar) * gf
    r = {**r, "alpha": alpha, "cd": r["cd"] + cd_induced,
         "finite": {"alpha_effective": round(a, 3), "induced_angle": round(a - alpha, 3), "aspect_ratio_effective": round(ar, 3),
                    "ground_factor": round(gf, 4), "solves": n, "converged": settled, "cd_induced": cd_induced,
                    "span": span, "endplate": endplate, "two_d": two_d}}
    return r


BRACKET_LIFT = 0.05  # the two models' lift this far apart (relative) also means transition decides it


def bracket(p: dict, first: dict, workdir: Path, mesh_file: Path, su2_hint: str | None, cores: int, env: dict | None,
            progress: Callable[[float, str], None], log: Callable[..., None]) -> dict:
    """first (an SST-LM run) with the same wing again fully turbulent (SST), at
    the angle first ran at (its induced angle when it ran as on the car), from
    first's solution on the same mesh in free air. Car CFD is usually fully
    turbulent; the track lies between. transition_decides: the two disagree on
    separation, or their lift differs by more than BRACKET_LIFT."""
    alpha = (first.get("finite") or {}).get("alpha_effective", p.get("alpha", 0.0))
    ground = p.get("ride_height") is not None
    ready = None if ground else {"mesh": first["mesh"], "transition": first["transition"]}
    restart = (workdir / "restart.dat").resolve() if not ground and (workdir / "restart.dat").exists() else None
    folder = workdir / "turbulent"
    folder.mkdir(parents=True, exist_ok=True)
    q = {k: v for k, v in p.items() if k != "finite"}
    q.update(model="sst", alpha=alpha)
    report = lambda pct, msg: progress(pct, f"fully turbulent: {msg}")
    try:
        r = solve(q, folder, mesh_file, su2_hint, cores, env, report, log, field=False, mesh_ready=ready, restart=restart)
    except EngineError as exc:
        if restart is None:
            raise
        log(f"fully turbulent from the transition solution failed ({exc.msg}); from rest", level="warning")
        r = solve(q, folder, mesh_file, su2_hint, cores, env, report, log, field=False, mesh_ready=ready)
    sst = {k: r.get(k) for k in ("cl", "cd", "converged", "separated", "separation", "regions")}
    decides = bool(sst["separated"]) != bool(first.get("separated")) or \
        abs(sst["cl"] - first["cl"]) > BRACKET_LIFT * max(abs(first["cl"]), 1e-9)
    return {**first, "bracket": {"sst": sst}, "transition_decides": decides}


def sweep(p: dict, workdir: Path, mesh_file: Path, su2_hint: str | None, cores: int, env: dict | None,
          progress: Callable[[float, str], None], log: Callable[..., None]) -> dict:
    """The wing at several angles on one mesh within time_limit seconds.

    The middle angle runs first, from rest; then the others alternately above
    and below it, working outwards, each started from its neighbour's
    solution, which takes about half the iterations. If time runs out, what
    was run is a balanced range about the middle. Every angle's iterations are capped by the time left,
    so the sweep never runs past the limit: an angle that hits the cap is
    reported as not converged, and angles there is no time to start are
    listed as skipped. Each angle's files go to workdir/a<angle>.

    Over a ground the wing turns against it, so each angle is meshed again
    and solved from rest (a restart needs the same mesh): slower, but the
    same sweep."""
    import time

    alphas = sorted({float(a) for a in p.get("alphas", [])})
    if not alphas:
        raise EngineError("params.alphas must list the wing angles")
    ground = p.get("ride_height") is not None
    limit = float(p.get("time_limit") or float("inf"))  # 0 or none: no limit
    max_iterations = int(p.get("iterations", 4000))
    if p.get("order") == "rising":
        # A polar through stall: the least loaded angle from rest, each next
        # from the one before, so the angles near maximum lift start from an
        # attached flow. Least loaded is the lowest angle upright and the
        # highest inverted (a bigger wing angle unloads an inverted wing).
        seq = alphas[::-1] if any(e.get("inverted") for e in p.get("elements", [])) else alphas
        order = [(seq[0], None)] + [(seq[k], seq[k - 1]) for k in range(1, len(seq))]
    else:
        mid = min(range(len(alphas)), key=lambda k: abs(alphas[k] - 0.5 * (alphas[0] + alphas[-1])))
        order = [(alphas[mid], None)]
        for step in range(1, len(alphas)):
            if mid + step < len(alphas):
                order.append((alphas[mid + step], alphas[mid + step - 1]))
            if mid - step >= 0:
                order.append((alphas[mid - step], alphas[mid - step + 1]))
    start = time.time()
    done: dict[float, dict] = {}
    solutions: dict[float, Path] = {}
    skipped: list[float] = []
    ready = None
    per_iteration = None  # seconds, the slowest seen
    restart_time = None  # seconds a restarted angle took, once one has
    base = {**p, "wake_alpha": 0.5 * (alphas[0] + alphas[-1])}
    for n, (a, near) in enumerate(order):
        left = limit - (time.time() - start)
        if done:
            first = next(iter(done.values()))["seconds"]
            expected = first if ground else restart_time if restart_time is not None else 0.5 * first
            # No time limit (left is infinite): every angle gets the full iterations.
            cap = min(int(left / per_iteration), max_iterations) if per_iteration and left != float("inf") else max_iterations
            if expected > left or cap < 200:
                skipped = sorted(x for x, _ in order[n:])
                log(f"time limit: {len(skipped)} angle(s) not run", level="warning")
                break
        else:
            cap = max_iterations
        folder = workdir / f"a{a:g}"
        folder.mkdir(parents=True, exist_ok=True)
        t0 = time.time()
        lo, hi = 100 * n / len(order), 100 * (n + 1) / len(order)
        report = lambda pct, msg, lo=lo, hi=hi, a=a: progress(lo + (hi - lo) * pct / 100, f"{a:g}°: {msg}")
        restart = solutions.get(near) if near is not None and not ground else None
        q = {**base, "alpha": a, "iterations": min(max_iterations, cap)}
        try:
            r = solve(q, folder, mesh_file, su2_hint, cores, env, report, log, mesh_ready=ready, restart=restart)
        except EngineError as exc:
            if restart is None:
                raise
            # A restart that will not settle: try that angle once from rest.
            log(f"{a:g}° from {near:g}°'s solution failed ({exc.msg}); from rest", level="warning")
            left = limit - (time.time() - start)
            q["iterations"] = min(max_iterations, int(left / per_iteration)) if per_iteration and left != float("inf") else max_iterations
            restart = None
            r = solve(q, folder, mesh_file, su2_hint, cores, env, report, log, mesh_ready=ready)
        r.pop("history_columns", None)
        seconds = round(time.time() - t0, 1)
        r.update(seconds=seconds, folder=folder.name, started_from=near if restart is not None else None)
        done[a] = r
        ready = None if ground else {"mesh": r["mesh"], "transition": r["transition"]}
        if not ground and (folder / "restart.dat").exists():
            solutions[a] = (folder / "restart.dat").resolve()
        if r.get("iterations"):
            per_iteration = max(per_iteration or 0.0, seconds / r["iterations"])
        if restart is not None:
            restart_time = max(restart_time or 0.0, seconds)
        log(f"{a:g}°: Cl {r['cl']:.4f}, Cd {r['cd']:.5f}{'' if r['converged'] else ' (not converged)'}, {seconds:.0f} s"
            + (f", from {near:g}°" if restart is not None else ", from rest"))
    rows = [done[a] for a in alphas if a in done]
    return {"rows": rows, "skipped": skipped, "seconds": round(time.time() - start, 1),
            "time_limit": limit if limit != float("inf") else 0.0}
