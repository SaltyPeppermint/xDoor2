import tomllib
from pathlib import Path

SUPPORTED_SCHEMA_VERSION = 1


def load_config(path: Path) -> dict:
    with open(path, "rb") as f:
        config = tomllib.load(f)

    version = config["schema_version"]
    if version != SUPPORTED_SCHEMA_VERSION:
        raise ValueError(f"unsupported config schema_version {version}")

    return config
