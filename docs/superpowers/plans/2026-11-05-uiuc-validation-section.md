# UIUC comparison in the accuracy window — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A section in the accuracy window that compares the quick estimate and RANS against ten UIUC tunnel sections, keeps a history of runs, and recomputes on demand.

**Architecture:** The engine gains a fixed ten-case benchmark in `aeroengine/validation.py` (case picking, RANS errors, a run that appends to `data/validation/uiuc_results.json`), a `validate-uiuc` job and a `uiuc-results` warm-engine request. The kit decodes the results; the app shows them in `AccuracyHelpView` and submits the job.

**Tech Stack:** Python (NeuralFoil, SU2 through `rans.sweep`), SwiftUI + Swift Charts, sage37, the existing JobManager and WarmEngine.

**Spec:** `docs/superpowers/specs/2026-11-05-uiuc-validation-section-design.md`

## Global Constraints

- UIUC data (GPL) is never committed: fetched into `data/validation/downloads` by `fetch_uiuc`. Committed results hold only AeroBench's numbers and errors.
- Errors for both solvers use `compare()`'s rules: relative, lift against `LIFT_FLOOR` (0.4), attached range up to `STALL_BACKOFF` (2°) short of the measured maximum lift.
- RANS errors come from linear interpolation between converged RANS angles at the tunnel's angles; outside the converged range, no RANS error.
- RANS: one element, chord 0.30 m, rho 1.225, mu 1.81e-5, speed so Re equals the tunnel run's own, angles every 2° within the tunnel's range, `order` "rising", `time_limit` 0, mesh "fine", model `su2.DEFAULT_MODEL`, turbulence intensity left at the engine default.
- Comparable settings: model, mesh, turbulence intensity, engine git commit. Cores are recorded but never make a run stale.
- Run picking: comment exactly "clean" (case-insensitive), within 5% of Re 300,000, most angles wins, then nearest Re.
- sage37: solid panes, one prominent button per view, left-aligned text, no colour outside the tokens.

## Review Focus

- **No internet on first open:** the tunnel data cannot download. Expect the section to show errors and history without tunnel points and one line saying why (test in Task 3).
- **SU2 not installed:** Recompute is disabled with the same note Wing Lab's RANS shows (`haveSU2` pattern) (Task 4).
- **Results file missing (first launch):** the section says the comparison has not run yet and offers Recompute (tests in Tasks 2 and 4).
- **A section whose RANS never converges:** its RANS errors are null and it shows "no converged angles"; the summary means skip it and the converged share counts it (test in Task 2).
- **Cancelled run resumed after the defaults changed:** the partial file is discarded and the run starts fresh, never mixing settings (test in Task 2).

---

### Task 1: The benchmark cases and shared error rules

**Files:**
- Modify: `engine/src/aeroengine/validation.py`
- Test: `engine/tests/test_validation.py`

**Interfaces:**
- Produces:
  - `UIUC_BENCHMARK: list[tuple[str, int, str]]`: (airfoil as the drag file names it, volume, key), in this order: ("S1223", 1, "s1223"), ("E423", 2, "e423"), ("S1210", 1, "s1210"), ("SG6043", 3, "sg6043"), ("SD7062 (B)", 3, "sd7062"), ("E387 (A)", 1, "e387"), ("SD7037 (B)", 1, "sd7037"), ("Clark-Y (B)", 3, "clarky"), ("SA7038", 3, "sa7038"), ("S8037", 3, "s8037").
  - `pick_run(runs: list[dict], airfoil: str, target: float = 300_000) -> dict | None`
  - `benchmark_cases(folders: dict[int, Path] | None = None) -> list[Case]` (Case.key = the benchmark key; Case.notes names the volume and model file)
  - `errors(case: Case, alphas, cl, cd) -> dict`: `{"lift": float|None, "drag": float|None, "lift_signed": float|None}` over the attached range at the tunnel's angles; `alphas` may be a subset (points with no value are skipped).
  - `rans_at_tunnel(case: Case, rans_rows: list[tuple[float, float, float, bool]]) -> tuple[list, list, list]`: interpolated Cl, Cd at the tunnel angles inside the converged range.
- `compare()` keeps its return shape; it uses `errors()` internally.

- [ ] **Step 1: Write the failing tests**

