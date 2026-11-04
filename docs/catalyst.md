# macOS conversion

`--macos` builds a Mac Catalyst `.app` alongside the IPA in the same run. The conversion works on a separate copy under `macos/`, so the app in `Payload` and the IPA keep their iOS platform metadata. For the command and output layout, see the [README](../README.md#mac-app-experimental).

## How it works

Before dumping, unipa checks that `vtool`, `install_name_tool`, and `clang` are installed. Once the IPA is verified, it runs the Python converter (`src/macho/catalyst.py`) on the copy.

Every binary must be a decrypted, thin arm64 Mach-O file, and the main executable must target iOS or Mac Catalyst. Kept iOS extensions are rejected. The converter uses `vtool` to retag iOS build-version commands as Mac Catalyst (minimum version 11.0, SDK 14.0). Libraries that are already Mac Catalyst or native macOS keep their platform. This only changes metadata: the code is not recompiled, and nothing guarantees it will run on those OS versions.

References to `@rpath/libswiftUIKit.dylib` are rewritten to `/System/iOSSupport/usr/lib/swift/libswiftUIKit.dylib`. Each binary is checked again for platform and library paths before signing.

Hooks in `src/hooks/` are compiled into `UnipaRuntime.dylib` and added to the executable as a load command. If the Mach-O header has no room for it, conversion stops.

## Bundle settings

App and display names stay the same. The bundle identifier gets a `.unipalocal` suffix, which may break apps that depend on it. Entitlements are replaced with a sandbox profile that allows outgoing network connections. The original entitlements are dropped, so keychain groups, push notifications, App Groups, and similar features may need extra provisioning or changes to the app.

## Compatibility sandbox

Every macOS conversion automatically adds sandbox rules from `src/macho/entitlements.py`. They deny process forking and access to common shell, SSH, and jailbreak-related paths that iOS apps may mistake for a jailbroken device. No extra flag is needed. The applied restrictions are listed under `compatibility_sandbox` in the conversion report and manifest.

These restrictions apply only to the generated Mac app. They reduce filesystem-based false positives; app-specific signature checks or other detection methods may still reject the converted app.

## Working directory

`src/hooks/runtime-environment.m` sets the working directory to `/` at startup, matching iOS. This prevents relative-file write checks from succeeding in the app's writable container and incorrectly reporting a jailbreak. The setting is recorded under `runtime` in the conversion report and manifest.

## Window size

`src/hooks/window-geometry.m` sets the initial and minimum window content size to 390 × 844, shrinking it to fit the display, and keeps the aspect ratio when resizing.

## Signing and output

Nested binaries and their frameworks or bundles are signed and verified from the inside out. The outer app is signed last, then everything is verified once more.

```text
macos/App.app/            Converted, signed app
macos/conversion.json     Converted binaries, library fixes, signing targets, status
macos/entitlements.plist  Entitlements used for the outer app
```

The `.app` appears under its final name only after verification passes. Successful conversions are recorded under `macos` in `manifest.json`; normal runs set it to `null`.

If conversion fails, the verified IPA, the conversion report, and the unfinished app copy are kept, and automatic app and core cleanup is skipped. unipa never installs or launches the generated app. The IPA still needs signing and provisioning for wherever you install it.
