# Document security design

This document describes the on-device secure-folder format and its recovery rules. It is part of the versioning contract for DocScanner 2.0.

## Trust boundary and keys

The app creates one random 256-bit root vault key after checking an unfiltered inventory of protected metadata, files, and unfinished security operations. Key creation runs only through the secure-folder creation path. Opening a folder never generates a key.

`VaultKeyStore` writes the key as a generic-password item explicitly scoped to `group.tn.document-scaner.app.vault`, with `userPresence` and `kSecAttrAccessibleWhenUnlocked`. The seller bridge reads the previous selector in the default Keychain group. It writes the same key to the App Group, reads it back, and compares it before reporting success. The item in the default group remains untouched. If two readable items disagree, the app returns a conflict. The two selectors use different account names so the legacy query cannot match the new item. See the [transfer runbook](VAULT_TRANSFER.md) for signing and rollout.

A successful Face ID, Touch ID, or device-passcode action returns a memory-only, folder-scoped `VaultAccess`. Access is invalidated when the user leaves the secure navigation flow, the app becomes inactive, protected data becomes unavailable, or an unrecoverable secure operation fails.

The root key, unlocked state, generated PDF passwords, and decrypted titles are never written to Core Data, UserDefaults, logs, analytics, or filenames. Removing the app or losing a device without a usable backup can make secure documents unrecoverable.

## Vault asset format, version 1

PDF and preview assets use a binary `DSVAULT1` envelope containing the format version, asset kind, document UUID, a random 32-byte salt, original plaintext length, 1 MiB chunk size, chunk count, and length-prefixed AES-GCM sealed chunks.

For each asset, HKDF-SHA256 derives a key from the root key. The HKDF info binds the document UUID, asset kind, and format version. Every chunk uses a fresh 12-byte AES-GCM nonce. The canonical header and chunk index are authenticated as associated data. Readers reject unknown versions, mismatched document or asset identifiers, malformed lengths, missing or reordered chunks, trailing bytes, and authentication failures before returning plaintext.

Titles use a separate `DSTITLE1` AES-GCM envelope and an independently derived title key. Title encryption is bound to the document UUID, allowing secure-to-secure moves to change only folder metadata. Secure records keep `title` and `normalizedTitle` empty. Only `secureTitleBlob` contains the encrypted title.

Vault, staging, recovery, and sensitive temporary files use complete file protection. Decrypted previews and titles stay in memory. Short-lived plaintext PDF files needed for sharing also use complete protection and are removed after sharing.

## Transaction and recovery protocol

`DocumentSecurityCoordinator` exclusively owns moves across the normal and secure boundary. Each operation writes a durable manifest containing no keys, passwords, titles, or plaintext content. The phases are staging, originals moved to recovery, replacements installed, metadata committed, and cleanup.

The coordinator stages every replacement before changing live data. Encrypted output is reopened, authenticated, decrypted, and checksum-verified. Decrypted PDFs are reopened to verify page count, and previews are decoded to verify readability. Originals then move to recovery, replacements move to final paths, and all filenames, protection fields, title blobs, folder relationships, and folder security state are committed in one Core Data save. Recovery data is deleted only after that save succeeds.

Before metadata commit, cancellation or failure restores all originals and leaves the previous metadata state intact. At launch, manifests are compared with Core Data. If the commit did not occur, originals are restored. If it did occur, stale staging and recovery data are removed. Format changes must introduce a new envelope version and reader. The shipped version 1 layout must not be changed in place.

## Encrypted vault backup, version 1

A vault backup contains a versioned `DSBACK01` header, an AES-GCM encrypted manifest, and the original encrypted PDF and preview envelopes. CryptoKit generates a new 256-bit secret for each export. The displayed Base64 code encodes that secret directly. The authenticated manifest binds the format header and each asset's length, document UUID, and kind. It contains the vault key, folder metadata, and encrypted title blobs. The asset envelopes authenticate each chunk with the recovered root key. The code stays out of the archive and is not saved by DocScanner.

Restore authenticates the manifest, titles, and all asset chunks before changing the library. It rejects unknown versions, filename and identity collisions, missing or trailing bytes, and inconsistent metadata. For an existing vault, it verifies all current protected files and titles with the candidate key before installing it. If there are no encrypted documents to verify in an existing vault, restore requires an already accessible matching key. No document rows or files are merged or replaced in an existing vault.

On a device without an existing vault, restore checks for database conflicts, reads back the App Group key, and installs only verified encrypted files without replacing destination files. It makes the new folders and document references visible in one Core Data save. If the process stops after inserting the Keychain item or some files, retrying the same archive reuses the matching key and identical files. A failed save removes files installed by that attempt; it keeps earlier files and all preexisting keys. Normal unlock and backup need device authentication, and restore requires both the recovery code and device authentication. These paths do not depend on a Pro cache.

## PDF sharing

Password-protected sharing uses PDFKit owner and user password write options. The user password contains 16 random characters displayed in four groups, and the three visible dashes are part of the actual PDF password. Reveal, copy, and manual entry therefore use exactly the same value. Quality conversion happens before the password-protected final write. The app reopens the result and verifies that it is encrypted and locked, a wrong password fails, the generated password unlocks it, the page count matches, and searchable text remains. The saved master PDF is never modified. PDFKit encryption is described only as native PDF password protection, not as AES-256.

## Export compliance

The implementation uses Apple operating-system cryptography through CryptoKit, Security, Keychain, and PDFKit. `ITSAppUsesNonExemptEncryption` is set to `false` for the corresponding exempt classification. Release owners must confirm the App Store Connect answers against Apple's current export-compliance guidance before each submission.
