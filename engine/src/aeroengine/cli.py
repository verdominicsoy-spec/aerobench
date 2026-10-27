"""Entry point: aeroengine <command> --input job.json --workdir <job folder>

Exit codes: 0 done, 1 failed (an error event was emitted), 2 bad usage,
143 cancelled by SIGTERM.
"""

from __future__ import annotations

import argparse
import os
import signal
import sys
import traceback
from pathlib import Path

from .commands import COMMANDS
from .events import Emitter
from .job import EngineError, JobCancelled, JobContext

EXIT_OK, EXIT_FAILED, EXIT_USAGE, EXIT_CANCELLED = 0, 1, 2, 143


class _UsageError(Exception):
    pass


class _Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:  # type: ignore[override]
        raise _UsageError(message)


def _parser() -> argparse.ArgumentParser:
    p = _Parser(prog="aeroengine", description="AeroBench compute engine")
    p.add_argument("command", help=f"one of: list, {', '.join(sorted(COMMANDS))}")
    p.add_argument("--input", type=Path, help="job JSON file (defaults to an empty job)")
    p.add_argument("--workdir", type=Path, help="job folder for results and intermediates")
    return p


def _on_sigterm(signum: int, frame: object) -> None:
    # Ignore repeats so cleanup is not interrupted. The app follows up with
    # SIGKILL if we take too long.
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    raise JobCancelled()


def main(argv: list[str] | None = None) -> int:
    emit = Emitter()
    try:
        args = _parser().parse_args(argv)
    except _UsageError as exc:
        emit.error(f"bad arguments: {exc}")
        return EXIT_USAGE

    if args.command == "list":
        emit.emit({"type": "commands", "names": sorted(COMMANDS)})
        return EXIT_OK
    fn = COMMANDS.get(args.command)
    if fn is None:
        emit.error(f"unknown command '{args.command}'", f"available: {', '.join(sorted(COMMANDS))}")
        return EXIT_USAGE
    if args.workdir is None:
        emit.error("--workdir is required")
        return EXIT_USAGE

    # Lead our own process group so the app can kill any solver we spawn
    # along with us. Harmless if we already lead one.
    try:
        os.setpgid(0, 0)
    except OSError:
        pass
    signal.signal(signal.SIGTERM, _on_sigterm)
    signal.signal(signal.SIGINT, _on_sigterm)

    ctx: JobContext | None = None
    try:
        ctx = JobContext.load(args.command, args.input, args.workdir, emit)
        emit.log(f"{args.command} started (cores={ctx.options.cores})")
        data = fn(ctx)
        ctx.write_result(data)
        return EXIT_OK
    except JobCancelled:
        emit.log("cancelled", level="warning")
        return EXIT_CANCELLED
    except EngineError as exc:
        emit.error(exc.msg, exc.detail)
        return EXIT_FAILED
    except Exception as exc:  # noqa: BLE001 - report anything else as a failure, never crash silently
        emit.error(f"{type(exc).__name__}: {exc}", traceback.format_exc())
        return EXIT_FAILED
    finally:
        if ctx is not None:
            try:
                ctx.cleanup()
            except JobCancelled:
                pass


if __name__ == "__main__":
    sys.exit(main())
