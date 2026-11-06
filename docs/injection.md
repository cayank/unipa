# Dylib injection

`--inject` adds local iOS dylibs to the output app after recovery and before signing. With `--macos`, they are included in the Mac copy too. Source files stay unchanged.

```bash
unipa \
  --app /Applications/Example.app \
  --inject ./dylibs/FridaGadget.dylib.gz \
  --inject ./dylibs/CustomHook.dylib
```

## Files and architectures

The `dylibs/` directory at the project root is ignored by Git. Use it for downloaded libraries, or supply any other local path. The `src/hooks/` directory contains unipa's own hook source files.

Inputs can be `.dylib`, `.dylib.gz`, or `.dylib.xz`. Compressed files are unpacked, and universal libraries are reduced to one compatible CPU type and subtype. An exact subtype match is preferred, with a compatible generic slice accepted when needed. Libraries must target iOS devices and must already be decrypted. Simulator, macOS, incompatible, and ambiguous inputs are rejected.

Libraries are checked and staged before a new core dump is taken. unipa requires enough unused Mach-O header space for the load commands and stops if adding them would move existing contents. Existing bundle files and duplicate destination names are never overwritten. With `--macos`, preflight also reserves `UnipaRuntime.dylib` and checks space for both injected libraries and the Mac runtime before dumping.

Only the main executable receives load commands. Extensions are not injected. Dependencies required by a custom dylib must also be available in the app or provided by the target platform.

## Mac output

Combine injection with `--macos` to produce both outputs:

```bash
unipa --app /Applications/Example.app --inject ./dylibs/unipa-flex.dylib --macos
```

The IPA keeps the iOS library. The Mac copy retags it during [Mac Catalyst conversion](catalyst.md). Libraries must be thin arm64 after architecture selection. Platform retagging does not guarantee compatibility with macOS, so check the library's runtime and signing requirements.

With `--macos --inject`, the Mac app also receives incoming-network permission so injected libraries can listen for connections. The library configuration determines the listening address and port. The setting is recorded as `incoming_network` in the conversion report and manifest.

## Building FLEX

Build the customized FLEX library with Xcode and its iOS SDK installed:

```bash
python3 scripts/build-flex.py
unipa --inject ./dylibs/unipa-flex.dylib
```

The script downloads pinned [FLEX](https://github.com/FLEXTool/FLEX), [PrisonFLEX](https://github.com/Uraniumm/PrisonFLEX), and [Logos](https://github.com/theos/logos) sources, applies `scripts/flex.patch`, and builds an arm64 iOS 15+ dylib. Sources, build files, and license notices stay in the ignored `dylibs/flex/` directory. Cached sources must match the pinned revisions and patch. Unexpected tracked or untracked changes stop the build.

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

The run folder keeps `injection/plan.json`, prepared library files under `injection/files/`, and `injection/result.json`. Successful runs also record the libraries under `injections` in `manifest.json`. `source_sha256` identifies the original input, including compression, while `prepared_sha256` identifies the selected, decompressed slice before signing. A companion config is copied byte-for-byte and has its own hash.
