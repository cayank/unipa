"""Storage namespaces for the optional macOS Keychain compatibility layer."""

from __future__ import annotations

import os
import re
import stat
from pathlib import Path
from reader import MachOError

def keychain_configuration(bundle_id: str, instance: str) -> dict:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]{0,254}", bundle_id):
        raise MachOError("Isolated Keychain requires a valid bundle identifier")
    
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", instance):
        raise MachOError("Keychain instance must be 1–64 letters, digits, dots, underscores, or hyphens, starting with a letter or digit")
    
    bundle_id, instance = bundle_id.lower(), instance.lower()
    directory = Path.home() / "Library/Application Support/unipa/Keychain" / bundle_id
    return {
        "backend": "sqlite",
        "bundle_id": bundle_id,
        "instance": instance,
        "directory": str(directory),
        "database": str(directory / f"{instance}.db"),
    }

def prepare_keychain_directory(configuration: dict) -> None:
    base = Path.home() / "Library/Application Support"
    base.mkdir(parents=True, exist_ok=True)
    current = base
    for component in ("unipa", "Keychain", configuration["bundle_id"]):
        current /= component
        try:
            current.mkdir(mode=0o700)
        except FileExistsError:
            pass
        info = current.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise MachOError(f"Keychain directory must be owned by you, private (0700), and not a symlink: {current}")

