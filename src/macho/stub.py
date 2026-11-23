"""Generate placeholder Mac Catalyst frameworks for iOS-only dependencies"""

from __future__ import annotations

import re
import subprocess
import tempfile
from pathlib import Path
from reader import MachO, MachOError
from load_commands import commands

ARM64 = 0x100000C
MAC_CATALYST = 6
DYLIB_COMMANDS = {0xC, 0x20, 0x80000018, 0x8000001F, 0x80000023}
SYSTEM_FRAMEWORK = "/System/Library/Frameworks/{name}.framework/{name}"
LOCAL_FRAMEWORK = "@executable_path/Frameworks/{name}.framework/{name}"
NUMERIC = {
    "Int", "Int8", "Int16", "Int32", "Int64",
    "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
    "Double", "Float", "CGFloat"
}

def run_tool(*arguments: str) -> str:
    result = subprocess.run(arguments, check=False, capture_output=True, text=True)
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise MachOError(f"{arguments[0]} exited with {result.returncode}: {detail}")
    return result.stdout.strip()

def interface_path(name: str) -> Path | None:
    sdk = Path(run_tool("/usr/bin/xcrun", "--sdk", "iphoneos", "--show-sdk-path"))
    modules = sdk / "System" / "Library" / "Frameworks" / f"{name}.framework" / "Modules" / f"{name}.swiftmodule"
    for candidate in ("arm64-apple-ios.swiftinterface", "arm64e-apple-ios.swiftinterface"):
        path = modules / candidate
        if path.exists():
            return path
    return None

def default_body(type_text: str, sequences: set[str]) -> str:
    text = type_text.strip()
    if text.endswith("?"):
        return "nil"
    if text.startswith("["):
        return "[]"
    base = text.rsplit(".", 1)[-1]
    if base == "Bool":
        return "false"
    if base in NUMERIC:
        return "0"
    if base == "String":
        return '""'
    if any(sequence in text for sequence in sequences):
        return ".init()"
    return "Swift.fatalError()"

def collect_sequences(lines: list[str]) -> set[str]:
    names = set()
    for line in lines:
        match = re.match(r"\s*(?:public\s+)?struct\s+(\w+)\s*:\s*.*AsyncSequence", line)
        if match:
            names.add(match.group(1))
    return names

def transform(interface: str) -> str:
    lines = interface.splitlines()
    sequences = collect_sequences(lines)
    out: list[str] = []
    pending: list[str] = []
    drop = ("@_implements", "__AsyncSequence_Failure", "__AsyncIteratorProtocol_Failure")
    last_type: str | None = None

    for raw in lines:
        stripped = raw.strip()
        indent = raw[: len(raw) - len(raw.lstrip())]
        if stripped.startswith("//"):
            continue
        if stripped.startswith("#if") or stripped in ("#else", "#endif"):
            continue
        if stripped.startswith("@_exported"):
            continue
        if stripped.startswith("public import"):
            module = stripped.split()[-1]
            if module in ("Foundation", "Combine"):
                out.append("import " + module)
            continue
        if any(token in stripped for token in drop):
            continue
        if stripped.startswith("@available") and "unavailable" in stripped:
            continue
        if stripped == "@objc deinit":
            continue

        raw = raw.replace("@_hasMissingDesignatedInitializers ", "")
        stripped = raw.strip()

        if stripped.startswith("@"):
            pending.append(raw)
            continue
        if stripped in ("", "}"):
            pending = []
            out.append(raw)
            continue

        out.extend(pending)
        pending = []

        header = re.match(r".*\b(?:var|let)\s+`?\w+`?\s*:\s*(.+?)\s*\{$", stripped)
        if header:
            last_type = header.group(1)

        if stripped == "get":
            out.append(indent + "get { " + default_body(last_type or "", sequences) + " }")
            continue
        if stripped == "set":
            out.append(indent + "set {}")
            continue

        stored = re.match(r"^(\s*)(.*?\b)(?:var|let)\s+(`?\w+`?)\s*:\s*(.+?)\s*$", raw)
        if stored and not stripped.endswith("{") and "=" not in stripped:
            lead, prefix, label, kind = stored.groups()
            out.append(f"{lead}{prefix}var {label}: {kind} {{ {default_body(kind, sequences)} }}")
            continue

        if re.search(r"\b(func|init)\b", stripped) and not stripped.endswith("{") and not stripped.endswith("}"):
            if "func makeAsyncIterator" in stripped:
                out.append(raw + " { .init() }")
            elif re.search(r"\bfunc next\b", stripped):
                out.append(raw + " { nil }")
            elif re.search(r"\binit\b", stripped):
                out.append(raw + (" {}" if re.search(r"\binit\s*\(\s*\)", stripped) else " { Swift.fatalError() }"))
            elif " -> " in stripped:
                out.append(raw + " { Swift.fatalError() }")
            else:
                out.append(raw + " {}")
            continue
        out.append(raw)
    return "\n".join(out)

def build_stub(name: str, frameworks: Path, deployment: str = "14.0") -> Path:
    interface = interface_path(name)
    if interface is None:
        raise MachOError(f"No Swift interface for {name}; cannot stub a non-Swift framework")

    source = transform(interface.read_text())
    framework = frameworks / f"{name}.framework"
    framework.mkdir(parents=True, exist_ok=True)
    binary = framework / name

    with tempfile.TemporaryDirectory() as workspace:
        swift = Path(workspace) / f"{name}.swift"
        swift.write_text(source)
        run_tool(
            "/usr/bin/xcrun", "-sdk", "macosx", "swiftc",
            "-emit-library", "-o", str(binary),
            "-module-name", name,
            "-target", f"arm64-apple-ios{deployment}-macabi",
            "-enable-library-evolution", "-swift-version", "5",
            "-Xlinker", "-install_name", "-Xlinker", LOCAL_FRAMEWORK.format(name=name),
            str(swift),
        )

    return binary

def retarget(binary: Path, name: str, install_name_tool: str) -> bool:
    data = MachO(binary.read_bytes())
    old = SYSTEM_FRAMEWORK.format(name=name)
    for command, offset, size in commands(data):
        if command not in DYLIB_COMMANDS:
            continue
        start = int.from_bytes(data.data[offset + 8: offset + 12], "little")
        value = data.data[offset + start: offset + size].split(b"\0", 1)[0].decode("utf-8", "replace")
        if value == old:
            run_tool(install_name_tool, "-change", old, LOCAL_FRAMEWORK.format(name=name), str(binary))
            return True
    return False