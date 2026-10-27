# AeroBench

One native macOS app with four Formula Student aero tools: Wing Lab, CAD Viewer,
Flow Field Viewer and Lap Sim. SwiftUI front end, Python compute engine. The
full brief is in [docs/AeroBench_spec.pdf](docs/AeroBench_spec.pdf), and every
judgement call made while building it is in [docs/DECISIONS.md](docs/DECISIONS.md).

**Status:** Phase 1 (Lap Sim) built. Wing Lab, CAD Viewer and Flow Field Viewer are empty screens for now.

## Layout

```
app/                  Xcode project (AeroBench.xcodeproj)
  AeroBench/          SwiftUI app sources
  AeroBenchKit/       Swift package: engine runner, project and job files (unit tested)
engine/               aeroengine Python package, managed with uv
  src/aeroengine/     CLI, job context, commands
  tests/              pytest suite
  scripts/            one-off tools (fetch_airfoils.py arrives in Phase 4)
data/airfoils/        airfoil library, fetched not committed
samples/              small test inputs
docs/                 spec and DECISIONS.md
```

## Setup on the Mac

You need Xcode 16 or later (for the project format) and [uv](https://docs.astral.sh/uv/).

```sh
# 1. uv, if you don't have it (either works)
brew install uv
# or: curl -LsSf https://astral.sh/uv/install.sh | sh

# 2. The engine. uv fetches Python 3.12 itself and builds engine/.venv
cd engine
uv sync
uv run pytest -q          # should be all green
cd ..

# 3. The app
open app/AeroBench.xcodeproj
```

In Xcode pick the **AeroBench** scheme and **My Mac**, then Run (⌘R). Signing is
set to "Sign to Run Locally", so no Apple developer team is needed.

On first launch the engine folder in Settings (⌘,) defaults to this repo's
`engine/` folder. If it shows "Engine not found", point it at `engine/` and make
sure `uv sync` has been run there. The app runs `engine/.venv/bin/aeroengine`
directly.

## Phase 0 checks

On the Project screen (no project needs to be open):

1. **Ping Engine** should show "pong from Python 3.12.x".
2. **Run** the dummy job at 10 s, open **Jobs** in the sidebar, watch the progress
   bar move, then press **Cancel**. It should end as cancelled within a second.
3. Run it again, and while it is running kill the engine from Terminal:
   `pkill -9 -f "aeroengine dummy"`. The job should show as failed with
   "Engine process was killed (signal 9)" and the app should keep running.

The same three behaviours are covered by automated tests in
`app/AeroBenchKit/Tests` that drive the real engine:

```sh
cd app/AeroBenchKit
AEROBENCH_ENGINE="$PWD/../../engine" swift test
```

## Lap Sim

Quasi-steady point-mass lap sim. Pick a track (built-in test track, skidpad,
75 m acceleration run, or an imported centreline CSV), set car A and
optionally car B, and Run (⌘R). Results show lap time, endurance time and
energy, a speed trace, a track map coloured by speed, the B minus A time
delta, and dt/dClA, dt/dCdA with the ClA-for-CdA exchange rate.

The car values shipped are **placeholder estimates**, marked "est." until you
change them. Every value is editable and saved in the project's
`lapsim/setup.json` when you save.

Track CSVs: the first two numeric columns are taken as x and y; header and `#`
comment lines are skipped; commas, semicolons, tabs or spaces all work. Pick m
or mm in the app. Whether the loop is closed is detected from whether the ends
meet, or set it by hand. With a project open, imported CSVs are copied into
`lapsim/tracks/`.

The engine side can be run by hand too:

```sh
cd engine
cat > /tmp/job.json <<'JSON'
{"params": {"track": {"builtin": "skidpad"},
  "car": {"mass": 280, "cla": 3.5, "cda": 1.3, "mu_lat": 1.5, "mu_long": 1.4,
          "power": 80000, "driven_axle_fraction": 0.55, "aero_balance_driven": 0.55,
          "crr": 0.015, "rho": 1.225, "v_max": 33}}}
JSON
uv run aeroengine lapsim --input /tmp/job.json --workdir "$(mktemp -d)"
```

## The engine on its own

```sh
cd engine
uv run aeroengine list
uv run aeroengine ping --workdir "$(mktemp -d)"
```

Every command is `aeroengine <command> --input job.json --workdir <job folder>`.
stdout is JSON lines (`progress`, `log`, `result`, `error`), the result lands in
`<job folder>/result.json`, and exit codes are 0 done, 1 failed, 2 bad usage,
143 cancelled.

## Projects and jobs

A project is a folder:

```
My Project/
  project.json        name, dates, notes, per-tool state
  wing/ cad/ flow/ lapsim/
  jobs/<yyyyMMdd-HHmmss-xxxx>/
    job.json          what the app asked for (command, params, options)
    status.json       queued / running / succeeded / failed / cancelled
    result.json       written by the engine on success
    log.txt           everything the engine printed
```

With no project open, jobs go to `~/Library/Caches/dev.aerobench.AeroBench/jobs`.
Intermediates (`scratch/`, `mesh/`) are deleted when a job ends; `mesh/` is kept
only if Keep mesh was ticked.

## SU2

Not needed until Phase 4 (Wing Lab). The exact Apple silicon install steps will
be written here once they have been checked on the actual machine.
