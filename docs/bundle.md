# Bundle settings

`--bundle-id` and `--bundle-name` change the staged app used to build the IPA. With `--macos`, the same requested values also apply to the Mac app. The installed source app is never modified.

## Bundle ID

Append a random suffix to the original bundle ID:

```bash
unipa --app /Applications/Example.app --bundle-id random
```

For example, `com.example.app` becomes `com.example.app.a1b2c3d4`.

To use an exact ID:

```bash
unipa --app /Applications/Example.app --bundle-id com.example.mycopy
```

An explicit ID gets no additional suffix in either output. Related nested app and extension IDs that start with the original ID plus a dot receive the same prefix change. Framework and resource bundle IDs are left alone. The same prefix rules apply to the Mac copy’s default ID.

Without this flag, the IPA keeps its original ID. The Mac copy uses `.unipalocal`, with an additional instance suffix for a nondefault isolated Keychain instance. An explicit `--bundle-id` overrides those Mac suffixes.

Bundle IDs may contain letters, digits, hyphens, and dots. Underscores and empty components are not accepted.

## App name

`--bundle-name` is optional. Omit it to keep the app's existing name, or supply an exact name:

```bash
unipa --app /Applications/Example.app --bundle-name "Example Test"
```

Use `--bundle-name random` to generate a name such as `Example_a1b2c3d4`. When both flags use `random`, they share one suffix generated once per run:

```bash
unipa --app /Applications/Example.app --bundle-id random --bundle-name random --macos
```

The name changes the staged `.app` directory, IPA filename, bundle/display names, and localized display names. The executable filename stays the same. Without a name override, the IPA retains the inner bundle's directory name; the Mac app filename uses its display name, falling back to its bundle name. Unsafe filename characters are replaced, and long filenames are shortened to fit filesystem limits. Display names are preserved.

Bare `--bundle-id` and `--bundle-name` also request random values. The resolved settings are recorded under `bundle` in `manifest.json`; pass the exact values to reuse them on a later run.

## Signing and identity

Metadata changes happen after recovery and before injection, signing, and packaging. Changing an ID does not update provisioning profiles, App Groups, Keychain access groups, URL schemes, or IDs embedded in application code and SDK configuration. Apps and backend services that depend on the original ID may stop working.

The IPA still needs suitable signing and provisioning for an iPhone or iPad; see [installing the IPA](../README.md#installing-the-ipa). Mac conversion has its own [sandbox and signing settings](catalyst.md).

With [isolated Keychain storage](keychain.md), the overridden ID also selects the Mac app's storage namespace. Renaming alone does not separate records, and changing the bundle ID does not guarantee a new device identifier.
