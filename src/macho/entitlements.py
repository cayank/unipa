"""Sandbox settings for converted apps"""

from pathlib import Path

DENIED_FILES = (
    "/.cydia_no_stash",
    "/bin/bash",
    "/bin/sh",
    "/bin/su",
    "/usr/bin/ssh",
    "/usr/bin/sshd",
    "/usr/sbin/sshd",
    "/usr/libexec/ssh-keysign",
    "/usr/libexec/sftp-server",
    "/etc/ssh/sshd_config",
    "/private/etc/ssh/sshd_config",
    "/usr/sbin/frida-server",
    "/usr/bin/cycript",
    "/usr/local/bin/cycript",
    "/usr/lib/libcycript.dylib",
    "/usr/lib/libjailbreak.dylib",
    "/System/Library/LaunchDaemons/com.saurik.Cydia.Startup.plist",
)

DENIED_DIRECTORIES = (
    "/Applications/Cydia.app",
    "/Library/MobileSubstrate",
    "/Library/PreferenceBundles/LaunchInSafeMode.bundle",
    "/etc/apt",
    "/private/etc/apt",
    "/var/cache/apt",
    "/private/var/cache/apt",
    "/var/lib/apt",
    "/private/var/lib/apt",
    "/var/lib/cydia",
    "/private/var/lib/cydia",
    "/var/stash",
    "/private/var/stash",
    "/var/jb",
    "/private/var/jb",
    "/jb",
    "/usr/libexec/cydia",
    "/usr/share/jailbreak",
)

def compatibility_sandbox() -> dict:
    return {
        "deny_process_fork": True,
        "denied_files": list(DENIED_FILES),
        "denied_directories": list(DENIED_DIRECTORIES),
    }

# preserve declared location access and supply the macOS purpose string
def configure_location_access(info: dict) -> bool:
    for key in (
        "NSLocationUsageDescription",
        "NSLocationWhenInUseUsageDescription",
        "NSLocationAlwaysAndWhenInUseUsageDescription",
        "NSLocationAlwaysUsageDescription",
    ):
        description = info.get(key)
        if isinstance(description, str) and description.strip():
            info["NSLocationUsageDescription"] = description
            return True
    return False

# restrict host features that an iOS app may mistake for a jailbreak
def macos_entitlements(keychain_database: Path | None = None, *, location: bool = False) -> dict:
    rules = ["(deny process-fork)"]
    operations = "file* file-read* file-read-metadata file-ioctl"
    rules.extend(f'(deny {operations} (literal "{path}"))' for path in DENIED_FILES)
    rules.extend(
        f'(deny {operations} (subpath "{path}"))' for path in DENIED_DIRECTORIES
    )
    entitlements = {
        "com.apple.security.app-sandbox": True,
        "com.apple.security.network.client": True,
        "com.apple.security.temporary-exception.sbpl": rules,
    }

    if location:
        entitlements["com.apple.security.personal-information.location"] = True

    if keychain_database is not None:
        relative = keychain_database.relative_to(Path.home())
        entitlements["com.apple.security.temporary-exception.files.home-relative-path.read-write"] = [
            f"/{relative}{suffix}" for suffix in ("", "-journal", "-wal", "-shm")
        ]
        entitlements["com.apple.security.temporary-exception.files.home-relative-path.read-only"] = [
            f"/{relative.parent}"
        ]
    return entitlements
