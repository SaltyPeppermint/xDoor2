import tomllib
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Protocol

SUPPORTED_SCHEMA_VERSION = 1


def load_config(path: Path) -> dict:
    with open(path, "rb") as f:
        config = tomllib.load(f)

    version = config["schema_version"]
    if version != SUPPORTED_SCHEMA_VERSION:
        raise ValueError(f"unsupported config schema_version {version}")

    return config


class WriterGone(Exception):
    """Writer disconnected while waiting for input"""


type WriteLine = Callable[[str], None]


class ReadLine(Protocol):
    def __call__(self, timeout: float | None = ...) -> Awaitable[str | None]:
        "Readline protocol, raises ClientGone if disconnect"


type DoorAction = Callable[[WriteLine, ReadLine], Awaitable[str]]
