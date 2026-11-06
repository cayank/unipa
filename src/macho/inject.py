"""Prepare local dylibs and embed them into a recovered iOS app"""

from __future__ import annotations

import gzip
import io
import json
import lzma
import os
import stat
import struct
import tempfile
from pathlib import Path
from load_commands import add_dylibs, build_platform
from reader import FAT_MAGICS, MH_DYLIB, MH_EXECUTE, MachO, MachOError, digest

IOS = 2
MAX_LIBRARY_BYTES = 256 * 1024 * 1024
SCHEMA = "unipa-injection-v1"
FAT_FORMATS = {
    b"\xca\xfe\xba\xbe": (">", False),
    b"\xbe\xba\xfe\xca": ("<", False),
    b"\xca\xfe\xba\xbf": (">", True),
    b"\xbf\xba\xfe\xca": ("<", True),
}

def architecture_score(cpu: int, subtype: int, target: MachO) -> int:
    if cpu != target.cpu:
        return 0
    
    if subtype == target.subtype:
        return 2
    
    if (cpu == 0x100000C and subtype == 0) or (cpu == 0x1000007 and subtype == 3):
        return 1
    
    return 0

def select_slice(data: bytes, target: MachO) -> tuple[bytes, bool]:
    if data[:4] not in FAT_MAGICS:
        binary = MachO(data)
        if not architecture_score(binary.cpu, binary.subtype, target):
            raise MachOError("Dylib architecture does not match the app")
        
        return data, False

    if len(data) < 8:
        raise MachOError("Truncated universal header")
    
    endian, wide = FAT_FORMATS[data[:4]]
    count = struct.unpack_from(endian + "I", data, 4)[0]
    record_size = 32 if wide else 20
    table_end = 8 + count * record_size

    if not count or table_end > len(data):
        raise MachOError("Invalid universal architecture table")

    slices = []
    ranges = []
    for index in range(count):
        record = struct.unpack_from(
            endian + ("IIQQII" if wide else "IIIII"), data, 8 + index * record_size
        )
        cpu, subtype, offset, size, alignment = record[:5]

        if (
            alignment > (63 if wide else 31)
            or offset < table_end
            or not size
            or offset + size > len(data)
            or offset % (1 << alignment)
            or (wide and record[5])
        ):
            raise MachOError("Invalid universal slice range or alignment")
        
        ranges.append((offset, offset + size))
        score = architecture_score(cpu, subtype, target)
        if score:
            slices.append((score, cpu, subtype, offset, size))

    ranges.sort()
    if any(left[1] > right[0] for left, right in zip(ranges, ranges[1:])):
        raise MachOError("Universal slices overlap")
    
    if not slices:
        raise MachOError("Universal dylib has no architecture matching the app")
    
    best = max(item[0] for item in slices)
    matches = [item for item in slices if item[0] == best]
    if len(matches) != 1:
        raise MachOError("Universal dylib has ambiguous matching architectures")
    
    _, cpu, subtype, offset, size = matches[0]
    selected = data[offset : offset + size]
    binary = MachO(selected)
    if (binary.cpu, binary.subtype) != (cpu, subtype):
        raise MachOError("Universal slice header disagrees with its architecture table")
    
    return selected, True

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
    
    if build_platform(binary) != IOS:
        raise MachOError(f"Injected dylib must target iOS devices: {source}")

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

def write_new(path: Path, data: bytes, mode: int = 0o600) -> None:
    with path.open("xb") as handle:
        handle.write(data)

    path.chmod(mode)

def prepare_injection(info: dict, sources: list[Path], output_dir: Path) -> dict:
    app = Path(info["path"])
    output_dir = output_dir.resolve()
    if output_dir.is_relative_to(app):
        raise MachOError("Injection staging directory cannot be inside the source app")
    
    target_data = Path(info["executable"]).read_bytes()
    target = MachO(target_data)

    if target.filetype != MH_EXECUTE or build_platform(target) != IOS:
        raise MachOError("--inject requires an iOS device executable")
    
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
    write_new(output_dir / "plan.json", (json.dumps(plan, indent=2) + "\n").encode())
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
    
    if (target.cpu, target.subtype) != (plan["cpu"], plan["subtype"]) or build_platform(target) != IOS:
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
            or build_platform(binary) != IOS
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
    write_new(prepared_dir / "result.json", (json.dumps(result, indent=2) + "\n").encode())
    return result