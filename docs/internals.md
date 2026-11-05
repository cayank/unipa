# unipa internals

For requirements, compatibility, installation, and everyday usage, see the [README](../README.md).

## Finding the app and its process

Apps are listed with `system_profiler`, and the executable name comes from `CFBundleExecutable`. Both the `Wrapper/*.app` layout and a plain iOS `.app` work. Excluded extensions are skipped during the source inventory scan and removed from the output copy before recovery.

To find the running process, unipa first compares the executable's canonical path. macOS can launch wrapped iOS apps from a relocated `/private/var/folders/.../d/Wrapper/` path, so a different path is accepted only if the executable name and size match and the full SHA256 equals the selected app's executable. The verified runtime path is logged, and hashes are cached until the file metadata changes. A matching process is reused; if there is none, the app is launched.

## Recovery

`src/macho/run.ts` calls the Python CLI (`src/macho/cli.py`), which handles the commands and recovery files. `src/macho/reader.py` parses Mach-O files, reads core memory, and patches bytes.

`cryptoff` is a file offset. unipa looks for the segment that contains the **entire** encrypted range rather than assuming `__TEXT` or a fixed base:

```text
preferred_header_address = header_segment.vmaddr - header_segment.fileoff
slide = runtime_header_address - preferred_header_address
encrypted_memory_address = slide + encrypted_segment.vmaddr
                         + cryptoff - encrypted_segment.fileoff
```

`SG_HIGHVM` segments are handled separately, since their stored bytes map to the high end of the segment. Apple's [Mach-O definitions](https://github.com/apple-oss-distributions/xnu/blob/main/EXTERNAL_HEADERS/mach-o/loader.h) are the reference for the file layout.

The core is opened with `mmap`, and headers are searched for inside core segments, not only at segment starts. A runtime header may have a different `cryptid`, but every other header and load command byte must match. Samples from unencrypted instruction sections are also compared with the code on disk. This filters out mappings that share the same header but are not the runtime image, and it can reject code modified by hooks.

Missing core pages are never zero-filled; reads continue across adjacent segments. Candidates are discarded if they are identical to disk, entirely zero, or fail the plaintext code check.

### Choosing a base

If more than one valid candidate remains, the run stops. Look at `recovery/000/analysis.json` in the work folder, then pick one explicitly:

```bash
unipa \
  --app /Applications/Example.app \
  --core /tmp/example.core \
  --base 0x102e1c000
```

The address is only an example; use one from your own report. `--base` chooses among valid candidates and does not skip any checks. Note that a difference between disk and RAM is not cryptographic proof that the plaintext is correct.

### Patching

The patch changes only the `cryptoff..cryptoff+cryptsize` range and the `cryptid` field in the encryption command. The result is read back and verified, and the source app is never touched. Before packaging, every Mach-O file is scanned again, and if any encrypted executable is left, no IPA is produced.

Recovery supports thin, little-endian 64-bit Mach-O only. FAT/universal source apps and 32-bit files fail with an explicit error. Injection libraries can be universal; one compatible CPU type and subtype is selected before embedding. The encrypted range must sit inside a single executable segment, though in the core it may span several adjacent ones.

## Bundle metadata

After recovery, `src/bundle.ts` calls the Python `configure-bundle` command in `src/macho/bundle.py` when a bundle ID or name override was requested. The staged app is updated before injection and signing; its executable filename and code remain unchanged. Related nested app/extension IDs receive the new prefix. Random values are generated once and recorded under `bundle` in the manifest, then reused for Mac output. See [bundle settings](bundle.md).

## Dylib injection

`--inject` validates and stages local libraries before dumping, then adds them to the output copy after recovery and before signing. This keeps the original executable header available for matching against the core. `src/inject.ts` calls the Python `prepare-injection` and `inject` commands; `src/macho/load_commands.py` provides build-platform parsing, dylib-path validation, and header-padding checks shared by injection and Mac Catalyst conversion. Libraries are signed and verified individually before the app is signed. Plans, results, and hashes are saved under `injection/` and listed in the manifest. See [dylib injection](injection.md) for usage and limits.

## Output files

Each run creates a new folder under `output/<app-name>-XXXXXX/`, using the lowercase `.app` bundle name followed by a random suffix. The default parent is the checkout's `output/` directory. Use `--work-dir` to change it.

