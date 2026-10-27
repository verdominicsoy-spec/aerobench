# aeroengine

The Python compute engine behind AeroBench. Every operation is a subcommand:

```
aeroengine <command> --input job.json --workdir <job folder>
```

stdout is JSON lines, one event per line (`progress`, `log`, `result`, `error`).
The result itself is written to `result.json` inside the job folder.

```
uv sync                 # create .venv with the engine installed
uv run pytest           # run the test suite
uv run aeroengine list  # list available commands
```

See the repo README and docs/ for the job protocol.