```python
def test_pick_run_takes_the_clean_run_with_most_angles():
    runs = [{"airfoil": "SG6043", "comment": "clean", "re": 299_100, "rows": [(0, .5, .01)] * 11},
            {"airfoil": "SG6043", "comment": "clean", "re": 299_700, "rows": [(0, .5, .01)] * 20},
            {"airfoil": "SG6043", "comment": "clean: flap = 10 degs", "re": 300_000, "rows": [(0, .5, .01)] * 30},
            {"airfoil": "SG6043", "comment": "clean", "re": 200_000, "rows": [(0, .5, .01)] * 40}]
    assert v.pick_run(runs, "SG6043")["re"] == 299_700

def test_rans_errors_use_only_converged_angles_inside_their_range():
    case = v.Case("t", "t", "", 3e5, np.zeros((3, 2)), [(-1.0, 0.4, 0.010), (1.0, 0.6, 0.012), (5.0, 1.0, 0.020)])
    rows = [(0.0, 0.5, 0.011, True), (2.0, 0.7, 0.013, True), (4.0, 0.9, 0.030, False)]
    a, cl, cd = v.rans_at_tunnel(case, rows)
    assert a == [1.0] and cl == pytest.approx([0.6]) and cd == pytest.approx([0.012])

def test_a_section_with_no_converged_rans_has_no_rans_errors():
    case = v.Case("t", "t", "", 3e5, np.zeros((3, 2)), [(0.0, 0.5, 0.01), (2.0, 0.7, 0.012)])
    assert v.errors(case, *v.rans_at_tunnel(case, [(0.0, 0.5, 0.01, False)])) == {"lift": None, "drag": None, "lift_signed": None}
```

Plus a network test (skipped without a connection, like the existing UIUC tests): `benchmark_cases()` returns ten cases with the keys above, each Re within 5% of 300,000 and each model a `.dap` file.

- [ ] **Step 2: Run them and watch them fail**

Run: `cd engine && .venv/bin/python -m pytest tests/test_validation.py -q -k "pick_run or rans_errors or no_converged or benchmark"`
Expected: FAIL, `pick_run` / `rans_at_tunnel` / `errors` not defined.

- [ ] **Step 3: Implement**

`errors()` is `compare()`'s existing error block lifted out (attached range from the full measured rows, then the subset). `fetch_uiuc` already takes a volume; `benchmark_cases` reads each needed volume's DRAG and COORD files and uses `_model` for the tested shape.

- [ ] **Step 4: Run `tests/test_validation.py` whole and watch it pass**

Run: `cd engine && PATH=$PWD/.venv/bin:$PATH .venv/bin/python -m pytest tests/test_validation.py -q`
Expected: all pass (network ones skip offline).

- [ ] **Step 5: Commit** `engine/src/aeroengine/validation.py engine/tests/test_validation.py`, "Validation: the ten-section UIUC benchmark and shared error rules".

### Task 2: The benchmark run and its results file

**Files:**
- Modify: `engine/src/aeroengine/validation.py`
- Test: `engine/tests/test_validation.py`

**Interfaces:**
- Consumes: Task 1's `benchmark_cases`, `errors`, `rans_at_tunnel`.
- Produces:
  - `RESULTS_FILE = data_dir() / "validation" / "uiuc_results.json"`, partial file `uiuc_partial.json` beside it.
  - `current_settings() -> dict`: `{"model": su2.DEFAULT_MODEL, "mesh": "fine", "turbulence_intensity": <rans default>, "commit": <git short hash or None>}`
  - `run_benchmark(workdir: Path, cores: int, su2_hint: str | None, progress, results: Path = RESULTS_FILE, cases: list[Case] | None = None, rans_fn=None) -> dict` returning the run it appended. `rans_fn(case, workdir) -> list[(alpha, cl, cd, converged)]` defaults to `rans.sweep` with the Global Constraints' parameters.
  - Results JSON: `{"runs": [run, ...]}` newest first; run = `{"date", "settings", "cores", "seconds", "summary": {"estimate": {"lift", "drag"}, "rans": {"lift", "drag"}, "converged"}, "cases": [{"key", "name", "volume", "re", "estimate": [[a, cl, cd]], "rans": [[a, cl, cd, converged]], "errors": {"estimate": {...}, "rans": {...}}}]}`. Summary lift and drag are means of the per-case means that are not None; `converged` = converged RANS angles / RANS angles run, over every case.

- [ ] **Step 1: Write the failing tests** (fake `rans_fn`, two tiny cases, `tmp_path` results file):
  - `test_a_run_is_appended_newest_first`: two runs leave two entries, the second first.
  - `test_summary_skips_cases_without_rans_errors_but_counts_their_angles`: one case all unconverged → summary RANS means from the other case only; `converged` = 2/4.
  - `test_a_cancelled_run_resumes_with_the_same_settings`: a `rans_fn` that raises on case 2 leaves a partial file holding case 1; a second call with a counting `rans_fn` runs only case 2.
  - `test_a_partial_with_other_settings_is_discarded`: partial written with `"model": "sa"` → the next run runs every case.
  - `test_missing_results_file_starts_a_new_history`.

- [ ] **Step 2: Run and watch them fail** (`-k "appended or summary_skips or resumes or discarded or new_history"`); expected `run_benchmark` not defined.

- [ ] **Step 3: Implement `current_settings` and `run_benchmark`.** The partial file is written after each case and removed after the run is appended. `git rev-parse --short HEAD` in the repo for the commit, None if it fails.

- [ ] **Step 4: Run `tests/test_validation.py` and watch it pass.**

- [ ] **Step 5: Commit**, "Validation: run the UIUC benchmark and keep its history".

### Task 3: The job and the warm-engine request

**Files:**
- Modify: `engine/src/aeroengine/commands/validate.py`, `engine/src/aeroengine/serve.py`
- Test: `engine/tests/test_validation.py`

