# PeakActivity iOS companion prototype

This is a limited SwiftUI companion, not a desktop-equivalent tracker. It supports
encrypted manual entries and a local manual-entry report. The optional Apple picker
is shown only after the user explicitly starts the Screen Time flow; the app stores
the resulting opaque `FamilyActivitySelection` token and never enumerates app names,
bundle identifiers, window titles or web URLs.

## Capability status

| Capability | Candidate state |
| --- | --- |
| Manual/offline entry and local daily summary | Implemented in source; Xcode tests pending |
| Family Controls picker | Prototype; development entitlement and regional/device support not verified |
| Automatic Screen Time usage report | Unavailable; no DeviceActivity report extension is included |
| Desktop app/window/browser tracking | Unsupported on iOS |
| Shared E2EE sync | Unavailable; no signed iOS native bridge or relay consent is configured |
| AI | Off; no model, endpoint or network client exists |

## Local protection

Manual state and opaque selection tokens are AES-GCM encrypted. The 256-bit vault
key is stored in the device-only Keychain; an existing encrypted file with a missing
Keychain key fails closed. The Application Support file uses complete file
protection and is excluded from device backup. No networking, analytics or account
flow is implemented.

## External gates

Apple Family Controls distribution entitlement approval, region/device support,
App Store privacy-manifest review, package identity, signing, Xcode/simulator builds,
and physical-device accessibility/performance checks are not approved or verified.
The project identifier is a development placeholder and is not registered for
distribution.
