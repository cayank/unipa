"""Build a separate Mac Catalyst copy of a decrypted iOS app."""

from __future__ import annotations

import json
import os
import plistlib
import shutil
import struct
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

from entitlements import compatibility_sandbox, macos_entitlements
from reader import MachO, MachOError

ARM64 = 0x100000C
MACOS = 1
IOS = 2
MAC_CATALYST = 6
LC_BUILD_VERSION = 0x32
VERSION_COMMANDS = {0x24: MACOS, 0x25: IOS}
DYLIB_COMMANDS = {0xC, 0x80000018, 0x8000001F, 0x80000023}
SWIFT_UIKIT = "@rpath/libswiftUIKit.dylib"
CATALYST_SWIFT_UIKIT = "/System/iOSSupport/usr/lib/swift/libswiftUIKit.dylib"
RUNTIME_LIBRARY = "@executable_path/Frameworks/UnipaRuntime.dylib"


@dataclass(frozen=True)
class Binary:
    relative: Path
    platform: int
    fix_swift_uikit: bool

def inspect_binary(path: Path, app: Path) -> Binary:
    data = path.read_bytes()
    binary = MachO(data)
    if binary.cpu != ARM64:
        raise MachOError(f"Mac Catalyst conversion requires arm64: {path}")
    if binary.encryption and binary.encryption.cryptid:
        raise MachOError(f"Decrypt the binary before macOS conversion: {path}")

    platforms = []
    fix_swift_uikit = False
    offset = 32
    while offset < binary.header_size:
        command, size = struct.unpack_from("<II", data, offset)
        if command == LC_BUILD_VERSION:
            if size < 24:
                raise MachOError(f"Truncated LC_BUILD_VERSION: {path}")
            platform, _, _, tools = struct.unpack_from("<4I", data, offset + 8)
            if 24 + tools * 8 > size:
                raise MachOError(f"Truncated build tool table: {path}")
            platforms.append(platform)
        elif command in VERSION_COMMANDS:
            if size < 16:
                raise MachOError(f"Truncated minimum OS command: {path}")
            platforms.append(VERSION_COMMANDS[command])
        elif command in DYLIB_COMMANDS:
            if size < 24:
                raise MachOError(f"Truncated dylib command: {path}")
            start = struct.unpack_from("<I", data, offset + 8)[0]
            if not 24 <= start < size:
                raise MachOError(f"Invalid dylib name offset: {path}")
            name = data[offset + start : offset + size]
            if b"\0" not in name:
                raise MachOError(f"Unterminated dylib name: {path}")
            fix_swift_uikit |= name.split(b"\0", 1)[0] == SWIFT_UIKIT.encode()
        offset += size

    if len(platforms) != 1 or platforms[0] not in (MACOS, IOS, MAC_CATALYST):
        raise MachOError(f"Unsupported or missing build platform {platforms}: {path}")
    return Binary(path.relative_to(app), platforms[0], fix_swift_uikit)

def run_tool(*arguments: str) -> str:
    result = subprocess.run(arguments, check=False, capture_output=True, text=True)
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise MachOError(f"{arguments[0]} exited with {result.returncode}: {detail}")

    return result.stdout.strip()

def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n")
    path.chmod(0o600)

def signing_targets(app: Path, binaries: list[Binary], executable: Path) -> list[Path]:
    targets = set()
    for binary in binaries:
        path = app / binary.relative
        if path != executable:
            targets.add(path)
        for parent in path.parents:
            if parent == app:
                break
            if parent.suffix in (".framework", ".bundle", ".app", ".xpc"):
                targets.add(parent)

    return sorted(targets, key=lambda target: (-len(target.parts), str(target)))

