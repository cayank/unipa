#!/usr/bin/env python3
"""Build unipa-flex.dylib from pinned sources and flex.patch"""

import os
import sys
import shutil
import subprocess
import json
import hashlib
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
CACHE = PROJECT / "dylibs/flex"
PATCH = Path(__file__).with_name("flex.patch")
OUTPUT = PROJECT / "dylibs/unipa-flex.dylib"
ENV = {**os.environ, "LC_ALL": "C", "LC_CTYPE": "C", "LANG": "C", "GIT_TERMINAL_PROMPT": "0"}
SOURCES = {
    "FLEX": ("https://github.com/FLEXTool/FLEX.git", "dac6130e0c7aca0bbf7ff8c0b57ba284776bfdff"),
    "PrisonFLEX": ("https://github.com/Uraniumm/PrisonFLEX.git", "3b756fac9df09299c8ab2eae6ffa3a5d62e15246"),
    "logos": ("https://github.com/theos/logos.git", "365a4e7028234e90bc2cbc724e5c87607130d3b3"),
}

def run(command, **options):
    return subprocess.run(command, check=True, env=ENV, **options)

def capture(command):
    return subprocess.check_output(command, text=True, env=ENV).strip()

def checkout(name, url, revision):
    directory = CACHE / "sources" / name
    if not directory.exists():
        directory.mkdir(parents=True)
        run(["git", "init", "--quiet", str(directory)])
        run(["git", "-C", str(directory), "remote", "add", "origin", url])

    head = subprocess.run(
        ["git", "-C", str(directory), "rev-parse", "HEAD"],
        capture_output=True, text=True, env=ENV,
    )

    if head.returncode:
        print(f"Fetching {name}…", flush=True)
        run(["git", "-C", str(directory), "fetch", "--depth=1", "origin", revision])
        run(["git", "-C", str(directory), "checkout", "--quiet", "--detach", "FETCH_HEAD"])
    elif head.stdout.strip() != revision:
        raise ValueError(f"{directory} has a different revision; move it aside and retry")
    return directory

def apply_patch(sources):
    patches = {}

    for block in PATCH.read_text().split("diff --git ")[1:]:
        name = block.splitlines()[0].split()[0].split("/")[1]

        if name not in ("FLEX", "PrisonFLEX"):
            raise ValueError(f"Unexpected source in flex.patch: {name}")
        
        patches[name] = patches.get(name, "") + "diff --git " + block
        
    if set(patches) != {"FLEX", "PrisonFLEX"}:
        raise ValueError("flex.patch must contain the FLEX and PrisonFLEX changes")
    
    for name, directory in sources.items():
        command = ["git", "-C", str(directory)]
        untracked = capture(command + ["ls-files", "--others"])
        if untracked:
            raise ValueError(f"{directory} has untracked files; move them aside and retry")

        patch = patches.get(name, "")
        current = subprocess.check_output(
            command + ["diff", "HEAD", "--no-ext-diff", "--no-color", "--binary",
                       f"--src-prefix=a/{name}/", f"--dst-prefix=b/{name}/"], env=ENV,
        ).decode()

        if current == patch:
            continue
        
        if current:
            raise ValueError(f"{sources[name]} has other edits; move it aside and retry")
        
        run(command + ["apply", "--check", "-p2", "-"], input=patch, text=True)
        run(command + ["apply", "-p2", "-"], input=patch, text=True)

def main():
    if sys.platform != "darwin":
        raise ValueError("Building FLEX requires macOS and Xcode with the iOS SDK")
    
    sdk = capture(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"])
    sources = {name: checkout(name, *source) for name, source in SOURCES.items()}
    apply_patch(sources)
    
    artifacts = CACHE / "artifacts"
    artifacts.mkdir(parents=True, exist_ok=True)
    generated = artifacts / "loader.generated.m"
    loader = artifacts / "loader.o"
    compile_command = [
        "xcrun", "--sdk", "iphoneos", "clang", "-target", "arm64-apple-ios15.0",
        "-isysroot", sdk, "-fobjc-arc", "-fmodules", "-O2",
        "-c", str(generated), "-o", str(loader),
    ]

    for directory in sorted({str(p.parent) for p in (sources["FLEX"] / "Classes").rglob("*.h")}):
        compile_command.extend(["-I", directory])
        
    build_command = [
        "xcodebuild", "-quiet", "-project", str(sources["FLEX"] / "FLEX.xcodeproj"),
        "-target", "FLEX", "-configuration", "Release", "-sdk", "iphoneos",
        "SYMROOT=" + str(artifacts / "Products"),
        "OBJROOT=" + str(artifacts / "Intermediates"),
        "-disableAutomaticPackageResolution", "-skipPackageUpdates",
        "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
        "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "IPHONEOS_DEPLOYMENT_TARGET=15.0",
        "LD_DYLIB_INSTALL_NAME=@rpath/unipa-flex.dylib",
        "OTHER_LDFLAGS=$(inherited) " + str(loader), "build",
    ]
    
    print("Building unipa-flex…", flush=True)
    log_path = CACHE / "build.log"
    with log_path.open("w") as log:
        with generated.open("w") as handle:
            run(["perl", str(sources["logos"] / "bin/logos.pl"), "-c", "generator=internal",
                 str(sources["PrisonFLEX"] / "Tweak.x")], stdout=handle, stderr=log)
            
        for command in (compile_command, build_command):
            log.write(json.dumps(command) + "\n")
            log.flush()
            run(command, stdout=log, stderr=subprocess.STDOUT)
            
    product = artifacts / "Products/Release-iphoneos/FLEX.framework/FLEX"
    pending = artifacts / "unipa-flex.pending.dylib"
    shutil.copy2(product, pending)
    pending.chmod(0o755)
    run(["codesign", "--force", "--sign", "-", str(pending)])
    run(["codesign", "--verify", "--strict", str(pending)])

    dependencies = capture(["otool", "-L", str(pending)])
    if any(name in dependencies.lower() for name in ("substrate", "libhooker", "ellekit")):
        raise ValueError("The dylib has an unexpected external hook-engine dependency")
    
    for name, directory in sources.items():
        licenses = list(directory.glob("LICENSE*"))
        if name == "FLEX":
            licenses.extend((directory / "Classes").rglob("LICENSE*"))

        for license_file in licenses:
            destination = CACHE / "licenses" / name / license_file.relative_to(directory)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(license_file, destination)
            
    os.replace(pending, OUTPUT)
    info = {
        "revisions": {name: revision for name, (_, revision) in SOURCES.items()},
        "patch_sha256": hashlib.sha256(PATCH.read_bytes()).hexdigest(),
        "output_sha256": hashlib.sha256(OUTPUT.read_bytes()).hexdigest(),
        "sdk": sdk,
    }
    (CACHE / "provenance.json").write_text(json.dumps(info, indent=2) + "\n")
    print(f"Built {OUTPUT}")

if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"build-flex: {error}\nBuild output: {CACHE / 'build.log'}", file=sys.stderr)
        sys.exit(1)