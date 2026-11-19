# Bundle settings

`--bundle-id` and `--bundle-name` apply to the IPA and the optional Mac copy. The installed app is never modified.

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

Nested app and extension IDs starting with `<original-id>.` receive the new prefix. Framework and resource bundle IDs stay unchanged.

Without this flag, both outputs keep the original bundle ID.

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

This renames the output app and its display names. IPA filenames use lowercase and hyphens, such as `example-test-patched.ipa`. The executable name stays the same.

Using either flag without a value also generates a random value. The chosen settings are saved under `bundle` in `manifest.json`.

## Signing and identity

Changing the bundle ID does not update provisioning profiles, App Groups, Keychain access groups, URL schemes, or IDs embedded in code and SDK configuration. SDKs and services tied to the original ID, such as Google Maps, may stop working.

The IPA still needs suitable signing and provisioning for an iPhone or iPad. See [installing the IPA](../README.md#installing-the-ipa). Mac conversion has its own [sandbox and signing settings](catalyst.md).

With [isolated Keychain storage](keychain.md), the overridden ID also selects the Mac app's storage namespace. Renaming alone does not separate records, and changing the bundle ID does not guarantee a new device identifier.