def add_runtime_hooks(executable: Path, app: Path) -> Binary:
    sdk = Path(run_tool("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"))
    hooks = Path(__file__).resolve().parents[1] / "hooks"
    library = app / "Frameworks" / "UnipaRuntime.dylib"
    library.parent.mkdir(exist_ok=True)
    if library.exists():
        raise MachOError(f"Runtime helper already exists: {library}")

    run_tool(
        "/usr/bin/xcrun",
        "clang",
        "-arch",
        "arm64",
        "-mmacosx-version-min=11.0",
        "-isysroot",
        str(sdk),
        "-dynamiclib",
        "-fobjc-arc",
        "-framework",
        "AppKit",
        "-framework",
        "Foundation",
        "-Wl,-install_name," + RUNTIME_LIBRARY,
        str(hooks / "window-geometry.m"),
        str(hooks / "runtime-environment.m"),
        "-o",
        str(library),
    )

    link_runtime_hooks(executable)
    return inspect_binary(library, app)

def link_runtime_hooks(executable: Path) -> None:
    data = bytearray(executable.read_bytes())
    binary = MachO(data)
    content_offsets = []
    offset = 32
    while offset < binary.header_size:
        command, size = struct.unpack_from("<II", data, offset)
        if command == 0x19:
            fileoff, filesize = struct.unpack_from("<QQ", data, offset + 40)
            if fileoff and filesize:
                content_offsets.append(fileoff)
            sections = struct.unpack_from("<I", data, offset + 64)[0]
            for index in range(sections):
                section = offset + 72 + index * 80
                section_size = struct.unpack_from("<Q", data, section + 40)[0]
                file_offset = struct.unpack_from("<I", data, section + 48)[0]
                if section_size and file_offset:
                    content_offsets.append(file_offset)
        offset += size

    name = RUNTIME_LIBRARY.encode() + b"\0"
    size = (24 + len(name) + 7) // 8 * 8
    start = binary.header_size
    end = start + size
    if not content_offsets or end > min(content_offsets) or any(data[start:end]):
        raise MachOError("Not enough unused Mach-O header space for the runtime helper")
    command = struct.pack("<6I", 0xC, size, 24, 0, 0, 0) + name
    data[start:end] = command.ljust(size, b"\0")
    count, command_bytes = struct.unpack_from("<II", data, 16)
    struct.pack_into("<II", data, 16, count + 1, command_bytes + size)
    MachO(data)
    executable.write_bytes(data)

