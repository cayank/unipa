"""Shared bundle metadata for staged iOS apps and Mac conversions."""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import re
import subprocess
import tempfile
import uuid
from pathlib import Path
from reader import MachOError

def converted_bundle_id(bundle_id: str, instance: str | None) -> str:
    result = f"{bundle_id}.unipalocal"
    if instance is not None and instance.lower() != "default":
        suffix = hashlib.sha256(instance.lower().encode()).hexdigest()[:12]
        result += f".instance-{suffix}"
    return result

def bundle_settings(
    original_id: str,
    original_name: str,
    bundle_id: str | None,
    bundle_name: str | None,
) -> dict:
    random_id = bundle_id in ("", "random")
    random_name = bundle_name in ("", "random")
    suffix = uuid.uuid4().hex[:8] if random_id or random_name else None

    if bundle_id is None:
        identifier = original_id
    elif random_id:
        identifier = f"{original_id}.{suffix}"
    else:
        identifier = bundle_id

    if bundle_name is None:
        name = original_name
    elif random_name:
        name = f"{original_name}_{suffix}"
    else:
        name = bundle_name

    if len(identifier) > 255 or not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*", identifier):
        raise MachOError(
            "Bundle ID must contain only letters, digits, hyphens, and nonempty "
            "dot-separated components (maximum 255 characters)"
        )

    if bundle_name is not None:
        unsafe_name = (
            not name.strip()
            or name.startswith(".")
            or any(character in name for character in '/\\:')
            or any(ord(character) < 32 or ord(character) == 127 for character in name)
            or len((name + ".app").encode()) > 255
        )

        if unsafe_name:
            raise MachOError(
                "Bundle name must be a nonempty app name without path separators "
                "or control characters (maximum 251 UTF-8 bytes)"
            )
        
    return {"bundle_id": identifier, "name": name}

def app_filename(name: str, fallback: str) -> str:
    safe_name = re.sub(r"[/\\:\x00-\x1f\x7f]", "-", name).strip().lstrip(".")
    safe_name = safe_name.encode()[:251].decode("utf-8", errors="ignore").rstrip()
    return f"{safe_name}.app" if safe_name else fallback

def _read_info(path: Path, app: Path) -> dict:
    if not path.resolve(strict=True).is_relative_to(app):
        raise MachOError(f"Bundle metadata symlink escapes app: {path}")
    try:
        info = plistlib.loads(path.read_bytes())
    except plistlib.InvalidFileException:
        result = subprocess.run(
            ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)],
            capture_output=True, text=True, check=False,
        )
    
        if result.returncode:
            raise MachOError(f"Cannot read bundle metadata: {path}")
        info = json.loads(result.stdout)
    
    if not isinstance(info, dict):
        raise MachOError(f"Bundle metadata must be a dictionary: {path}")
    return info


def _write_info(path: Path, info: dict) -> None:
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        temporary.chmod(path.stat().st_mode & 0o777 | 0o200)
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)

def configure_bundle(app: Path, bundle_id: str | None, bundle_name: str | None) -> dict:
    app = app.resolve(strict=True)
    info_path = app / "Info.plist"
    info = _read_info(info_path, app)
    original_id = info.get("CFBundleIdentifier")
    if not isinstance(original_id, str) or not original_id:
        raise MachOError("Bundle settings require a CFBundleIdentifier")
    
    original_name = info.get("CFBundleDisplayName", info.get("CFBundleName", app.stem))
    if not isinstance(original_name, str) or not original_name:
        original_name = app.stem
        
    settings = bundle_settings(original_id, original_name, bundle_id, bundle_name)
    target = app if bundle_name is None else app.with_name(app_filename(settings["name"], app.name))
    if target != app and (target.exists() or target.is_symlink()):
        raise MachOError(f"Bundle destination already exists: {target}")

    changes = []
    nested_ids = []
    if bundle_id is not None:
        info["CFBundleIdentifier"] = settings["bundle_id"]
        for nested in app.rglob("Info.plist"):
            if nested == info_path or nested.parent.suffix not in (".app", ".appex"):
                continue

            child = _read_info(nested, app)
            identifier = child.get("CFBundleIdentifier")
            if isinstance(identifier, str) and identifier.startswith(original_id + "."):
                child["CFBundleIdentifier"] = settings["bundle_id"] + identifier[len(original_id):]
                if len(child["CFBundleIdentifier"]) > 255:
                    raise MachOError(f"Nested bundle identifier exceeds 255 characters: {nested}")
                changes.append((nested, child))
                nested_ids.append({"bundle": str(nested.parent.relative_to(app)), "bundle_id": child["CFBundleIdentifier"]})

    if bundle_name is not None:
        info["CFBundleName"] = settings["name"]
        info["CFBundleDisplayName"] = settings["name"]
        for localized in app.glob("*.lproj/InfoPlist.strings"):
            values = _read_info(localized, app)
            values["CFBundleName"] = settings["name"]
            values["CFBundleDisplayName"] = settings["name"]
            changes.append((localized, values))

    for file, values in [(info_path, info), *changes]:
        _write_info(file, values)

    if target != app:
        app.rename(target)
    return {"app": str(target), "original_bundle_id": original_id, **settings, "nested_bundles": nested_ids}