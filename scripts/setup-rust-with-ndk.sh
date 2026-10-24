#!/usr/bin/env bash
set -euo pipefail

# Gradle and build-native.sh use the NDK directly; no toolchain mutations or
# machine-specific Cargo configuration are needed.
: "${ANDROID_HOME:=${ANDROID_SDK_ROOT:-}}"
: "${ANDROID_NDK_HOME:=${ANDROID_HOME:+$ANDROID_HOME/ndk/28.2.13676358}}"
if [ ! -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" ]; then
    echo 'Install ndk;28.2.13676358 with sdkmanager and set ANDROID_HOME.' >&2
    exit 1
fi
rustup target add aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android
