# machkit

Creates an IPA from an iOS app running on macOS by recovering decrypted executable bytes from a core dump. The installed app stays unchanged.

> **Disclaimer:** machkit is provided "as is", without warranty. Use it at your own risk and only on apps you own or are authorized to analyze. To the extent permitted by applicable law, the authors and contributors accept no liability for damage, data loss, or other consequences of its use. You are responsible for how you use the tool and the files it produces.

## Requirements

- Apple Silicon Mac (M1 or later)
- A compatible macOS version (see [Compatibility](#compatibility))
- Bun — required runtime; Node.js is not supported
- Python 3.10+ — standard library only, no pip packages needed
- `gcore`, `ditto`, `codesign`, and `unzip`

## Compatibility

Running iOS apps and recovering their decrypted memory have different requirements:

| Capability | macOS version |
| --- | --- |
| Native support for compatible iPhone and iPad apps | Big Sur 11+ on Apple Silicon. Individual apps may require newer versions. |
| Current live-dump method using the system `gcore` | Sequoia 15.0–15.2.x is the relevant window reported by the research. |
| Tested with machkit | macOS 15.0, build 24A8332, arm64. |

Apple introduced native iOS app support with [Big Sur on Apple Silicon](https://developer.apple.com/videos/play/wwdc2020/10114/). [FFRI's research](https://www.ffri.jp/wp-content/uploads/2026/01/gcore.pdf) documents the privileged `gcore` entitlement in 15.0 and its removal in 15.3. The reported window has not been fully tested with machkit; do not assume live dumping works on newer releases.

machkit records the host OS version but does not enforce a version cutoff. Successful startup does not establish live-dump compatibility.

## Install

```bash
git clone https://github.com/cayank/machkit
cd machkit
bun install
bun link
```

Then run `machkit` from any directory:

```bash
machkit --help
machkit
```

`bun link` points to this checkout, so keep the project directory in place. Run `bun unlink` from the project directory to remove the link.

## Usage

Run `machkit` to select an iOS App Store app under `/Applications/`, or pass its path directly. Both wrapped and plain iOS app bundles are supported.

```bash
machkit --app /Applications/Starbucks.app
machkit --app /Applications/Starbucks.app --pid 12345 --wait-ms 5000
```

An existing app process is reused; otherwise, machkit launches it. `--pid` selects a process, and `--wait-ms` sets the delay before dumping. Capturing a new core may prompt for your `sudo` password.

Running against an existing core lets you retry patching and packaging without launching the app:

```bash
machkit --app /Applications/Starbucks.app --core /tmp/starbucks/starbucks.core
```

## Extensions

By default, all `PlugIns/*.appex` directories are removed from the output copy and listed in `manifest.json`. Features provided by those extensions, such as notification processing, may be unavailable.

<details>
<summary>Keep extensions or exclude specific ones</summary>

Use `--keep-extensions` to preserve them. An encrypted extension may run in a separate process and need its own dump:

```bash
machkit \
  --app /Applications/Starbucks.app \
  --core /tmp/starbucks/starbucks.core \
  --keep-extensions \
  --core-for 'PlugIns/NetmeraNotificationService.appex/NetmeraNotificationService=/tmp/notification.core'
```

To keep other extensions while explicitly removing one:

```bash
machkit \
  --app /Applications/Starbucks.app \
  --core /tmp/starbucks/starbucks.core \
  --keep-extensions \
  --exclude-extension NetmeraNotificationService.appex
```

`--core-for` and `--exclude-extension` can be repeated. Packaging still stops if an encrypted executable remains in a preserved extension.

</details>

## Output and signing

Each run creates `output/machkit-XXXXXX/` containing `App-patched.ipa`, a patched app copy, and recovery reports. Use `--work-dir /path/to/dir` to change the parent folder. Failed runs keep their work folder for inspection.

Signing is ad-hoc by default. Use `--identity 'Apple Development: …'` to choose an identity or `--no-sign` to skip signing. Patching invalidates the original signature. Only thin, little-endian 64-bit Mach-O is supported; FAT/universal and 32-bit binaries are rejected.

## Installing the IPA

You can use [Sideloadly](https://sideloadly.io/) to re-sign and install the IPA on a compatible device; follow its [instructions](https://sideloadly.io/faq).

The default ad-hoc signature is not enough for installation on an iOS device. Signing, provisioning, entitlements, and device compatibility still apply. Generating an IPA does not guarantee it will install or run correctly.

## Cleanup

After producing a verified IPA, machkit force-closes the app process used for the dump and deletes the core it generated. Failed recovery or packaging leaves the app and core available for inspection.

Cores supplied through `--core` or `--core-for` are kept, and existing-core runs never launch or close an app.

Cleanup errors are recorded in `manifest.json`; the IPA is kept and the command exits with a nonzero status.

From the project directory, preview or delete leftover core files from failed runs:

```bash
bun run clean:cores --dry-run
bun run clean:cores
bun run clean:cores --work-dir /path/to/output   # custom output directory
```

The script removes only `machkit-*/process.core`, keeps other output files, and skips symlinks.

For recovery details, report files, troubleshooting, and development commands, see [Internals](docs/internals.md).

## License

Licensed under the [ISC License](LICENSE).
