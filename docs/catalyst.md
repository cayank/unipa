# macOS conversion

`--macos` builds a Mac Catalyst `.app` alongside the IPA in the same run. The conversion works on a separate copy under `macos/`, so the app in `Payload` and the IPA keep their iOS platform metadata. For the command and output layout, see the [README](../README.md#mac-app-experimental).

## How it works

Before dumping, unipa checks that `vtool`, `install_name_tool`, and `clang` are installed. Once the IPA is verified, it runs the Python converter (`src/macho/catalyst.py`) on the copy.

Every binary must be a decrypted, thin arm64 Mach-O file, and the main executable must target iOS or Mac Catalyst. Kept iOS extensions are rejected. The converter uses `vtool` to retag iOS build-version commands as Mac Catalyst (minimum version 11.0, SDK 14.0). Libraries that are already Mac Catalyst or native macOS keep their platform. This only changes metadata: the code is not recompiled, and nothing guarantees it will run on those OS versions.

References to `@rpath/libswiftUIKit.dylib` are rewritten to `/System/iOSSupport/usr/lib/swift/libswiftUIKit.dylib`. Each binary is checked again for platform and library paths before signing.

Hooks in `src/hooks/` are compiled into `UnipaRuntime.dylib` and loaded by the executable. Before dumping, unipa checks for filename conflicts and enough header space for the runtime, injected libraries, and version-command growth. The converter repeats this check before copying.

## Bundle settings

The Mac app filename uses the source app's display name, falling back to its bundle name. The executable filename stays the same. Without an ID override, conversion adds `.unipalocal` to the bundle ID and an instance suffix for a nondefault isolated Keychain instance.

`--bundle-id` and `--bundle-name` are shared with IPA output. See [bundle settings](bundle.md) for random and exact values, naming, nested IDs, and signing implications.

Entitlements are replaced with a sandbox profile that allows outgoing network connections and declared location access. With `--inject`, the Mac app also receives incoming-network permission. Optional isolated Keychain storage adds access to the selected database. Original entitlements are dropped, so push notifications, App Groups, and other provisioned features may need additional configuration.

## Optional Keychain storage

`--isolated-keychain` uses independent storage for the generated Mac app. `--keychain-instance <name>` selects another persistent instance and enables isolation. Native Keychain remains the default, and the IPA is unaffected. See [isolated Keychain storage](keychain.md) for paths, behavior, security limits, and tests.

## Compatibility sandbox

Every macOS conversion automatically adds sandbox rules from `src/macho/entitlements.py`. They deny process forking and access to common shell, SSH, and jailbreak-related paths that iOS apps may mistake for a jailbroken device. No extra flag is needed. The applied restrictions are listed under `compatibility_sandbox` in the conversion report and manifest.

These restrictions apply only to the generated Mac app. They reduce filesystem-based false positives, but app-specific signature checks or other detection methods may still reject the converted app.

## Location access

When the source app declares a nonempty location usage description, conversion enables the macOS sandbox location entitlement. Existing purpose strings are preserved. If only an iOS purpose string exists, it also supplies `NSLocationUsageDescription` for macOS. Apps without a declared purpose receive no location entitlement.

The app must request location permission through macOS. Conversion does not grant permission or reset earlier decisions. Check System Settings → Privacy & Security → Location Services for the generated app.

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

The `.app` appears under its final name only after verification passes. Successful conversions are recorded under `macos` in `manifest.json`, while normal runs set it to `null`.

If conversion fails, any IPA already built is kept and automatic app and core cleanup is skipped. The conversion report and any unfinished app copy are kept if they were created. Early validation failures can occur before either exists.

unipa never installs or launches the generated app. The IPA still needs signing and provisioning for wherever you install it.
