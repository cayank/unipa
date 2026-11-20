# macOS conversion

`--macos` builds a separate Mac Catalyst `.app` under `macos/`. The IPA keeps its iOS platform metadata. See the [README](../README.md#mac-app-experimental) for usage.

## How it works

Before dumping, unipa checks that `vtool`, `install_name_tool`, and `clang` are installed. Once the IPA is verified, it runs the Python converter (`src/macho/catalyst.py`) on the copy.

Every binary must be a decrypted, thin arm64 Mach-O file, and the main executable must target iOS or Mac Catalyst. Kept iOS extensions are rejected. The converter uses `vtool` to retag iOS build-version commands as Mac Catalyst with minimum version 11.0. Each binary keeps its SDK version, with 14.0 as the floor, because UIKit enables newer behavior, such as the iPadOS 18 tab bar, only for apps built with a newer SDK. Libraries that are already Mac Catalyst or native macOS keep their platform. Retagging changes metadata, not the code, and does not guarantee runtime compatibility.

References to `@rpath/libswiftUIKit.dylib` are rewritten to `/System/iOSSupport/usr/lib/swift/libswiftUIKit.dylib`. Each binary is checked again for platform and library paths before signing.

Hooks in `src/hooks/` are compiled into `UnipaRuntime.dylib` and loaded by the executable. Preflight checks filename conflicts and header space for the runtime, injected libraries, and platform changes.

## Bundle settings

The Mac app filename uses the source app's display name, falling back to its bundle name. The executable filename stays the same. The original bundle ID is preserved unless you use `--bundle-id`.

`--bundle-id` and `--bundle-name` are shared with IPA output. See [bundle settings](bundle.md) for random and exact values, naming, nested IDs, and signing implications.

Entitlements are replaced with a sandbox profile that allows outgoing network connections and declared location access. With `--inject`, the Mac app also receives incoming-network permission. Optional isolated Keychain storage adds access to the app's Keychain folder. Original entitlements are dropped, so push notifications, App Groups, and other provisioned features may need additional configuration.

## Optional Keychain storage

`--isolated-keychain` uses independent storage for the generated Mac app. `--keychain-instance <name>` selects another persistent instance and enables isolation. Native Keychain remains the default, and the IPA is unaffected. See [isolated Keychain storage](keychain.md) for details and security limits.

## Compatibility sandbox

Sandbox rules in `src/macho/entitlements.py` block process forking and common shell, SSH, and jailbreak-related paths. The applied rules are recorded under `compatibility_sandbox` in the reports.

These restrictions apply only to the generated Mac app. They reduce filesystem-based false positives, but app-specific signature checks or other detection methods may still reject the converted app.

## Location access

When the source app declares a nonempty location usage description, conversion enables the macOS sandbox location entitlement. Existing purpose strings are preserved. If only an iOS purpose string exists, it also supplies `NSLocationUsageDescription` for macOS. Apps without a declared purpose receive no location entitlement.

The app must request location permission through macOS. Conversion does not grant permission or reset earlier decisions. Check System Settings → Privacy & Security → Location Services for the generated app.

## Working directory

`src/hooks/environment.m` sets the working directory to `/` at startup, matching iOS. This prevents relative-file write checks from succeeding in the app's writable container and incorrectly reporting a jailbreak. The setting is recorded under `runtime` in the conversion report and manifest.

## Window size

`--macos` uses a fixed 390 × 844 iPhone layout, shrinking it to fit smaller displays. The window is not resizable.

Apps with iPad support can select an 820 × 1180 layout from **unipa → Layout**. Restart to apply it cleanly. **Switch Now** applies it immediately, but some screens may need a restart. iPad-capable apps may retain some iPad styling in the iPhone layout.

App sheets open inside the window. System dialogs keep their native look. The window reopens where it was last left. In the iPad layout, tab bars move into the window toolbar, as in iPad apps from the App Store.

## unipa menu

Settings in the **unipa** menu are saved per app. Appearance, location, and window options apply immediately. Layout and Keychain changes may require a restart.

| Item | What it does |
|---|---|
| About unipa | Shows the unipa version, bundle ID, layout, Keychain mode, and location |
| Layout | Select the iPhone or supported iPad layout |
| Appearance | Follow the system, or force light or dark |
| Keep on Top | Keeps the window above other windows |
| Hide Title Bar | Hides the window title and makes the title bar transparent |
| Location | Use real or simulated coordinates when Core Location is available |
| Keychain | Select, create, or clear an [isolated Keychain instance](keychain.md#switching-instances) |
| Device Info | Shows the vendor and advertising IDs, the device the app sees, and the app's Keychain items, such as stored device IDs. Values can include sign-in tokens |
| Show App Data in Finder | Opens the app's sandbox container |
| Reset App… | Deletes the Keychain instance in use, preferences (including saved addresses and device IDs), caches, and app files. Everything is selected by default; SDKs such as Adjust restore IDs from their own files otherwise. The app quits and the reset runs when it opens again, before the app's code. unipa settings are kept |

Location simulation is meant for testing. While it is on, the app sees location access as granted and receives only the simulated coordinates.

Reset App and Keychain instances keep the same vendor ID (IDFV), which macOS derives from the app's identity. For fully separate identities, such as two accounts, convert separate copies with different [`--bundle-id`](bundle.md) values; each gets its own container, preferences, Keychain, and vendor ID.

Simulating locations and resetting identifiers are meant for testing apps you work on. Using them to bypass per-device or regional restrictions in other apps may break their terms of service.

## Signing and output

Nested binaries and their frameworks or bundles are signed and verified from the inside out. The outer app is signed last, then everything is verified once more.

```text
macos/App.app/            Converted, signed app
macos/conversion.json     Converted binaries, library fixes, signing targets, status
macos/entitlements.plist  Entitlements used for the outer app
```

The `.app` appears under its final name only after verification passes. Successful conversions are recorded under `macos` in `manifest.json`, while normal runs set it to `null`.

If conversion fails, the IPA and any conversion artifacts already created are kept. Automatic app and core cleanup is skipped.

unipa never installs or launches the generated app. The IPA still needs signing and provisioning for wherever you install it.
