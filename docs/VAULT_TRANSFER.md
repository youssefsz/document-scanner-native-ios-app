# Transfer an app with existing secure folders

The App Store release before the bridge stores its vault key in the seller's default Keychain group. Installing an update signed by another team can make that item inaccessible. The bridge preserves access by copying the same key after a device authentication prompt. It keeps the old item and leaves the existing PDFs, previews, titles, and encryption format intact. See [Apple DTS's transfer procedure](https://developer.apple.com/forums/thread/706128) and [Apple's App Groups handoff instructions](https://developer.apple.com/help/app-store-connect/transfer-an-app/overview-of-app-transfer#apps-using-app-groups).

## Provision the seller's bridge

1. Have the seller's Account Holder or Admin open **Certificates, Identifiers & Profiles > Identifiers > + > App Groups**. Register `group.tn.document-scaner.app.vault` with the description **DocScanner Vault**. This identifier is reserved for DocScanner. If the portal says it is unavailable, stop and resolve that before signing a bridge. See [Register an app group](https://developer.apple.com/help/account/identifiers/register-an-app-group/).
2. Open the existing DocScanner iOS App ID, `tn.document-scaner.app` in this project. Enable **App Groups > Configure**, select the exact group, then **Assign**. Leave other apps out of this group. Refresh or regenerate the development and App Store provisioning profiles. See [Enable app capabilities](https://developer.apple.com/help/account/identifiers/enable-app-capabilities/).
3. Build under the current seller team, `5S4ZT4SRV9`. Compare the production App Store build's application identifier with the seller bridge's application identifier. The bridge must still be able to access the old default group. Inspect its signed entitlements and provisioning profile; both must authorize the exact group. Do not configure a separate, team-prefixed Keychain Sharing group for it.

   ```sh
   codesign -d --entitlements - "/path/to/DocScanner.app"
   security cms -D -i "/path/to/DocScanner.app/embedded.mobileprovision" | plutil -extract Entitlements xml1 -o - -
   ```
4. Pass the seller portion of the device check below before releasing the bridge. The bridge offers **Unlock Now** or **Remind Me Later** after loading a library with a secure folder. Dismissing the sheet defers it for 24 hours, and the Folders tab still offers an unlock. A verified App Group key retires the reminder. In the release notes and customer communications, ask users to update, open a secure folder, authenticate, and check **Ready for transfer** in **Settings > Vault Transfer & Backup**. Advise them to export an encrypted backup and store the recovery code separately. Give users time to do both before initiating any transfer.

## Hand the group to the buyer

1. Keep a seller-signed bridge on the test device. Have both account holders agree on the handoff window and confirm the buyer is ready to register the group. Wait for the app transfer to finish before changing the group. Apple DTS warns that another team can register the identifier in the gap between removal and registration.
2. After the transfer, the seller removes the dedicated App Group from the seller's account. The buyer immediately registers the exact same identifier, assigns it to the transferred iOS App ID, and generates the buyer's provisioning profiles. Keep the production bundle ID and the lifetime Pro product identifier `tn.documentscaner.app.pro.lifetime`. If the buyer cannot register or provision the exact group, hold the release.
3. Set `VaultTransferReminderEnabled` to `false` in `document-scaner-Info.plist` for the buyer build. Verify the buyer's signed entitlements. Install the buyer-signed TestFlight build over the seller bridge on the same test device. Pass the device check before releasing the buyer build. Keep backup and recovery available in future builds.

The user can install the buyer's update directly from a version that predates the bridge. If the only key is in the inaccessible seller group and the user has no usable backup, DocScanner cannot decrypt the vault. It shows **Vault recovery needed** and keeps the encrypted data in place. A buyer build or a restored Pro purchase cannot recreate the original key. Tell the user to keep the app installed and retain any archive and recovery code they have. If they still have another device running an authorized seller bridge with a usable vault, they can export a backup from that device.

## Check on a physical iPhone

These steps belong to the app owner and buyer. Use a device with a passcode and sample data only. Never delete or offload DocScanner for the check, and never share a recovery code, archive, private document, purchase receipt, or account credential.

| Install in place | What to do and report |
| --- | --- |
| Current seller App Store build | Put a synthetic one-page PDF in a new secure folder named `Transfer QA`. Set the document title to `Transfer sample`. Record the app version/build, iOS version and device model. Confirm the document title, thumbnail and PDF page all open after authentication. If this Apple Account bought lifetime Pro, verify that **Restore Purchases** works in the production build. |
| Seller-signed bridge TestFlight build, before transfer | Install over the App Store build. If asked to authenticate, cancel once and confirm the folder stays locked. Open it again and authenticate. Confirm the same title, thumbnail and PDF page. Open **Vault Transfer & Backup** from the secure folder menu or Settings and confirm **Ready for transfer**. Export an encrypted backup to Files and save its code separately. Quit and reopen DocScanner and repeat the vault check. |
| Buyer-signed internal TestFlight build, after transfer and group handoff | Install over the seller bridge. Before importing any backup, quit and reopen the app, unlock the same folder, and confirm the title, thumbnail and PDF page open. Confirm **Ready for transfer**. Report build numbers, status labels, and success or the exact visible error. Use an approved separate sample device or isolated library to test archive import if available. |
| Buyer StoreKit check | In buyer TestFlight, test **Restore Purchases** with an eligible buyer sandbox account and a prior test lifetime purchase. Expect Pro access without repurchasing. [TestFlight runs StoreKit in sandbox](https://developer.apple.com/documentation/storekit/testing-at-all-stages-of-development-with-xcode-and-the-sandbox), so this does not prove a past App Store purchase carries forward. Verify that separately on the buyer's first production build with an Apple Account that owned lifetime Pro before the transfer, before expanding distribution. |

The seller App Group is registered and assigned to DocScanner. The app owner confirmed that Face ID opens an existing secure folder on an iPhone 15 running the development-signed bridge, 2.0.4 (build 2). The seller's App Store-to-TestFlight upgrade check and the buyer's TestFlight and purchase checks remain pending. If either in-place vault check fails, stop and report the step and visible error. Leave the sample vault and backup in place.

## Repeat simulator verification

The simulator checks validate application behavior with real on-disk fixtures and the simulator's Keychain. They cannot prove production entitlement or App Group ownership across teams.

The newest installed runtime used here was iOS/iPadOS 27.0, build 24A434, on Xcode 27.0. The devices were iPhone Air (`28FAA3F9-0D5D-4760-B5B5-9391AB3BCCB5`) and iPad Air 13-inch (M4) (`D1D924B7-3E35-4186-B6F7-B2E1B60124D9`).

```sh
xcodebuild test -project document-scaner.xcodeproj -scheme document-scaner \
  -destination 'platform=iOS Simulator,id=28FAA3F9-0D5D-4760-B5B5-9391AB3BCCB5' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/docscanner-vault-bridge \
  -resultBundlePath /tmp/docscanner-vault-phone-r4.xcresult \
  -only-testing:document-scanerTests

xcodebuild test -project document-scaner.xcodeproj -scheme document-scaner \
  -destination 'platform=iOS Simulator,id=D1D924B7-3E35-4186-B6F7-B2E1B60124D9' \
  -parallel-testing-enabled NO -derivedDataPath /tmp/docscanner-vault-bridge \
  -resultBundlePath /tmp/docscanner-vault-ipad.xcresult \
  -only-testing:document-scanerTests/VaultTransferTests \
  -only-testing:document-scanerTests/VaultCryptoServiceTests \
  -only-testing:document-scanerTests/LibraryRepositoryTests \
  -only-testing:document-scanerTests/ProStoreTests

scripts/vault-transfer/smoke.sh 22c94cddbd903745d422edbc171c3f73d058c06f \
  28FAA3F9-0D5D-4760-B5B5-9391AB3BCCB5 D1D924B7-3E35-4186-B6F7-B2E1B60124D9

# For reminder UI checks, set VAULT_SMOKE_LEAVE_LEGACY=1 on the smoke command,
# then run the screen checks with VAULT_SCREENS_VARIANT=bridge.
scripts/vault-transfer/screens.sh "<Build logs directory printed by smoke.sh>" \
  28FAA3F9-0D5D-4760-B5B5-9391AB3BCCB5 D1D924B7-3E35-4186-B6F7-B2E1B60124D9
```

The smoke test builds the integration commit, creates a sample vault using its legacy Keychain and encryption code, and installs the bridge over it. It compares ciphertext hashes and opens the original title, PDF and preview both immediately and after relaunch. A second test application skips the bridge and changes the simulated signing prefix. It must report recovery and leave the encrypted assets and title untouched. Both scripts use disposable simulator bundle IDs and exclude iPhone 17 models. The screen test opens the real locked folder and Settings recovery screens in an isolated build. The bridge variant checks the reminder, snooze, verification, and backup export action.

## Support boundaries

- For a missing key, guide the user to **Restore Vault Backup** with their archive and recovery code. If encrypted documents already exist, a verified restore recovers the key and leaves the local documents as they are.
- A key mismatch, damaged archive, wrong code, unfinished vault operation, or signing error calls for investigation. Never advise the user to remove Keychain items, delete vault files, or reinstall the app to make an error disappear.
- The archive is an independent copy of the secure folders. Store the recovery code separately. Anyone with both can decrypt the contents without access to the original device.
