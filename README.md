# PeakActivity Android development candidate

This isolated branch is an unpublished development candidate. It is not a Google
Play or F-Droid release, and no APK/AAB is approved for distribution or publication.
Inherited tag, signing and publish workflow steps and encrypted signing
credentials have been removed from this candidate. The existing application ID
remains unchanged pending an explicit migration decision; no release is approved.

PeakActivity Android uses UsageStats only after the user starts recording.
Browser URL/title and media-session sources require separate opt-ins. Reports,
manual entry and settings remain available when capture is paused or UsageStats
access is denied. Local E2EE pairing and recovery are available in the WebView
settings. Network sync remains off until the Android relay worker and signed Egress
policy are configured.

The native **Plan and sync access** menu imports a signed entitlement JSON document
only after an explicit user action. Rust verifies the document against release-owned
entitlement keys; imported documents cannot install trust keys. Billing proof uses
its own Android Keystore key and an encrypted file excluded from backup. Global
revocation checkpoints are append-only OS Keystore aliases, separate from SQLCipher,
and contain no account or activity ID. This prevents rolling back the checkpoint by
restoring older app files; whole-OS/Keystore rollback and rooted-device resistance are
not established. The UI reports the key's actual hardware/software protection and
unknown protection fails closed. The 4096-marker limit fails closed when exhausted.
([Android Keystore](https://developer.android.com/privacy-and-security/keystore),
[KeyInfo](https://developer.android.com/reference/android/security/keystore/KeyInfo)).
Current signed revocation state and the `e2ee-sync` feature are required for network
access. Local history, export, decrypt, deletion and pause remain available without
a paid entitlement. No billing provider, login, checkout or account flow is added.

## Local source checks

Run the dependency-free mobile privacy contract:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_mobile_privacy.py' -v
```

Android instrumentation, Play Data Safety declarations, signing identity and
store acceptance remain open and must be completed before distribution.

## Native build

Use JDK 17 or 21, Android SDK 36, NDK `28.2.13676358`, Python 3 and Rust
with the Android targets installed. Build the WebUI
first. Gradle compiles the SQLCipher-enabled Rust server and shared E2EE code,
then checks its ELF architecture and 16 KB segment alignment before packaging.
Missing Rust sources, WebUI assets or native toolchains fail the build.

```sh
rustup target add aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android
./gradlew :mobile:assembleDebug
```

The default sources are the initialized `aw-server-rust` submodule and its
`aw-webui/dist`. For sibling development checkouts, use:

```sh
./gradlew :mobile:assembleDebug \
  -PrustSource=../aw-server-rust -PwebuiDist=../aw-webui/dist
```

Release builds retain all four supported ABIs; debug APKs retain arm64-v8a and
x86_64. Set `-PnativeAbis=x86_64` for an emulator-only build, or
`-PnativeAbis=arm64-v8a,x86_64` to compile only the modern targets. Generated libraries live under
`mobile/build/generated/jniLibs`; old `src/main/jniLibs` files are not packaged.
The retired folder-sync library is not required. JVM unit tests do not need to
build JNI, and run with the same unmodified Gradle configuration.

Gradle project and buildscript dependencies use committed strict lockfiles.
Normal builds require the recorded lock state and do not update it. To review
an intentional dependency change, first resolve the project and build-tool graphs:

```sh
./gradlew dependencies :mobile:dependencies --write-locks --no-daemon --max-workers=1
```

Reports alone miss configurations created during task execution, including
`androidApis`. Generate that state with these representative JVM tests:

```sh
./gradlew :mobile:testDebugUnitTest \
  --tests net.activitywatch.android.VaultKeyStoreTest \
  --tests net.activitywatch.android.workers.SyncWorkerPolicyTest \
  --tests net.activitywatch.android.CaptureSourcesTest \
  --write-locks --no-daemon --max-workers=1
```

These tests do not build JNI or an APK. Repeat this task without `--write-locks`,
with `--offline --rerun`, to execute the tests again against unchanged locks.
Other build variants may create additional configurations; generate their state
with the actual reviewed task instead of weakening strict locking.

Review and commit the generated `gradle.lockfile` and
`buildscript-gradle.lockfile` files together with the dependency change. After
the required metadata is cached, the same command without `--write-locks` and
with `--offline` checks the lock state. Check that the report has no `FAILED`
dependencies: Gradle's reporting tasks can exit successfully when resolution
fails. Locks fix resolved module versions; they do not verify dependency bytes,
complete the SBOM or approve a release.
