# Contributing to DocScanner

Thanks for taking the time to improve DocScanner. Focused fixes, tests, accessibility work, documentation corrections, and well-scoped feature proposals are welcome.

## Before you start

- Search the existing issues before opening a new one.
- Open an issue before starting a large feature or architectural change. This avoids spending time on work that does not fit the project.
- Report suspected vulnerabilities through [SECURITY.md](SECURITY.md), not a public issue.
- Do not attach personal documents, App Store credentials, signing certificates, purchase receipts, or other secrets.

## Development setup

Fork the repository on GitHub and use your fork's clone URL in the [README setup steps](README.md#build-from-source). Use the `document-scaner-StoreKit` scheme to test purchases with the checked-in StoreKit configuration.

If you need a local build override, copy `Config/LocalOverrides.xcconfig.example` to `Config/LocalOverrides.xcconfig`. Git ignores the copied file. Never commit credentials or private product configuration.

## Make a change

1. Create a branch from the latest `main`.
2. Keep the change focused. Avoid unrelated formatting or generated-file churn.
3. Match the existing Swift and SwiftUI style.
4. Add or update tests when behavior changes.
5. Update documentation when setup, behavior, privacy, storage, or security changes.

## Run tests

The test targets require iOS or iPadOS 17 or later. In Xcode, select the `document-scaner` scheme and a compatible simulator. Run `document-scanerTests` from the Test navigator.

From the repository root, list available simulators with `xcrun simctl list devices available`. Replace `SIMULATOR_UDID` with the identifier of a compatible simulator.

```bash
xcodebuild test \
  -project document-scaner.xcodeproj \
  -scheme document-scaner \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -only-testing:document-scanerTests
```

The regular unit run skips checks that require the isolated `tn.document-scaner.performance` build. Some UI tests also need that build to seed sample documents. See the [vault transfer runbook](docs/VAULT_TRANSFER.md#repeat-simulator-verification) for the legacy-vault checks.

For interface changes, test the affected screen on the smallest supported iPhone layout and an iPad layout. Check light and dark appearances, larger text, VoiceOver labels, empty states, loading states, and error states when they apply. Include before-and-after screenshots in the pull request.

## Pull requests

Fill out the pull-request template and explain the user-visible effect. Link the issue when one exists. A reviewer should be able to understand what changed, why it changed, and how you verified it without reconstructing the work from the commit history.

Pull requests should:

- Build without new warnings
- Pass the existing test suite
- Include tests for changed logic when practical
- Keep document content and sensitive metadata out of logs and fixtures
- Preserve on-device processing unless a proposal has been discussed first
- Avoid adding a third-party dependency when an Apple framework or a small local implementation is sufficient

The maintainer may ask for changes, close work that is out of scope, or squash commits before merging.

## Licensing

By submitting a contribution, you confirm that you have the right to submit it and agree that it will be licensed under the repository's [MIT License](LICENSE). Do not submit code copied from a source with incompatible terms.

DocScanner's original visual assets have separate terms. Use them only for work on this project unless you have written permission from the owner. See [BRAND_ASSETS.md](BRAND_ASSETS.md).

Participation in this project is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).
