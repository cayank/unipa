"""Prepare local dylibs and embed them into a recovered iOS or Mac Catalyst app"""

from __future__ import annotations

import gzip
import io
import json
import lzma
import os
import stat
import subprocess
import tempfile
from pathlib import Path
from universal import architecture_score, select_slice
from artifacts import write_json, write_new
from load_commands import add_dylibs, build_platform, build_version
from reader import MH_DYLIB, MH_EXECUTE, MachO, MachOError, digest

IOS = 2
MAC_CATALYST = 6
TARGET_PLATFORMS = (IOS, MAC_CATALYST)
MAX_LIBRARY_BYTES = 256 * 1024 * 1024
SCHEMA = "unipa-injection-v1"

def retag_catalyst(data: bytes) -> bytes:
    _, sdk = build_version(MachO(data))
    version = tuple(int(part) for part in sdk.split("."))
    sdk = sdk if version >= (14, 0) else "14.0"
    descriptor, path = tempfile.mkstemp(suffix=".dylib")
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
        result = subprocess.run(
            ["/usr/bin/xcrun", "vtool", "-set-build-version", "maccatalyst", "11.0", sdk, "-replace", "-output", path, path],
            capture_output=True, text=True,
        )
        if result.returncode:
            raise MachOError(f"Could not retag the dylib for Mac Catalyst: {result.stderr.strip()}")
        return Path(path).read_bytes()
    finally:
        Path(path).unlink(missing_ok=True)

def bounded_read(handle) -> bytes:
    data = handle.read(MAX_LIBRARY_BYTES + 1)
    if len(data) > MAX_LIBRARY_BYTES:
        raise MachOError("Dylib exceeds the 256 MiB size limit")
    
    return data

def read_library(source: Path, target: MachO) -> tuple[str, bytes, dict, bytes | None]:
    input_path = source.expanduser().absolute()
    source = input_path.resolve(strict=True)
    if not source.is_file():
        raise MachOError(f"Dylib must be a regular file: {source}")
    
    with source.open("rb") as handle:
        original = bounded_read(handle)
    data = original
    name = input_path.name

    try:
        if name.lower().endswith(".gz"):
            name = name[:-3]
            with gzip.GzipFile(fileobj=io.BytesIO(data)) as handle:
                data = bounded_read(handle)
        elif name.lower().endswith(".xz"):
            name = name[:-3]
            with lzma.LZMAFile(io.BytesIO(data)) as handle:
                data = bounded_read(handle)
    except (OSError, EOFError, lzma.LZMAError) as error:
        raise MachOError(f"Cannot decompress dylib {source}: {error}") from error
    
    if not name.lower().endswith(".dylib") or any(ord(char) < 32 for char in name):
        raise MachOError("--inject expects a .dylib, .dylib.gz, or .dylib.xz file")
    
    data, thinned = select_slice(data, target)
    binary = MachO(data)

    if binary.filetype != MH_DYLIB:
        raise MachOError(f"Not a Mach-O dynamic library: {source}")
    
    if binary.encryption and binary.encryption.cryptid:
        raise MachOError(f"Injected dylib must already be decrypted: {source}")

    host_platform = build_platform(target)
    if host_platform == MAC_CATALYST and build_platform(binary) == IOS:
        data = retag_catalyst(data)
        binary = MachO(data)
    if build_platform(binary) != host_platform:
        target_name = "Mac Catalyst" if host_platform == MAC_CATALYST else "iOS devices"
        raise MachOError(f"Injected dylib must target {target_name}: {source}")

    config_path = input_path.with_name(name[:-6] + ".config")
    config = None

    if config_path.exists():
        if not config_path.is_file():
            raise MachOError(f"Dylib config must be a regular file: {config_path}")
        
        with config_path.open("rb") as handle:
            config = bounded_read(handle)

    relative = "Frameworks/" + name
    metadata = {
        "source": str(source),
        "binary": relative,
        "load_command": "@executable_path/" + relative,
        "source_sha256": digest(original),
        "prepared_sha256": digest(data),
        "thinned": thinned,
        "config": "Frameworks/" + config_path.name if config is not None else None,
        "config_sha256": digest(config) if config is not None else None,
    }
    return name, data, metadata, config


def check_destinations(app: Path, libraries: list[dict]) -> None:
    frameworks = app / "Frameworks"
    if frameworks.is_symlink() or (frameworks.exists() and not frameworks.is_dir()):
        raise MachOError("Frameworks must be a directory, not a symlink or file")

    names = (
        {entry.name.casefold() for entry in frameworks.iterdir()}
        if frameworks.exists()
        else set()
    )

    for library in libraries:
        for relative in (library["binary"], library["config"]):
            if relative is None:
                continue

            path = Path(relative)
            if path.parts != ("Frameworks", path.name) or any(ord(char) < 32 for char in path.name):
                raise MachOError("Invalid injection destination")
            
            if path.name.casefold() in names:
                raise MachOError(f"Injection destination already exists or is duplicated: {relative}")
            names.add(path.name.casefold())