```text
Payload/App.app/                 Patched copy, signed unless disabled
process.core                     Generated core; kept until outputs and initial manifest are saved
source.json                      Source bundle, retained Mach-O inventory, and excluded extensions
recovery/000/analysis.json       All base candidates and comparison results
recovery/000/region.bin          Extracted bytes (full cryptsize range)
recovery/000/executable.patched  Patch result before signing
recovery/000/result.json         Selected candidate and hashes
manifest.json                    Verified outputs, bundle overrides, and cleanup status
App-patched.ipa                  Verified ZIP containing only Payload
```

Failed runs keep their work folder. If the base is ambiguous or missing, `analysis.json` is there to explain why. Recovery artifacts never overwrite existing files, so use a new recovery folder to retry.

unipa is macOS-only (`os: ["darwin"]`) and exits on any other system before doing any work. The host's macOS version, build, and architecture are saved under `host` in `source.json` and `manifest.json`, but no version cutoff is enforced. With an existing core, `host` describes the current machine, which may not be where the dump came from. For live-dump version limits, see [Compatibility](../README.md#compatibility).

## Signing and permissions

The default signature is ad-hoc (`codesign --force --deep --sign -`), followed by `codesign --verify --deep --strict`. Use `--identity 'Apple Development: …'` to pick another identity. `--no-sign` only skips signing, and patching invalidates the original signature either way. IPA provisioning remains external. Mac conversion replaces entitlements with the generated sandbox settings described in [macOS conversion](catalyst.md).

> Some apps produce incomplete core dumps because `gcore` cannot read a memory mapping. unipa attempts recovery from the captured data and stops if required bytes are missing.

Taking a new core may ask for your `sudo` password. Only `gcore` and the `chown` that gives you ownership of the core run under sudo. The work folder is created with `0700`, and the core and reports with `0600`.

## macOS conversion

The Mac Catalyst app, window size, signing, and conversion reports are covered in [macOS conversion](catalyst.md).

## Cleanup

After the IPA passes signing and archive checks (and the macOS conversion succeeds, if requested), unipa saves `manifest.json` before cleanup. It then confirms the dumped process still runs the selected executable, sends `SIGKILL` to that exact PID, and deletes the generated core. Failures before the initial manifest is saved leave the app and core in place.

Cores passed with `--core` or `--core-for` are never deleted. `--core` prevents live dumping; `--core-for` supplies a core only for the specified binary, so other binaries may still require a live dump.

The manifest is written atomically with `cleanup.status` set to `pending`, then replaced with cleanup results and a status of `complete` or `failed`. If cleanup fails, the verified IPA is kept, a warning is shown, and the exit code is nonzero. If saving the final results fails, the initial manifest remains with `pending` status; the app may already be closed and the core deleted.

The [cleanup script](../scripts/clean-cores.ts) removes only regular `process.core` files directly inside recognized run folders under the chosen output directory. For app-named folders, the prefix must match the source app in a regular `source.json` file and the suffix must contain six letters or digits. Older run folders are also supported. It leaves IPAs, app copies, extracted regions, and reports alone, skips symlinks, and reports unreadable runs without stopping on them. The commands are in the [README](../README.md#cleanup).

## Development

Log lines use the labels `[INFO]`, `[SUCCESS]`, `[WARN]`, and `[ERROR]`. Warnings and errors go to stderr, everything else to stdout. Colors are off when output is redirected; set `NO_COLOR=1` to disable them or `FORCE_COLOR=1` to force them.

From the project directory:

```bash
bun run format
bun run format:check
```

The Python backend can be run on its own:

```bash
python3 -B src/macho/cli.py inspect --binary /path/to/executable
python3 -B src/macho/cli.py analyze --binary /path/to/executable --core /path/to/app.core
python3 -B src/macho/cli.py recover --binary /path/to/executable --core /path/to/app.core --output-dir /tmp/new-recovery
python3 -B src/macho/cli.py patch --binary /path/to/executable --region /tmp/new-recovery/region.bin --output /tmp/new-executable
```

`UNIPA_PYTHON=/path/to/python3` selects the Python interpreter. The tests use synthetic Mach-O files and cores, so they never launch a real app or use `sudo`. The macOS integration tests rely on `xcrun clang`, `codesign`, `ditto`, and `unzip`.
