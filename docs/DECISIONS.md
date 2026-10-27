# Decisions

Judgement calls made while building AeroBench, newest at the bottom of each
phase. Anything here can be revisited.

## Phase 0

**Repo layout.** Follows spec section 3. `scripts/` sits inside `engine/` as
the layout block indents it and section 8.1 names `engine/scripts/fetch_airfoils.py`.

**Built in a Linux container, verified on macOS CI.** Phase 0 was written in a
cloud session with no Xcode. The engine was run and tested there directly.
The Swift code is compiled and its tests run by GitHub Actions on a macOS
runner (`.github/workflows/ci.yml`), which also runs `xcodebuild` on the app.
That CI job is the main evidence the app builds until it is run on the real Mac.

**Swift split into an app target and a local package.** `app/AeroBenchKit` holds
everything that does not need SwiftUI: event parsing, the engine process
runner, project and job files. That lets `swift test` exercise the job runner
against the real engine, which covers the Phase 0 acceptance checks at that
level. The app target is views and observable state on top.

**Hand-written Xcode project, Xcode 16 format.** `project.pbxproj` uses a
file-system synchronised group for `app/AeroBench/`, so new Swift files are
picked up without touching the project file. Needs Xcode 16 or later. No
XcodeGen or other generator.

**Swift 5 language mode.** Both the app and the package compile in Swift 5 mode
with Swift 6 toolchains. Strict concurrency checking would add churn around
`Process` and pipes for no v1 benefit. Revisit when polishing.

**macOS 15 deployment target, arm64 only.** The target machine runs the latest
macOS; 15 is a safe floor for Observation, `ContentUnavailableView` and the
APIs used. Apple silicon only per spec section 2.

**No sandbox, no hardened runtime, sign to run locally.** The app has to launch
the engine from the repo and read and write project folders anywhere. Signing
and notarisation come with packaging (later phase).

**The app runs `engine/.venv/bin/aeroengine` directly, not `uv run`.** Two
reasons: `uv run` re-resolves the environment on every launch, and it puts a
uv process between the app and Python, so SIGTERM/SIGKILL would hit uv and
could orphan Python. The trade-off is that `uv sync` must have been run in the
engine folder, which Settings checks and reports.

**Cancelling.** SIGTERM, then SIGKILL after 3 s. The engine makes itself a
process group leader at startup, and the SIGKILL goes to the whole group so
any solver it starts later (gmsh, SU2) dies with it. On SIGTERM the engine
stops, cleans up its intermediates and exits with 143, logging a `cancelled`
warning event. No new event type was added.

**How a job is judged.** Succeeded only if the engine exited 0 and emitted a
`result` event. A job the user cancelled is cancelled. Otherwise it failed,
with the engine's own `error` message if it sent one, else a message built
from the exit status (killed by signal, non-zero exit, or no result) and the
tail of stderr. Nothing is shown as good unless the engine said so.

**Job folder contents.** The app owns `job.json`, `status.json` and `log.txt`;
the engine owns `result.json` and its intermediates. Jobs left as running by a
crash or quit are marked failed ("Interrupted") the next time the folder is
loaded.

**Intermediates.** Commands put throwaway files in `scratch/` and meshes in
`mesh/` inside the job folder. The engine removes both when the job ends,
whether it succeeded, failed or was cancelled, and keeps `mesh/` only when
`options.keep_mesh` is true. A SIGKILLed engine cannot clean up after itself,
so its `scratch/` may survive; it stays inside the job folder.

**Jobs with no project open** go to the app's cache folder
(`~/Library/Caches/<bundle id>/jobs`), the only place outside a project the app
writes, per spec section 4.

**Core limit.** Settings has max parallel jobs (default 2) and cores per job
(default 4). Cores per job reaches the engine as `options.cores` in job.json and
as `OMP_NUM_THREADS` / `AEROBENCH_CORES`; `JobContext.thread_env()` builds the
environment for child solvers. Placeholder defaults; tune once real runs exist.

**Engine dependencies are added per phase.** Phase 0 needs only the standard
library, so `engine/pyproject.toml` has no runtime dependencies yet. numpy,
scipy and the rest (spec section 3) are added, and checked for Apple silicon
wheels, when the phase that needs them lands. This keeps `uv sync` fast and
avoids pinning versions nobody has tested yet.

**Engine default for development builds.** Settings defaults the engine folder
to `<repo>/engine`, worked out from the source path at compile time, so a fresh
clone works without configuration.

**Project autosave on switch and quit.** Opening another project, closing the
current one or quitting saves unsaved project changes instead of asking.
Explicit Save (⌘S) is also there.

**SU2 install steps deferred to Phase 4.** They could not be verified from a
Linux container, and the spec asks for steps that actually work on the Mac.

**Airfoil data ignored by git now.** `data/airfoils/*` is gitignored ahead of
Phase 4 because UIUC's redistribution terms have not been checked yet.
