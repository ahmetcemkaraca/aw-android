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