**Interfaces:**
- Consumes: Task 2's `run_benchmark`, `current_settings`, `RESULTS_FILE`.
- Produces:
  - Job `validate-uiuc`: no params needed; `ctx.options.cores`, SU2 from `ctx.params.get("su2") or ctx.options.su2_path`; returns the appended run.
  - Request `uiuc-results` → `{"runs": [...], "current": current_settings(), "tunnel": {key: {"name", "re", "rows": [[a, cl, cd]]}}, "tunnel_error": str | None}`. The tunnel comes from `benchmark_cases()`; if that raises `EngineError`, `tunnel` is `{}` and `tunnel_error` is its message.

- [ ] **Step 1: Failing tests**: `test_uiuc_results_without_the_tunnel_data_says_why` (monkeypatch `benchmark_cases` to raise `EngineError("could not download the UIUC low-speed airfoil data")`; expect empty `tunnel` and that message) and `test_uiuc_results_reads_the_history` (monkeypatched `RESULTS_FILE` in `tmp_path`).
- [ ] **Step 2: Watch them fail** (handler not registered).
- [ ] **Step 3: Implement** the command and add `"uiuc-results"` to `serve.HANDLERS`.
- [ ] **Step 4: Run the engine suite**: `cd engine && PATH=$PWD/.venv/bin:$PATH .venv/bin/python -m pytest tests -q` — expected all pass.
- [ ] **Step 5: Commit**, "Engine: the validate-uiuc job and the uiuc-results request".

### Task 4: The section in the accuracy window

**Files:**
- Create: `app/AeroBenchKit/Sources/AeroBenchKit/UIUCResults.swift`, `app/AeroBenchKit/Tests/AeroBenchKitTests/UIUCResultsTests.swift`, `app/AeroBench/Views/UIUCSection.swift`, `app/AeroBench/AppState+UIUC.swift`
- Modify: `app/AeroBench/AeroBenchApp.swift` (accuracy window gets `.environment(app)`), `app/AeroBench/Views/AccuracyHelpView.swift` (shows `UIUCSection`)

**Interfaces:**
- Consumes: Task 3's `uiuc-results` request and `validate-uiuc` job; `JobManager.submit`, `JobInlineStatus`, `WarmEngine.request`, `app.settings.su2Executable`.
- Produces:
  - Kit: `public struct UIUCResults: Decodable` mirroring the request's JSON (`runs`, `current`, `tunnel`, `tunnelError`), with `static func decode(_ data: Data) throws -> UIUCResults` and `func isStale(_ run: Run) -> Bool` (compares model, mesh, turbulence intensity, commit; ignores cores).
  - App: `AppState.uiuc: UIUCResults?`, `AppState.uiucJob: JobItem?`, `func loadUIUC() async`, `func recomputeUIUC()` (submits `validate-uiuc`; reloads on finish).

- [ ] **Step 1: Failing kit tests**: decoding a sample JSON with one run, one case, a null RANS error and `tunnel_error`; `isStale` true when the model differs and false when only cores differ.
- [ ] **Step 2: Watch them fail**: `cd app/AeroBenchKit && swift test --filter UIUCResultsTests` → type not found.
- [ ] **Step 3: Implement the kit type, then the section:**
  - not run yet: one line and the Recompute button;
  - stale: one line above the summary naming what changed;
  - summary strip: estimate lift and drag error, RANS lift and drag error, converged share, date and settings;
  - per section (a disclosure each): Cl–α, Cd–α and Cl–Cd with the tunnel as black points, the estimate as a dashed line and RANS as a line with markers (unconverged RANS points hollow), plus that section's four errors, or "no converged angles";
  - history table: date, model and mesh, four errors, converged share;
  - Recompute (prominent; disabled without SU2, with Wing Lab's note), "about an hour", `JobInlineStatus` while running, and a line saying Wing Lab's RANS runs share the cores while it runs.
- [ ] **Step 4: Verify**: kit tests pass; `xcodebuild -project app/AeroBench.xcodeproj -scheme AeroBench -configuration Debug -destination 'platform=macOS' build` → BUILD SUCCEEDED; open the app, open the accuracy window and check the not-run-yet state renders.
- [ ] **Step 5: Commit**, "Accuracy window: the UIUC comparison section".

### Task 5: First run and record

**Files:**
- Modify: `data/validation/uiuc_results.json` (created by the run), `docs/DECISIONS.md`

- [ ] **Step 1: Run the benchmark** in the background from the engine venv (`run_benchmark(workdir=<scratch>, cores=12, su2_hint=None, progress=print)`), about an hour. Expected: one run appended, ten cases.
- [ ] **Step 2: Check the numbers** against the Vol 1 workbook for S1223 and E387 (same tunnel runs, fully turbulent SST now): RANS Cd errors of the same order, Cl high.
- [ ] **Step 3: Open the accuracy window** and check charts, summary and history render with real data.
- [ ] **Step 4: DECISIONS.md entry**: the benchmark set and why, the error rules, the results file, the rerun rule (big fundamental change or Recompute).
- [ ] **Step 5: Commit, push (a major feature), `graphify update .`**
