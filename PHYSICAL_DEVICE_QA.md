# Secure Folders Physical-Device QA

Run this matrix on physical iPhone and iPad hardware. The implementation build intentionally does not use an Apple simulator.

## Device and accessibility coverage

- iOS 16, 17, 18, and 26 where devices are available
- Face ID device, Touch ID device, and device-passcode fallback
- No passcode configured, biometric lockout, changed biometric enrollment, and protected-data-unavailable transitions
- iPhone and iPad, light and dark appearance, large accessibility text sizes, and VoiceOver

## Secure-folder workflow

1. Create a normal folder and a secure folder. Confirm the secure switch resets off each time the form opens and cancellation leaves the form open.
2. Unlock with biometrics and passcode fallback. Confirm one authentication covers folder search, detail, rename, move, add-existing, scan, and share until the flow is left.
3. Cancel authentication. Confirm only the locked state and folder metadata are visible.
4. Search globally for a known secure title or OCR phrase. Confirm no result appears. Search the unlocked folder and confirm normalized title matching works.
5. Background the app from the folder, detail, search, conversion, and sharing screens. Confirm an opaque shield appears before the app-switcher snapshot, pages and thumbnails clear, conversion rolls back, and return requires an explicit Unlock tap.
6. Exercise normal-to-secure, secure-to-normal, secure-to-secure, add-existing, scan into secure, remove security, delete-and-keep, and delete-everything flows. Confirm filenames are opaque in the vault and no plaintext title exists in Core Data.
7. Trigger memory pressure and protected-data loss where tooling permits. Confirm decrypted thumbnails and access capabilities are cleared.

## Transaction recovery

For each staging, recovery-move, final-install, metadata-save, and cleanup phase, force terminate the app and relaunch. Repeat with low storage. Confirm startup either restores the complete previous state or retains the complete committed state. No metadata record may point to content with the opposite protection state.

## PDF sharing

1. Test Low, Medium, High, and Very High exports from normal and secure documents, with password protection on and off.
2. Confirm secure documents default on and normal documents default off for every new share presentation.
3. Reveal, hide, regenerate, and explicitly copy the password. Confirm the clipboard item is local-only, expires after five minutes, and is never copied merely by tapping Share.
4. Confirm a wrong password fails and the displayed generated password opens the protected copy in Apple Files, macOS Preview, Adobe Acrobat, Safari, and another common browser viewer.
5. Confirm page count and selectable/searchable OCR text remain intact after unlock, and the original master PDF checksum never changes.
6. Complete and cancel the share sheet. Confirm temporary plaintext and password-protected exports are removed in both cases.

Record device model, OS version, authentication method, document size/page count, test result, and any recovery artifacts for every run.
