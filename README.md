# machkit

Takes a core dump of an iOS app running on macOS, locates the encrypted Mach-O regions, extracts them from memory, patches copies of the executables, and produces an IPA containing `Payload/*.app`.

> **Disclaimer:** machkit is provided "as is", without warranty. Use it at your own risk and only on apps you own or are authorized to analyze. To the extent permitted by applicable law, the authors and contributors accept no liability for damage, data loss, or other consequences of its use. You are responsible for how you use the tool and the files it produces.

Requirements: An Apple Silicon Mac (M1 or later), Bun, Python 3.10+, `gcore`, `ditto`, `codesign`, `unzip`. The Python standard library is sufficient; LIEF is not needed.

## Compatibility

Running iOS apps on a Mac and recovering their decrypted memory have different requirements:

| Capability | macOS version |
| --- | --- |
| Native support for compatible iPhone and iPad apps | Big Sur 11+ on Apple Silicon. Individual apps may require newer versions. |
| Current live-dump method using the system `gcore` | Sequoia 15.0–15.2.x is the relevant window reported by the research. |
| Tested with machkit | macOS 15.0, build 24A8332, arm64. |

Apple introduced native iPhone and iPad app support with [Big Sur on Apple Silicon](https://developer.apple.com/videos/play/wwdc2020/10114/). For the current FairPlay recovery method, [FFRI's research](https://www.ffri.jp/wp-content/uploads/2026/01/gcore.pdf) documents the privileged `gcore` entitlement in macOS 15.0 and its removal in 15.3. This method should not be assumed to work on newer releases. The reported version window is not a claim that every release and app has been tested with machkit.

The package is macOS-only (`os: ["darwin"]`), and the CLI rejects other operating systems before doing any work. It records the host's macOS version, build, and architecture under `host` in `source.json` and `manifest.json`, but does not enforce a macOS version cutoff. Successful startup does not establish live-dump compatibility. When using an existing core, `host` describes the current machine, which may differ from the dump's source.

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

Apps are listed via `system_profiler`. The picker shows only iOS App Store apps under `/Applications/`; use `--app` to select a bundle elsewhere. Both the `Wrapper/*.app` layout and a plain iOS `.app` are supported. The executable name is read from `CFBundleExecutable`.

```bash
machkit --app /Applications/Starbucks.app
machkit --app /Applications/Starbucks.app --pid 12345 --wait-ms 5000
```

Process detection first checks the executable's canonical path. macOS can launch wrapped iOS apps from a relocated `/private/var/folders/.../d/Wrapper/` path. For a different path with the same executable name and size, the full SHA256 must match the selected app's executable. The verified runtime path is logged, and hashes are cached as long as file metadata is unchanged. Existing processes are reused; if none match, the app is launched. `--wait-ms` sets the delay before dumping.

Running against an existing core lets you retry patching and packaging without launching the app:

```bash
machkit --app /Applications/Starbucks.app --core /tmp/starbucks/starbucks.core
```

## How it works

`src/macho/run.ts` calls the Python CLI (`src/macho/cli.py`), which handles commands and recovery files. `src/macho/reader.py` parses Mach-O files, reads core memory, and patches bytes.

`cryptoff` is a file offset. The tool looks for the segment that contains the **entire** encrypted range; it doesn't assume `__TEXT` only or a fixed base:

```text
preferred_header_address = header_segment.vmaddr - header_segment.fileoff
slide = runtime_header_address - preferred_header_address
encrypted_memory_address = slide + encrypted_segment.vmaddr
                         + cryptoff - encrypted_segment.fileoff
```

For `SG_HIGHVM` segments, the mapping of stored bytes to the high end of the segment is handled separately. Apple's [Mach-O definitions](https://github.com/apple-oss-distributions/xnu/blob/main/EXTERNAL_HEADERS/mach-o/loader.h) are the reference for the file layout.

The core is opened with `mmap`. Headers are searched for inside core segments, not just at segment starts. The runtime header's `cryptid` may differ; all other header and load command bytes must match. Samples taken from unencrypted instruction sections are also compared against the code on disk, which filters out mappings that share the same header but are not the runtime image. Samples of plaintext code modified by hooks can be rejected as well.

Missing core pages are not zero-filled; reads continue across adjacent segments. Candidates that are identical to disk, entirely zero, or that fail the plaintext code check are discarded. If more than one valid candidate remains, the run stops:

```bash
machkit \
  --app /Applications/Starbucks.app \
  --core /tmp/starbucks/starbucks.core \
  --base 0x102e1c000
```

`--base` doesn't skip any checks; it only selects among the valid candidates. A difference between disk and RAM is not, by itself, cryptographic proof that the plaintext is correct.

The patch changes only the `cryptoff..cryptoff+cryptsize` range and the `cryptid` field in the encryption command. The result is re-read and verified. The source app is untouched. Before packaging, all Mach-O files are rescanned; if any encrypted executable remains, no IPA is produced.

## Extensions

By default, all `PlugIns/*.appex` directories are removed from the output copy. The installed app stays unchanged, and removed extensions are listed in the log and in `manifest.json`. Features provided by those extensions, such as notification processing, may be unavailable.

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

## Output and signing

Each run creates a new folder under `output/machkit-XXXXXX/`. Use `--work-dir /path/to/dir` to change the parent folder. The folder contains:

```text
Payload/App.app/                Patched copy, signed unless disabled
process.core                    Kept if the run fails; deleted after a verified IPA is created
source.json                     Source bundle and Mach-O inventory
recovery/000/analysis.json      All base candidates and comparison results
recovery/000/region.bin         Extracted cryptsize bytes (full range)
recovery/000/executable.patched Patch result before signing
recovery/000/result.json        Selected candidate and hashes
manifest.json                   Summary of a successful run; excluded extensions
App-patched.ipa                 Verified ZIP containing only Payload
```

On failure, the work folder is kept for inspection. If the base is ambiguous or missing, `analysis.json` will be present. Python outputs never overwrite existing files; use a new recovery folder to retry.

The default signature is ad-hoc (`codesign --force --deep --sign -`), followed by `codesign --verify --deep --strict`. Use `--identity 'Apple Development: …'` to pick a signing identity. `--no-sign` only skips signing; patching invalidates the original signature. Provisioning and entitlements are outside the scope of this tool.

Taking a new core may prompt for the `sudo` password. Only `gcore` and the `chown` that hands ownership of the core to the current user run under sudo. The work folder is created with `0700`, and the core and reports with `0600`.

## Installing the IPA

You can pass the generated IPA to [Sideloadly](https://sideloadly.io/) for re-signing and installation on a compatible device. Select the IPA and target device, then follow [Sideloadly's instructions](https://sideloadly.io/faq).

The default ad-hoc signature doesn't make the IPA ready for installation on an iOS device. Installation and app functionality depend on device and OS compatibility, signing, provisioning, and the app's entitlements. Successful IPA generation doesn't guarantee that the app will install or run correctly.

## Cleanup

After the IPA passes signing and archive checks, machkit sends `SIGKILL` to the exact PID used for the dump, after verifying that it still runs the selected executable. It then deletes the core generated by that run. If recovery or packaging fails, the app and core are left available for inspection.

Cores supplied through `--core` or `--core-for` are kept, and existing-core runs never launch or close an app.

Cleanup results are recorded in `manifest.json`. If cleanup fails, the verified IPA is kept, a warning is shown, and the command exits with a nonzero status.

From the project directory, preview or delete leftover core files from failed runs:

```bash
bun run clean:cores --dry-run
bun run clean:cores
bun run clean:cores --work-dir /path/to/output   # custom output directory
```

The script removes only `machkit-*/process.core` under the selected output directory. It keeps IPAs, copied apps, extracted regions, and reports, and skips symlinks. Unreadable runs are reported without stopping cleanup of the others.

## Limitations

Only thin, little-endian 64-bit Mach-O is supported. FAT/universal and 32-bit inputs are rejected with an explicit error; another architecture is never silently selected. The encrypted range must lie within a single executable segment, though in the core it may span several adjacent segments.

## Development

Messages use level labels (`[INFO]`, `[SUCCESS]`, `[WARN]`, `[ERROR]`). Warnings and errors go to stderr; everything else goes to stdout. Colors are omitted when output is redirected; set `NO_COLOR=1` to disable them or `FORCE_COLOR=1` to force them.

Run the development commands from the project directory:

```bash
python3 -B src/macho/cli.py inspect --binary /path/to/executable
python3 -B src/macho/cli.py analyze --binary /path/to/executable --core /path/to/app.core
python3 -B src/macho/cli.py recover --binary /path/to/executable --core /path/to/app.core --output-dir /tmp/new-recovery
python3 -B src/macho/cli.py patch --binary /path/to/executable --region /tmp/new-recovery/region.bin --output /tmp/new-executable
```

`MACHKIT_PYTHON=/path/to/python3` selects the backend interpreter. The tests generate synthetic Mach-O files and cores; they do not launch a real app or use `sudo`. The macOS integration tests use `xcrun clang`, `codesign`, `ditto`, and `unzip`.

## License

Licensed under the [ISC License](LICENSE).
