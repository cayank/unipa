# Dylib injection

`--inject` adds local dylibs to the output app after recovery and before signing. An iOS dylib injected into a Mac Catalyst app is retagged to Mac Catalyst so it loads. With `--macos`, injected dylibs are included in the Mac copy too. Source files stay unchanged.

Injecting into an already-converted Mac Catalyst app produces a runnable `.app` in the run folder instead of an IPA, since a Catalyst app runs on the Mac directly rather than being installed.

```bash
unipa \
  --app /Applications/Example.app \
  --inject ./dylibs/FridaGadget.dylib.gz \
  --inject ./dylibs/CustomHook.dylib
```

## Files and architectures

The `dylibs/` directory at the project root is ignored by Git. Use it for downloaded libraries, or supply any other local path. The `src/hooks/` directory contains unipa's own hook source files.

Inputs can be `.dylib`, `.dylib.gz`, or `.dylib.xz`. Universal libraries are reduced to a compatible slice, preferring an exact CPU subtype match. Libraries must be decrypted. iOS apps require iOS device libraries. Catalyst apps accept iOS device or Catalyst libraries. Simulator, macOS, incompatible, and ambiguous inputs are rejected.

Libraries are checked and staged before dumping. Injection stops if header space is insufficient or a destination filename conflicts. With `--macos`, these checks also cover `UnipaRuntime.dylib`.

Only the main executable receives load commands. Extensions are not injected. Dependencies required by a custom dylib must also be available in the app or provided by the target platform.

## Mac output

Combine injection with `--macos` to produce both outputs:

```bash
unipa --app /Applications/Example.app --inject ./dylibs/unipa-flex.dylib --macos
```

The IPA keeps the iOS library. The Mac copy retags it during [Mac Catalyst conversion](catalyst.md). Libraries must be thin arm64 after architecture selection. Platform retagging does not guarantee compatibility with macOS, so check the library's runtime and signing requirements.

With `--macos --inject`, the Mac sandbox allows incoming connections. The library controls its listening address and port. Reports record this permission as `incoming_network`.

## Building FLEX

Build the customized FLEX library with Xcode and its iOS SDK installed:

```bash
python3 scripts/build-flex.py
unipa --inject ./dylibs/unipa-flex.dylib
```

The script downloads pinned [FLEX](https://github.com/FLEXTool/FLEX), [PrisonFLEX](https://github.com/Uraniumm/PrisonFLEX), and [Logos](https://github.com/theos/logos) sources, applies `scripts/flex.patch`, and builds an arm64 iOS 15+ dylib. Sources, build files, and license notices stay in the ignored `dylibs/flex/` directory. Modified cached sources stop the build.

- On macOS, press `Ctrl+Shift+F` or `Command+Shift+F` to open FLEX.
- On iOS, use a three-finger long press to open FLEX.
- Click `×` to collapse the toolbar to its draggable handle.
- Click the handle to expand the toolbar.
- Hold `×` for two seconds to hide FLEX completely.
- Scroll the button row horizontally when space is limited.

## Gadget configuration

An optional config beside the input library is copied with it. For `FridaGadget.dylib`, `FridaGadget.dylib.gz`, or `FridaGadget.dylib.xz`, the config name is `FridaGadget.config`.

Frida Gadget waits for a controller by default, so the app can appear to pause at startup. To let it start immediately and attach later, use:

```json
{
  "interaction": {
    "type": "listen",
    "address": "127.0.0.1",
    "port": 27042,
    "on_load": "resume"
  }
}
```

unipa copies the config as supplied and does not generate or change it. Gadget's code-signing and debugger requirements on stock iOS still apply. See the [Frida Gadget documentation](https://frida.re/docs/gadget/).

## Packaging and reports

Each library is copied to `Payload/App.app/Frameworks/` and loaded through `@executable_path/Frameworks/<name>.dylib`. Injected libraries are signed and verified individually before the app is signed and the IPA is packaged. With `--no-sign`, the output still needs signing before installation.

The run folder keeps `injection/plan.json`, prepared libraries under `injection/files/`, and `injection/result.json`. The manifest lists successful injections. `source_sha256` hashes the input file, and `prepared_sha256` hashes the selected slice before signing. Companion configs have their own hashes.