def convert_bundle(inspection: dict, output_dir: Path, identity: str) -> dict:
    source = Path(inspection["path"])
    output_dir = output_dir.resolve()
    if output_dir.is_relative_to(source):
        raise MachOError("macOS output directory cannot be inside the source app")
    if inspection["encrypted"]:
        raise MachOError("Decrypt all binaries before macOS conversion")
    if any(source.rglob("*.appex")):
        raise MachOError("macOS conversion does not support retained iOS extensions")
    bundle_id = inspection["bundle_id"]
    if not isinstance(bundle_id, str) or not bundle_id:
        raise MachOError("macOS conversion requires a CFBundleIdentifier")

    binaries = [inspect_binary(Path(item), source) for item in inspection["binaries"]]
    main_relative = Path(inspection["executable"]).relative_to(source)
    main = next(binary for binary in binaries if binary.relative == main_relative)
    if main.platform not in (IOS, MAC_CATALYST):
        raise MachOError("macOS conversion expects an iOS or Mac Catalyst executable")
    vtool = run_tool("/usr/bin/xcrun", "--find", "vtool")
    install_name_tool = run_tool("/usr/bin/xcrun", "--find", "install_name_tool")

    output_dir.mkdir(parents=True, mode=0o700)
    output = output_dir / source.name
    pending = output_dir / f".{source.stem}.pending.app"
    report_path = output_dir / "conversion.json"
    report = {
        "status": "converting",
        "source": str(source),
        "app": str(output),
        "original_bundle_id": bundle_id,
        "bundle_id": f"{bundle_id}.unipalocal",
        "identity": identity,
        "binaries": [],
        "signed_targets": [],
        "runtime": {
            "working_directory": "/",
            "library": "Frameworks/UnipaRuntime.dylib",
        },
        "window_geometry": {
            "width": 390,
            "height": 844,
            "resizable": True,
            "lock_aspect_ratio": True,
            "library": "Frameworks/UnipaRuntime.dylib",
        },
    }
    write_json(report_path, report)

    try:
        shutil.copytree(source, pending, symlinks=True)
        for item in pending.rglob("*"):
            if item.is_symlink() and not item.resolve().is_relative_to(pending):
                raise MachOError(f"Copied bundle symlink escapes app: {item}")

        for binary in binaries:
            path = pending / binary.relative
            if binary.platform == IOS:
                run_tool(
                    vtool,
                    "-set-build-version",
                    "maccatalyst",
                    "11.0",
                    "14.0",
                    "-replace",
                    "-output",
                    str(path),
                    str(path),
                )
            if binary.fix_swift_uikit:
                run_tool(
                    install_name_tool,
                    "-change",
                    SWIFT_UIKIT,
                    CATALYST_SWIFT_UIKIT,
                    str(path),
                )
            descriptor, temporary = tempfile.mkstemp(dir=path.parent)
            os.close(descriptor)
            try:
                shutil.copy2(path, temporary)
                os.replace(temporary, path)
            finally:
                Path(temporary).unlink(missing_ok=True)

            converted = inspect_binary(path, pending)
            expected = MAC_CATALYST if binary.platform == IOS else binary.platform
            if converted.platform != expected or converted.fix_swift_uikit:
                raise MachOError(f"macOS conversion verification failed: {path}")
            report["binaries"].append(
                {
                    "binary": str(binary.relative),
                    "original_platform": binary.platform,
                    "platform": converted.platform,
                    "swift_uikit_fixed": binary.fix_swift_uikit,
                }
            )

        info_path = pending / "Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info.setdefault("CFBundleName", inspection["name"])
        info.setdefault("CFBundleDisplayName", inspection["name"])
        info.update(
            {
                "CFBundleIdentifier": report["bundle_id"],
                "MinimumOSVersion": "11.0",
                "LSMinimumSystemVersion": "11.0",
                "UIDeviceFamily": [1],
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
            }
        )
        info.pop("UISupportedInterfaceOrientations~ipad", None)
        info.pop("UISupportedInterfaceOrientations~iphone", None)
        info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        entitlements = output_dir / "entitlements.plist"
        entitlements.write_bytes(plistlib.dumps(macos_entitlements()))
        entitlements.chmod(0o600)
        report["compatibility_sandbox"] = compatibility_sandbox()

        executable = pending / main_relative
        helper = add_runtime_hooks(executable, pending)
        binaries.append(helper)
        report["binaries"].append(
            {
                "binary": str(helper.relative),
                "original_platform": None,
                "platform": helper.platform,
                "swift_uikit_fixed": False,
            }
        )
        for target in signing_targets(pending, binaries, executable):
            run_tool("/usr/bin/codesign", "--force", "--sign", identity, str(target))
            run_tool("/usr/bin/codesign", "--verify", "--strict", str(target))
            report["signed_targets"].append(str(target.relative_to(pending)))
        run_tool(
            "/usr/bin/codesign",
            "--force",
            "--sign",
            identity,
            "--entitlements",
            str(entitlements),
            str(pending),
        )
        run_tool(
            "/usr/bin/codesign",
            "--verify",
            "--deep",
            "--strict",
            str(pending),
        )
        for binary in binaries:
            run_tool(
                "/usr/bin/codesign",
                "--verify",
                "--strict",
                str(pending / binary.relative),
            )

        pending.rename(output)
        report["status"] = "ready"
    except (OSError, ValueError) as error:
        report["status"] = "failed"
        report["error"] = str(error)
        write_json(report_path, report)
        raise

    write_json(report_path, report)
    return report