def prepare_injection(info: dict, sources: list[Path], output_dir: Path) -> dict:
    app = Path(info["path"])
    output_dir = output_dir.resolve()
    if output_dir.is_relative_to(app):
        raise MachOError("Injection staging directory cannot be inside the source app")
    
    target_data = Path(info["executable"]).read_bytes()
    target = MachO(target_data)

    if target.filetype != MH_EXECUTE or build_platform(target) not in TARGET_PLATFORMS:
        raise MachOError("--inject requires an iOS or Mac Catalyst executable")
    
    if not sources:
        raise MachOError("No dylibs supplied for injection")
    
    prepared = [read_library(source, target) for source in sources]
    libraries = [item[2] for item in prepared]
    check_destinations(app, libraries)
    add_dylibs(target_data, [item["load_command"] for item in libraries])

    output_dir.mkdir(parents=True, mode=0o700)
    files = output_dir / "files"
    files.mkdir(mode=0o700)

    for name, data, metadata, config in prepared:
        write_new(files / name, data, 0o755)
        if config is not None:
            write_new(files / Path(metadata["config"]).name, config)

    plan = {
        "schema": SCHEMA,
        "directory": str(output_dir),
        "cpu": target.cpu,
        "subtype": target.subtype,
        "libraries": libraries,
    }
    write_json(output_dir / "plan.json", plan)
    return plan

def apply_injection(info: dict, prepared_dir: Path) -> dict:
    app = Path(info["path"])
    executable = Path(info["executable"])
    prepared_dir = prepared_dir.resolve(strict=True)
    if prepared_dir.is_relative_to(app):
        raise MachOError("Prepared injection files cannot be inside the app")
    
    plan = json.loads((prepared_dir / "plan.json").read_text())
    if (
        not isinstance(plan, dict)
        or plan.get("schema") != SCHEMA
        or not isinstance(plan.get("libraries"), list)
        or not plan["libraries"]
    ):
        raise MachOError("Invalid injection plan")
    
    target = MachO(executable.read_bytes())
    if target.encryption and target.encryption.cryptid:
        raise MachOError("Recover the executable before injecting dylibs")
    
    host_platform = build_platform(target)
    if (target.cpu, target.subtype) != (plan["cpu"], plan["subtype"]) or host_platform not in TARGET_PLATFORMS:
        raise MachOError("Prepared injection does not match the output app")
    
    libraries = plan["libraries"]
    check_destinations(app, libraries)

    files = {}
    for library in libraries:
        expected_load = "@executable_path/" + library["binary"]
        if library["load_command"] != expected_load:
            raise MachOError("Invalid injection load path")
        
        for relative, expected in (
            (library["binary"], library["prepared_sha256"]),
            (library["config"], library["config_sha256"]),
        ):
            if relative is None:
                continue

            source = prepared_dir / "files" / Path(relative).name
            if source.is_symlink() or not source.is_file():
                raise MachOError(
                    f"Prepared injection file is missing or is a symlink: {source}"
                )
            
            data = source.read_bytes()
            if digest(data) != expected:
                raise MachOError(f"Prepared injection file changed: {source}")
            
            files[relative] = data

        binary = MachO(files[library["binary"]])
        if (
            binary.filetype != MH_DYLIB
            or build_platform(binary) != host_platform
            or not architecture_score(binary.cpu, binary.subtype, target)
            or (binary.encryption and binary.encryption.cryptid)
        ):
            raise MachOError("Prepared dylib is incompatible with the app")

    patched = add_dylibs(target.data, [item["load_command"] for item in libraries])
    frameworks = app / "Frameworks"
    frameworks.mkdir(exist_ok=True)
    created = []
    temporary = None
    
    try:
        for relative, data in files.items():
            destination = app / relative
            write_new( destination, data, 0o755 if relative.lower().endswith(".dylib") else 0o600)
            created.append(destination)

        descriptor, temporary = tempfile.mkstemp(dir=executable.parent)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(patched)

        Path(temporary).chmod(stat.S_IMODE(executable.stat().st_mode))
        os.replace(temporary, executable)
    except OSError:
        for destination in created:
            destination.unlink(missing_ok=True)
        raise
    finally:
        if temporary is not None:
            Path(temporary).unlink(missing_ok=True)

    result = {"executable": str(executable.relative_to(app)), "libraries": libraries}
    write_json(prepared_dir / "result.json", result)
    return result