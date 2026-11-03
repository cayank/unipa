"""Sandbox settings for converted apps."""

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

# restrict host features that an iOS app may mistake for a jailbreak
def macos_entitlements() -> dict:
    rules = ["(deny process-fork)"]
    operations = "file* file-read* file-read-metadata file-ioctl"
    rules.extend(f'(deny {operations} (literal "{path}"))' for path in DENIED_FILES)
    rules.extend(
        f'(deny {operations} (subpath "{path}"))' for path in DENIED_DIRECTORIES
    )
    return {
        "com.apple.security.app-sandbox": True,
        "com.apple.security.network.client": True,
        "com.apple.security.temporary-exception.sbpl": rules,
    }
