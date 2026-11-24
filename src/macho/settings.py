"""Storage namespace for unipa's own per-app settings file"""

from __future__ import annotations

import os
import stat
from pathlib import Path
from reader import MachOError

def settings_directory(bundle_id: str) -> Path:
    return Path.home() / "Library/Application Support/unipa/Settings" / bundle_id

def prepare_settings_directory(bundle_id: str) -> Path:
    base = Path.home() / "Library/Application Support"
    base.mkdir(parents=True, exist_ok=True)
    current = base
    for component in ("unipa", "Settings", bundle_id):
        current /= component
        try:
            current.mkdir(mode=0o700)
        except FileExistsError:
            pass
        info = current.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise MachOError(f"Settings directory must be owned by you, private (0700), and not a symlink: {current}")
    return current
