# Isolated Keychain storage

Keychain storage is needed at runtime by apps that save credentials, tokens, keys, or persistent identifiers. It is not required to decrypt an app or build an IPA. Native Keychain behavior remains the default.

For a generated Mac app, enable the optional compatibility layer:

```bash
unipa --app /Applications/Example.app --macos --isolated-keychain
```

To use another persistent instance:

```bash
unipa --app /Applications/Example.app --macos --keychain-instance second
```

`--keychain-instance` enables isolated storage and requires `--macos`. Names contain 1–64 letters, digits, dots, underscores, or hyphens, starting with a letter or digit. The instance name is the database filename without `.db`. The default is `default.db`. Storage bundle IDs and instance names are case-insensitive and normalized to lowercase for consistent behavior across filesystems.

## Storage and identity

```text
~/Library/Application Support/unipa/Keychain/
└── <original-bundle-id>/
    ├── default.db
    └── second.db
```

Stores are keyed by bundle ID and instance. `--bundle-id` changes the storage namespace, and `--bundle-id random` creates a new one each run. `--bundle-name` has no effect. Rebuilding with the same bundle and instance reuses the store, which persists across restarts, app moves on the same Mac, and output-folder deletion.

Directories are created during conversion with mode `0700`, and databases are created on first use with `0600`. Sandbox write access covers only the selected database and its SQLite journal/WAL/SHM files. Parent-directory read access does not grant access to other databases.

Without `--bundle-id`, each nondefault instance gets a separate `.unipalocal.instance-<hash>` bundle ID and macOS container. An explicit ID is kept as supplied, so different databases can share a macOS app identity. See [bundle settings](bundle.md). Removing the app does not delete its records.

The app continues generating its own identifiers. Values stored through the intercepted APIs remain in the selected store. This does not override `identifierForVendor`, preferences, files, Secure Enclave keys, or server-side identity. Changing the generated bundle identifier may affect app behavior independently of Keychain storage.

## Compatibility

`src/hooks/keychain.m` interposes `SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate`, and `SecItemDelete`. The SQLite store in `src/keychain/store.m` supports generic and internet passwords, exportable software keys, and certificates. It handles duplicates, attribute queries, return flags, match limits, and store-specific persistent references. Indexed lookups narrow the search, single-result reads stop at the first match, and updates and deletes are transactional.

This is a local compatibility store, not Apple's protected Keychain. **Database values, including passwords and exportable private keys, are not encrypted by this backend.** Filesystem permissions restrict access by other users. They do not protect against software running as the same user. Accessibility attributes are metadata, not enforced lock-state policies. Use native Keychain when its security properties are needed.

User-presence access controls, iCloud synchronization, nonexportable or Secure Enclave keys, identities, queries using `kSecValueRef`, and unsupported query options return an error. The layer never falls back to another store. It also intercepts `SecKeyCreateRandomKey` and `SecKeyGeneratePair`: software keys use the native generator with the requested algorithm, then permanent private/public records are saved transactionally in the selected database. Ephemeral keys are not saved. Requests for Secure Enclave, token-backed keys, or access controls are rejected rather than converted to ordinary software keys. Other Security.framework APIs are not replaced.

`kSecUseDataProtectionKeychain` is accepted as a routing selector for this local store, including Firebase/GoogleUtilities queries. It does not enable Apple's Data Protection Keychain or add encryption. Both selector values address the same selected unipa database.

## PlayCover

This option applies only to the separate `--macos` output. The IPA keeps its original Keychain behavior. No PlayTools or PlayChain code is embedded, and unipa does not read, migrate, modify, or delete PlayCover databases. Conversion rejects isolated storage when the input already includes PlayTools, to avoid competing interceptors.

## Verification

```bash
python3 -B -m unittest discover -s tests -p test_keychain.py -v
bun test tests/keychain.test.ts
```

Tests use synthetic records, temporary stores, and uniquely named fixture apps. They exercise persistence across processes, bundle and instance isolation, CRUD, duplicate handling, return formats, binary values, software-key signing, certificates, concurrent writers, native software-key generation (EC and RSA), key-pair rollback, invalid attribute types, unsafe paths, and actual interposed Security.framework calls under the app sandbox. They do not open existing PlayCover databases or application records.

## Startup failures

The compatibility layer is shared by all generated apps and contains no app-specific device-ID or startup patches. A missing dependency, failed network request, or assertion in the app still needs its own diagnosis. Keychain operation success does not guarantee that every converted iOS app can start or use its backend.
