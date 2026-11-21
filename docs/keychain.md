# Isolated Keychain storage

Apps use Keychain storage for credentials, tokens, keys, and persistent identifiers. unipa's local store is the default for the generated Mac app. To use the system Keychain instead:

```bash
unipa --app /Applications/Example.app --macos --native-keychain
```

## Storage and identity

```text
~/Library/Application Support/unipa/Keychain/
└── <bundle-id>/
    ├── default.db
    └── second.db
```

The instance name selects the database file. Rebuilding with the same bundle ID and instance reuses the store. Removing the app or output folder does not delete its records.

`--bundle-id` changes the storage namespace. `--bundle-id random` creates a new one each run. Renaming the app has no effect.

Instances separate Keychain databases only. Copies with the same bundle ID share macOS app identity and may share other app data. Use [`--bundle-id`](bundle.md) for a separate identity.

Apps still generate their own identifiers. Isolating Keychain storage does not reset `identifierForVendor`, preferences, files, or server-side identity.

## Switching instances

Use **unipa → Keychain** to select an instance or create one with **New Instance…**. Changes apply after restarting. **Clear** deletes the active instance's records and quits the app.

Apps start with the `default` instance. Menu selections are saved in app preferences.

Preferences and files remain shared, so switching Keychains may not switch every account-related value. Apps often keep device IDs and addresses in preferences, which **unipa → Reset App…** clears.

## Compatibility and security

`src/hooks/keychain/interpose.m` intercepts `SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate`, and `SecItemDelete`. The SQLite backend in `src/hooks/keychain/store.m` supports generic and internet passwords, exportable software keys, and certificates, including queries, updates, duplicates, and persistent references.

**Values, including passwords and exportable private keys, are stored without encryption.** Directories use `0700` and databases use `0600`. Sandbox access is limited to the app's own Keychain folder, so other bundle IDs' stores stay unreadable. These permissions do not protect against other software running as the same user.

Accessibility attributes are stored as metadata, not enforced. User-presence controls, iCloud synchronization, nonexportable or Secure Enclave keys, identities, `kSecValueRef` queries, and unsupported options return an error. There is no fallback to another store. Use native Keychain when its security properties are needed.

`SecKeyCreateRandomKey` and `SecKeyGeneratePair` use the native software-key generator. Permanent key records are saved transactionally in the selected store. Ephemeral keys are not saved. Secure Enclave, token-backed keys, and access controls are rejected.

`kSecUseDataProtectionKeychain` is accepted as a routing selector. Both values use the same selected database without enabling Apple's Data Protection Keychain or encryption.

## PlayCover

This option applies only to `--macos` output. The IPA keeps its existing Keychain behavior. No PlayTools or PlayChain code is included, and PlayCover databases are untouched. Inputs containing PlayTools are rejected when isolated storage is enabled.
