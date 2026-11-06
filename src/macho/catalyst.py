"""Build a separate Mac Catalyst copy of a decrypted iOS app."""

from __future__ import annotations

import json
import os
import plistlib
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from entitlements import compatibility_sandbox, configure_location_access, macos_entitlements
from reader import MachO, MachOError
from load_commands import add_dylibs, build_platform, dylib_names
from bundle import app_filename, apply_bundle_settings, bundle_settings, converted_bundle_id
from keychain import keychain_configuration, prepare_keychain_directory

ARM64 = 0x100000C
MACOS = 1
IOS = 2
MAC_CATALYST = 6
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

    try:
        platform = build_platform(binary)
        libraries = dylib_names(binary)
    except MachOError as error:
        raise MachOError(f"{path}: {error}") from error

    if platform not in (MACOS, IOS, MAC_CATALYST):
        raise MachOError(f"Unsupported build platform {platform}: {path}")
    return Binary(path.relative_to(app), platform, SWIFT_UIKIT in libraries)

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

def add_runtime_hooks(executable: Path, app: Path, isolated_keychain: bool = False) -> Binary:
    sdk = Path(run_tool("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"))
    hooks = Path(__file__).resolve().parents[1] / "hooks"
    library = app / "Frameworks" / "UnipaRuntime.dylib"
    library.parent.mkdir(exist_ok=True)
    if library.exists():
        raise MachOError(f"Runtime helper already exists: {library}")

    keychain_sources = []
    if isolated_keychain:
        keychain_sources = [
            "-framework", "Security", "-lsqlite3",
            str(hooks / "keychain.m"), str(hooks.parent / "keychain/store.m"),
        ]

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
        *keychain_sources,
        "-o",
        str(library),
    )

    executable.write_bytes(add_dylibs(executable.read_bytes(), [RUNTIME_LIBRARY]))
    return inspect_binary(library, app)

def convert_bundle(inspection: dict, output_dir: Path, identity: str, keychain_instance: str | None = None,
                   bundle_id_override: str | None = None, bundle_name: str | None = None) -> dict:
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

    default_id = converted_bundle_id(bundle_id, keychain_instance)
    settings = bundle_settings(
        bundle_id, inspection["name"], default_id if bundle_id_override is None else bundle_id_override, bundle_name
    )
    storage_id = settings["bundle_id"] if bundle_id_override is not None else bundle_id
    keychain = keychain_configuration(storage_id, keychain_instance) if keychain_instance is not None else None
    if keychain:
        keychain_instance = keychain["instance"]
        for item in inspection["binaries"]:
            libraries = dylib_names(MachO(Path(item).read_bytes()))
            if Path(item).name == "PlayTools" or any("PlayTools.framework/" in name for name in libraries):
                raise MachOError("Isolated Keychain cannot be combined with PlayTools; use the original decrypted app")

    binaries = [inspect_binary(Path(item), source) for item in inspection["binaries"]]
    main_relative = Path(inspection["executable"]).relative_to(source)
    main = next(binary for binary in binaries if binary.relative == main_relative)
    if main.platform not in (IOS, MAC_CATALYST):
        raise MachOError("macOS conversion expects an iOS or Mac Catalyst executable")
    
    vtool = run_tool("/usr/bin/xcrun", "--find", "vtool")
    install_name_tool = run_tool("/usr/bin/xcrun", "--find", "install_name_tool")

    output_dir.mkdir(parents=True, mode=0o700)
    output_name = app_filename(settings["name"], source.name)
    output = output_dir / output_name
    pending = output_dir / ".pending.app"
    report_path = output_dir / "conversion.json"
    report = {
        "status": "converting",
        "source": str(source),
        "app": str(output),
        "original_bundle_id": bundle_id,
        "bundle_id": settings["bundle_id"],
        "name": settings["name"],
        "keychain": keychain,
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

        apply_bundle_settings(
            pending, settings, update_name=bundle_name is not None, rename_app=False
        )

        for binary in binaries:
            path = pending / binary.relative
            if binary.platform == IOS:
                run_tool(vtool, "-set-build-version", "maccatalyst", "11.0", "14.0", "-replace", "-output", str(path), str(path))

            if binary.fix_swift_uikit:
                run_tool(install_name_tool, "-change", SWIFT_UIKIT, CATALYST_SWIFT_UIKIT, str(path))

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

            report_binary = {
                "binary": str(binary.relative),
                "original_platform": binary.platform,
                "platform": converted.platform,
                "swift_uikit_fixed": binary.fix_swift_uikit,
            }
            report["binaries"].append(report_binary)
            
        info_path = pending / "Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info.update(
            {
                "MinimumOSVersion": "11.0",
                "LSMinimumSystemVersion": "11.0",
                "UIDeviceFamily": [1],
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
            }
        )
        if keychain:
            info["UnipaKeychain"] = {"BundleIdentifier": keychain["bundle_id"], "Instance": keychain_instance}
        else:
            info.pop("UnipaKeychain", None)
        info.pop("UISupportedInterfaceOrientations~ipad", None)
        info.pop("UISupportedInterfaceOrientations~iphone", None)
        location_access = configure_location_access(info)
        info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        entitlements = output_dir / "entitlements.plist"
        if keychain:
            prepare_keychain_directory(keychain)
        entitlements.write_bytes(plistlib.dumps(macos_entitlements(
            Path(keychain["database"]) if keychain else None, location=location_access
        )))
        entitlements.chmod(0o600)
        report["compatibility_sandbox"] = compatibility_sandbox()

        executable = pending / main_relative
        helper = add_runtime_hooks(executable, pending, keychain is not None)
        binaries.append(helper)
        report_binary = {
            "binary": str(helper.relative),
            "original_platform": None,
            "platform": helper.platform,
            "swift_uikit_fixed": False
        }
        report["binaries"].append(report_binary)

        for target in signing_targets(pending, binaries, executable):
            run_tool("/usr/bin/codesign", "--force", "--sign", identity, str(target))
            run_tool("/usr/bin/codesign", "--verify", "--strict", str(target))
            report["signed_targets"].append(str(target.relative_to(pending)))

        run_tool("/usr/bin/codesign", "--force", "--sign", identity, "--entitlements", str(entitlements), str(pending))
        run_tool("/usr/bin/codesign", "--verify", "--deep", "--strict", str(pending))
        for binary in binaries:
            run_tool ("/usr/bin/codesign","--verify","--strict",str(pending / binary.relative))

        pending.rename(output)
        report["status"] = "ready"
    except (OSError, ValueError) as error:
        report["status"] = "failed"
        report["error"] = str(error)
        write_json(report_path, report)
        raise

    write_json(report_path, report)
    return report