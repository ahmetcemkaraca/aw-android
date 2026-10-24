#!/bin/bash
set -euo pipefail

: "${PROJECT_DIR:?Xcode PROJECT_DIR is required}"
: "${DERIVED_FILE_DIR:?Xcode DERIVED_FILE_DIR is required}"
: "${ARCHS:?Xcode ARCHS is required}"
: "${PLATFORM_NAME:?Xcode PLATFORM_NAME is required}"

PEAKACTIVITY_CORE="${PEAKACTIVITY_CORE_DIR:-${PROJECT_DIR}/../aw-server-rust}"
PEAKACTIVITY_UI="${PEAKACTIVITY_WEBUI_DIR:-${PEAKACTIVITY_CORE}/aw-webui/dist}"
test -f "${PEAKACTIVITY_CORE}/aw-server/src/companion.rs" || {
    echo 'The reviewed shared companion binding is missing from the Core checkout.' >&2
    exit 1
}
test -f "${PEAKACTIVITY_UI}/index.html" || {
    echo 'Build the reviewed Core WebUI assets before compiling the shared native library.' >&2
    exit 1
}

PEAKACTIVITY_CARGO_TARGET="${DERIVED_FILE_DIR}/peakactivity-cargo"
read -r -a PEAKACTIVITY_ARCHITECTURES <<< "${ARCHS}"
PEAKACTIVITY_LIBRARIES=()
for PEAKACTIVITY_ARCH in "${PEAKACTIVITY_ARCHITECTURES[@]}"; do
    case "${PLATFORM_NAME}:${PEAKACTIVITY_ARCH}" in
        iphoneos:arm64) PEAKACTIVITY_RUST_TARGET=aarch64-apple-ios ;;
        iphonesimulator:arm64) PEAKACTIVITY_RUST_TARGET=aarch64-apple-ios-sim ;;
        iphonesimulator:x86_64) PEAKACTIVITY_RUST_TARGET=x86_64-apple-ios ;;
        *) echo 'Unsupported iOS Rust build target.' >&2; exit 1 ;;
    esac
    AW_WEBUI_DIR="${PEAKACTIVITY_UI}" CARGO_TARGET_DIR="${PEAKACTIVITY_CARGO_TARGET}" \
        cargo build --manifest-path "${PEAKACTIVITY_CORE}/Cargo.toml" --locked --release \
        --target "${PEAKACTIVITY_RUST_TARGET}" -p aw-server --lib \
        --no-default-features --features companion,encryption-vendored
    PEAKACTIVITY_LIBRARIES+=("${PEAKACTIVITY_CARGO_TARGET}/${PEAKACTIVITY_RUST_TARGET}/release/libaw_server.a")
done
PEAKACTIVITY_LIBRARY_DIR="${DERIVED_FILE_DIR}/peakactivity-rust"
mkdir -p "${PEAKACTIVITY_LIBRARY_DIR}"
lipo -create "${PEAKACTIVITY_LIBRARIES[@]}" -output "${PEAKACTIVITY_LIBRARY_DIR}/libaw_server.a"
