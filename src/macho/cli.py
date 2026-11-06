#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import plistlib
import stat
import sys
from pathlib import Path
from artifacts import write_json, write_new
from bundle import configure_bundle
from catalyst import check_runtime, convert_bundle
from inject import apply_injection, prepare_injection
from reader import (
    FAT_MAGICS,
    MAGIC,
    MH_BUNDLE,
    MH_DYLIB,
    MH_EXECUTE,
    Core,
    MachO,
    MachOError,
    analyze,
    choose_candidate,
    digest,
    patch_bytes,
)

MACHO_MAGICS = {
    MAGIC,
    *FAT_MAGICS,
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
}

def bundle_info(app: Path) -> dict:
    app = app.resolve(strict=True)
    with (app / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    executable_name = info.get("CFBundleExecutable")

    if (
        not isinstance(executable_name, str)
        or not executable_name
        or Path(executable_name).name != executable_name
    ):
        raise MachOError("Invalid CFBundleExecutable in Info.plist")

    executable = (app / executable_name).resolve(strict=True)
    if not executable.is_relative_to(app) or not executable.is_file():
        raise MachOError("Executable must be a file inside the selected app")

    return {
        "path": str(app),
        "executable": str(executable),
        "name": info.get("CFBundleDisplayName", info.get("CFBundleName", app.stem)),
        "bundle_id": info.get("CFBundleIdentifier", ""),
    }

def inspect_bundle(app: Path, excluded_extensions: list[str] | None = None) -> dict:
    info = bundle_info(app)
    app = Path(info["path"])
    main_binary = MachO(Path(info["executable"]).read_bytes())
    if main_binary.filetype != MH_EXECUTE:
        raise MachOError("CFBundleExecutable must be a Mach-O executable (MH_EXECUTE)")

    excluded = set(excluded_extensions or [])
    for name in excluded:
        if Path(name).name != name or not name.endswith(".appex"):
            raise MachOError("Excluded extensions must be .appex names inside PlugIns")
        extension = app / "PlugIns" / name
        if extension.is_symlink() or not extension.is_dir():
            raise MachOError(f"Invalid excluded extension: {extension}")

    encrypted = []
    binaries = []
    for root, dirs, files in os.walk(app, followlinks=False):
        if Path(root) == app / "PlugIns":
            dirs[:] = [name for name in dirs if name not in excluded]

        for name in dirs + files:
            item = Path(root) / name
            if item.is_symlink() and not item.resolve().is_relative_to(app):
                raise MachOError(f"Bundle symlink escapes app: {item}")

        for name in files:
            item = Path(root) / name
            if item.is_symlink():
                continue

            with item.open("rb") as handle:
                magic = handle.read(4)

            if magic not in MACHO_MAGICS:
                continue

            try:
                binary = MachO(item.read_bytes())
                if binary.filetype not in (MH_EXECUTE, MH_DYLIB, MH_BUNDLE):
                    continue

                binaries.append(str(item))
                if binary.encryption and binary.encryption.cryptid:
                    encrypted.append(str(item))
            except MachOError as error:
                raise MachOError(f"{item}: {error}") from error

    return {**info, "binaries": binaries, "encrypted": encrypted}

def recover(
    binary_path: Path, core_path: Path, output_dir: Path, base: int | None
) -> dict:
    original = binary_path.read_bytes()
    binary = MachO(original)

    with Core(core_path) as core:
        report = analyze(core, binary)
        output_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        write_json(output_dir / "analysis.json", report)
        candidate = choose_candidate(report, base)
        region = core.read(int(candidate["address"], 16), binary.encryption.cryptsize)

    patched = patch_bytes(original, region)
    region_path = output_dir / "region.bin"
    patched_path = output_dir / "executable.patched"
    mode = stat.S_IMODE(binary_path.stat().st_mode) | stat.S_IXUSR

    write_new(region_path, region)
    write_new(patched_path, patched, mode)
    if patched_path.read_bytes() != patched:
        raise MachOError("On-disk patch verification failed")

    report.update(
        {
            "selected": candidate,
            "output": str(patched_path),
            "region": str(region_path),
            "patched_sha256": digest(patched),
            "validation": "differs from disk; plaintext is not cryptographically verified",
        }
    )
    write_json(output_dir / "result.json", report)
    return report

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Inspect and recover Mach-O binaries.")
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("bundle-info", "inspect-bundle"):
        bundle = commands.add_parser(command)
        bundle.add_argument("--app", type=Path, required=True)
        if command == "inspect-bundle":
            bundle.add_argument("--exclude-extension", action="append", default=[])

    settings = commands.add_parser("configure-bundle")
    settings.add_argument("--app", type=Path, required=True)
    settings.add_argument("--bundle-id", nargs="?", const="")
    settings.add_argument("--bundle-name", nargs="?", const="")

    runtime = commands.add_parser("check-macos-runtime")
    runtime.add_argument("--app", type=Path, required=True)
    runtime.add_argument("--dylib", action="append", default=[])

    macos = commands.add_parser("convert-macos")
    macos.add_argument("--app", type=Path, required=True)
    macos.add_argument("--output-dir", type=Path, required=True)
    macos.add_argument("--identity", default="-")
    macos.add_argument("--incoming-network", action="store_true")
    macos.add_argument("--keychain-instance")
    macos.add_argument("--bundle-id", nargs="?", const="")
    macos.add_argument("--bundle-name", nargs="?", const="")

    prepare = commands.add_parser("prepare-injection")
    prepare.add_argument("--app", type=Path, required=True)
    prepare.add_argument("--dylib", type=Path, action="append", required=True)
    prepare.add_argument("--output-dir", type=Path, required=True)

    inject = commands.add_parser("inject")
    inject.add_argument("--app", type=Path, required=True)
    inject.add_argument("--prepared", type=Path, required=True)

    inspect = commands.add_parser("inspect")
    inspect.add_argument("--binary", type=Path, required=True)

    for command in ("analyze", "recover"):
        recovery = commands.add_parser(command)
        recovery.add_argument("--binary", type=Path, required=True)
        recovery.add_argument("--core", type=Path, required=True)

        if command == "recover":
            recovery.add_argument("--base", type=lambda value: int(value, 0))
            recovery.add_argument("--output-dir", type=Path, required=True)

    patch = commands.add_parser("patch")
    patch.add_argument("--binary", type=Path, required=True)
    patch.add_argument("--region", type=Path, required=True)
    patch.add_argument("--output", type=Path, required=True)

    return parser.parse_args()

def run_command(args: argparse.Namespace) -> dict:
    if args.command == "bundle-info":
        return bundle_info(args.app)

    if args.command == "inspect-bundle":
        return inspect_bundle(args.app, args.exclude_extension)

    if args.command == "configure-bundle":
        return configure_bundle(args.app, args.bundle_id, args.bundle_name)

    if args.command == "check-macos-runtime":
        return check_runtime(bundle_info(args.app), args.dylib)

    if args.command == "convert-macos":
        return convert_bundle(inspect_bundle(args.app), args.output_dir, args.identity, args.keychain_instance, args.bundle_id, args.bundle_name, incoming_network=args.incoming_network)

    if args.command == "prepare-injection":
        return prepare_injection(bundle_info(args.app), args.dylib, args.output_dir)

    if args.command == "inject":
        return apply_injection(bundle_info(args.app), args.prepared)

    if args.command == "recover":
        return recover(args.binary, args.core, args.output_dir, args.base)

    original = args.binary.read_bytes()
    binary = MachO(original)
    if args.command == "inspect":
        return binary.info()

    if args.command == "patch":
        patched = patch_bytes(original, args.region.read_bytes())
        mode = stat.S_IMODE(args.binary.stat().st_mode) | stat.S_IXUSR
        write_new(args.output, patched, mode)
        return {"output": str(args.output), "sha256": digest(patched)}

    with Core(args.core) as core:
        return analyze(core, binary)

def main() -> None:
    result = run_command(parse_args())
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"unipa: {error}", file=sys.stderr)
        sys.exit(1)
