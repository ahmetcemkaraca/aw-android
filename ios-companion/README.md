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
| Shared E2EE controls | Local pairing/recovery/device controls connected in source; native Apple build pending |
| Manual/report preparation | Explicit consent, atomic Rust projection and received aggregate report connected; Apple execution pending |
| Network synchronization | Signed-policy, explicit foreground run/stop and embedded trust resource connected in source; Apple execution and configured service pending |
| AI | Off; no model, endpoint or network client exists |

## Local protection

Manual state and opaque selection tokens are AES-GCM encrypted. The 256-bit vault
key is stored in the device-only Keychain; an existing encrypted file with a missing
Keychain key fails closed. The Application Support file uses complete file
protection and is excluded from device backup. No Swift networking or analytics is implemented. Explicit foreground sync uses only the shared Rust Privacy Firewall transport; no account flow is implemented. A separate SQLCipher `sync.db` uses the same device-only
Keychain identity and the shared Rust `SyncControl` for local pairing/recovery
commands. Missing keys, orphan recovery sidecars and linked/nonregular paths fail
closed; existing manual state is preserved. Native work runs off the main actor,
and its context closes when the scene leaves the foreground. No Family Controls
selection token or private manual note is passed to the native binding.

## Building the native binding

The Xcode source phase invokes `scripts/build-rust.sh`. Use a Core checkout with
the `companion` feature and its reviewed WebUI assets. Until the signed public
submodule update is available, set `PEAKACTIVITY_CORE_DIR` and
`PEAKACTIVITY_WEBUI_DIR` to the reviewed local candidates for development only.
Install the Rust targets matching Xcode's selected architectures:
`aarch64-apple-ios`, `aarch64-apple-ios-sim` or `x86_64-apple-ios`.
The script builds the locked shared library with vendored SQLCipher/OpenSSL and
combines simulator architecture archives. It refuses missing reviewed sources
or assets. The C ABI bounds requests at 16MiB, uses the shared worker/control gates and rejects stale handles. Foreground network work runs outside the serial Swift actor so urgent pause remains reachable. Larger snapshot transfer needs a separate bounded streaming path.

Host Rust binding tests cover actual SQLCipher persistence, shared recovery crypto,
malformed requests, wrong keys, stale handles and sidecar preservation. Written
Swift tests cover the binding, explicit null-success responses and existing local
state. Host evidence does not establish Swift compilation, Apple target linking,
simulator/device lifecycle or cross-device sync. The existing JSON recovery-profile
test alone is not crypto-vector execution.

Manual sharing is a separate explicit choice. A private, atomic source checkpoint records only locally supplied entry IDs and their digests. It is excluded from sync snapshots and cleared when a fresh recovery identity is installed. An empty local list on a new device cannot delete recovered entries; unchanged AES state cannot recreate a deleted shared row. Matching local IDs can adopt recovered rows without changing their timing or signed history. The native projection carries only
opaque entry IDs, UTC dates and durations, with a source checkpoint to preserve
newer peer corrections. Private notes and Family Controls tokens never enter the
projection request. Failed preparation leaves the AES state intact and can be
retried; privacy-filtered entries are not interpreted as deleted entries. Received
manual report totals exclude this device's entries and do not return private notes.

Sync and devices uses the existing shared pairing messages and matching-code
confirmation, encrypted recovery-file export and explicit saved-phrase confirmation.
Inactive scenes clear sensitive displays and invalidate late results. File callbacks also bind the current session and latest file operation. Foreground reopen waits for any uncancellable opening task to clean up its stale handle and retries a retained failed close before opening another context. Existing AES
decoding validates durations, timestamps, unique IDs and the entry bound before
publishing local state; invalid files remain preserved. Encrypted snapshot export and clean-vault restore use the shared activity-plus-sync continuity format. Importing the kit/snapshot and entering a phrase only prepares a local preview; a separate confirmation performs the atomic restore. Existing AES entries, notes and selection tokens are not modified.

Network controls accept only a signed service-policy bundle and an exact reviewed diff. Public trust keys are loaded at construction from the code-signed `release-trust.json` app resource, not an imported document or RPC. The development resource has no keys, so no configured service is available. A reviewed release may populate at most 32 exact Ed25519 public keys; private signing keys never belong in that file. Destination, retention and allowed fields are shown before enabling sync. A user action runs one cycle; Stop and the outbound kill switch bypass the actor running the cycle, wait for the current bounded request, then block further packets. Returning to the foreground waits for the previous context to close and starts with network sync Off. No background-sync entitlement or automatic cycle is claimed.

## External gates

Paid sync proof is imported explicitly in **Plan and sync access** and verified by
the shared Rust runtime before saving. Proof and the global revocation floor live
in a separate device-only Keychain service; neither enters the AES manual state or
SQLCipher activity database. The Swift source exposes no account identifier in the
UI or logs. `entitlement-trust.json` is a separate code-signed Bundle resource with
release-owned public keys and a minimum revocation sequence. Its development key
list is empty, so paid sync remains unavailable. Each actual network packet checks
current signed entitlement and revocation state. Local report/history, export,
decrypt, delete and pause remain available when paid access is absent or denied.
Written Swift tests cover proof separation, full UInt64 floors and rollback/corrupt
checkpoint denial; these tests have not been compiled or run on Apple platforms.

Apple Family Controls distribution entitlement approval, region/device support,
App Store privacy-manifest review, package identity, signing, Xcode/simulator builds,
and physical-device accessibility/performance checks are not approved or verified.
The project identifier is a development placeholder and is not registered for
distribution.
