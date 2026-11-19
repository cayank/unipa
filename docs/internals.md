# unipa internals

For requirements, compatibility, installation, and everyday usage, see the [README](../README.md).

## Finding the app and its process

Apps are listed with `system_profiler`, and the executable name comes from `CFBundleExecutable`. Both the `Wrapper/*.app` layout and a plain iOS `.app` work. Excluded extensions are skipped during the source inventory scan and removed from the output copy before recovery.

unipa matches the process by executable path. Relocated `/private/var/folders/.../d/Wrapper/` paths are accepted only when the executable name, size, and full SHA256 match. A matching process is reused. Otherwise, the app is launched.

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

Missing core pages are never zero-filled, and reads continue across adjacent segments. Candidates are discarded if they are identical to disk, entirely zero, or fail the plaintext code check.

### Choosing a base

If more than one valid candidate remains, the run stops. Look at `recovery/000/analysis.json` in the work folder, then pick one explicitly:

```bash
unipa \
  --app /Applications/Example.app \
  --core /tmp/example.core \
  --base 0x102e1c000
```

Use an address from your own report. `--base` selects a valid candidate without bypassing checks. Different disk and RAM bytes alone do not prove correct decryption.

### Patching

The patch changes only the `cryptoff..cryptoff+cryptsize` range and the `cryptid` field in the encryption command. The result is read back and verified, and the source app is never touched. Before packaging, every Mach-O file is scanned again, and if any encrypted executable is left, no IPA is produced.

Universal bundled binaries are reduced to a slice matching the main executable before recovery. Selection and thinning live in `src/macho/universal.py`, shared with injection. Malformed containers and missing or ambiguous matches are rejected. The main executable and core must be thin, little-endian 64-bit Mach-O. Encrypted ranges must fit one executable segment, but may span adjacent core segments.

## Bundle metadata

`src/bundle.ts` calls `configure-bundle` in `src/macho/bundle.py` to apply requested IDs and names before injection and signing. The shared `apply_bundle_settings` function updates bundle metadata, related nested IDs, and localized names for both outputs. Executable names and code stay unchanged. Random values are generated once, saved under `bundle` in the manifest, and reused for Mac output. See [bundle settings](bundle.md).

## Dylib injection

`src/inject.ts` calls the Python `prepare-injection` and `inject` commands. Validation and staging happen before dumping. Load commands are added after recovery so core matching uses the original header. Shared code in `src/macho/load_commands.py` handles platform parsing, dylib paths, and header space. Plans, results, and hashes are saved under `injection/` and listed in the manifest. See [dylib injection](injection.md).

## Output files

Runs use `output/<app-name>-XXXXXX/` in the checkout. Filenames use lowercase ASCII and hyphens, falling back to `app` when needed. Long names are shortened. Use `--work-dir` to change the parent directory.

```text
Payload/App.app/                 Patched copy, signed unless disabled
process.core                     Generated core; kept until outputs and initial manifest are saved
source.json                      Source bundle, Mach-O inventory, universal binaries, and excluded extensions
recovery/000/analysis.json       All base candidates and comparison results
recovery/000/region.bin          Extracted bytes (full cryptsize range)
recovery/000/executable.patched  Patch result before signing
recovery/000/result.json         Selected candidate and hashes
manifest.json                    Verified outputs, thinned binaries, bundle overrides, and cleanup status
app-patched.ipa                  Verified ZIP containing only Payload
```

Failed runs keep their work folder. If the base is ambiguous or missing, `analysis.json` is there to explain why. Recovery artifacts never overwrite existing files, so use a new recovery folder to retry.

unipa runs only on macOS. Reports record the current host version, build, and architecture without enforcing a version cutoff. With a supplied core, this may differ from the machine that produced it. See [Compatibility](../README.md#compatibility) for live-dump limits.

## Signing and permissions

The default signature is ad-hoc (`codesign --force --deep --sign -`), followed by `codesign --verify --deep --strict`. Use `--identity 'Apple Development: …'` to pick another identity. `--no-sign` only skips signing, and patching invalidates the original signature either way. IPA provisioning remains external. Mac conversion replaces entitlements with the generated sandbox, location, and optional Keychain settings described in [macOS conversion](catalyst.md).

> Some apps produce incomplete core dumps because `gcore` cannot read a memory mapping. unipa attempts recovery from the captured data and stops if required bytes are missing.

Taking a new core may ask for your `sudo` password. Only `gcore` and the `chown` that gives you ownership of the core run under sudo. The work folder is created with `0700`, and the core and reports with `0600`.

## macOS conversion

The Mac Catalyst app, window size, signing, and conversion reports are covered in [macOS conversion](catalyst.md).

## Cleanup

After the IPA passes signing and archive checks (and the macOS conversion succeeds, if requested), unipa saves `manifest.json` before cleanup. It then confirms the dumped process still runs the selected executable, sends `SIGKILL` to that exact PID, and deletes the generated core. Failures before the initial manifest is saved leave the app and core in place.

Cores passed with `--core` or `--core-for` are never deleted. `--core` prevents live dumping, while `--core-for` supplies a core only for the specified binary, so other binaries may still require a live dump.

The manifest is written atomically with `cleanup.status` set to `pending`, then replaced with cleanup results and a status of `complete` or `failed`. If cleanup fails, the verified IPA is kept, a warning is shown, and the exit code is nonzero. If saving the final results fails, the initial manifest remains with `pending` status. The app may already be closed and the core deleted.

The [cleanup script](../scripts/clean-cores.ts) removes only regular `process.core` files inside run folders validated against `source.json` and the expected folder name. Symlinks and other artifacts are skipped. Unreadable runs are reported without stopping cleanup. See the [README](../README.md#cleanup) for commands.

## Development

Log levels are `[INFO]`, `[SUCCESS]`, `[WARN]`, and `[ERROR]`. Warnings and errors go to stderr. Streamed command output includes the executable name and keeps its original stdout/stderr stream. Colors are off when redirected. Use `NO_COLOR=1` or `FORCE_COLOR=1` to override.

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

`UNIPA_PYTHON=/path/to/python3` selects the Python interpreter.
