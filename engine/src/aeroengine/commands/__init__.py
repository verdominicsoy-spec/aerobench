"""Command registry. Each command takes a JobContext and returns the result data."""

from __future__ import annotations

from typing import Callable

from ..job import JobContext

CommandFn = Callable[[JobContext], dict]
COMMANDS: dict[str, CommandFn] = {}


def command(name: str) -> Callable[[CommandFn], CommandFn]:
    def register(fn: CommandFn) -> CommandFn:
        COMMANDS[name] = fn
        return fn

    return register


# Import modules for their registration side effect.
from . import dummy, ping  # noqa: E402,F401
