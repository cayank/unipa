from __future__ import annotations

import os
import posixpath
import shutil
import stat
import zipfile
from pathlib import Path, PurePosixPath
from reader import MachOError

def extract_ipa(archive: Path, destination: Path) -> Path:
    destination = destination.resolve(strict=True)
    if any(destination.iterdir()):
        raise MachOError("IPA extraction directory must be empty")

    try:
        source = zipfile.ZipFile(archive)
    except zipfile.BadZipFile as error:
        raise MachOError("Invalid IPA archive") from error

    with source:
        entries = source.infolist()
        paths = {}
        apps = set()
        for entry in entries:
            name = entry.filename.rstrip("/")
            parts = name.split("/")
            if not name or name.startswith("/") or "\\" in name or any(part in ("", ".", "..") for part in parts):
                raise MachOError(f"Invalid IPA entry: {entry.filename}")
            key = name.casefold()
            if key in paths:
                raise MachOError(f"Duplicate IPA entry: {name}")
            paths[key] = entry
            if len(parts) >= 2 and parts[0] == "Payload" and parts[1].endswith(".app"):
                apps.add(parts[1])

        if len(apps) != 1:
            raise MachOError("IPA must contain exactly one app inside Payload")
        app = PurePosixPath("Payload", apps.pop())
        selected = [(PurePosixPath(entry.filename), entry) for entry in entries
                    if PurePosixPath(entry.filename).is_relative_to(app)]
        links = []
        for relative, entry in selected:
            for parent in relative.parents:
                ancestor = paths.get(str(parent).casefold())
                if ancestor is not None and not ancestor.is_dir():
                    raise MachOError(f"IPA entry has a non-directory parent: {relative}")
                
            target = destination / str(relative)
            mode = entry.external_attr >> 16
            kind = stat.S_IFMT(mode)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK):
                raise MachOError(f"Unsupported IPA entry: {relative}")
            
            if stat.S_ISLNK(mode):
                if entry.file_size > 4096:
                    raise MachOError(f"Invalid IPA symlink: {relative}")
                link = source.read(entry).decode("utf-8")
                resolved = PurePosixPath(posixpath.normpath(str(relative.parent / link)))
                if not link or "\\" in link or "\x00" in link or PurePosixPath(link).is_absolute() or not resolved.is_relative_to(app):
                    raise MachOError(f"IPA symlink escapes app: {relative}")
                links.append((target, link))
            elif entry.is_dir():
                target.mkdir(parents=True, exist_ok=True, mode=0o700)
            else:
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                with source.open(entry) as incoming, target.open("xb") as outgoing:
                    shutil.copyfileobj(incoming, outgoing)
                target.chmod((stat.S_IMODE(mode) & 0o777) | 0o600)

        for target, link in links:
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            os.symlink(link, target)

    return destination / str(app)