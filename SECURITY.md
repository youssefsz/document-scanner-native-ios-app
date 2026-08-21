# Security policy

DocScanner stores and processes documents on-device, including optional encrypted folders. Please report security problems privately so they can be investigated before public disclosure.

## Supported versions

| Version | Supported |
| --- | --- |
| 2.x | Yes |
| 1.x and earlier | No |

Only the latest App Store release and the current `main` branch receive security updates.

## Report a vulnerability

Email [dhibi.ywsf@gmail.com](mailto:dhibi.ywsf@gmail.com) with the subject `[DocScanner Security] Short description`. Do not open a public GitHub issue for a suspected vulnerability.

Include what you can safely share:

- The affected app version, build number, and commit
- Device model and iOS or iPadOS version
- Reproduction steps and a minimal proof of concept
- The impact you observed or expect
- Any suggested fix or mitigation

Do not include real scanned documents, passwords, encryption keys, personal data, or other people's data. Use synthetic test files when a sample is necessary.

You should receive an acknowledgment within seven days. Please allow time for investigation and a fix before publishing details. If a report is accepted, the maintainer will coordinate the release and disclosure timing with you.

This project does not currently offer a paid bug bounty.

## Security design

The public [security design document](docs/SECURITY_DESIGN.md) describes the vault format, key handling, transaction recovery, and protected PDF export. It is useful context, but it is not a guarantee that the implementation has no defects.
