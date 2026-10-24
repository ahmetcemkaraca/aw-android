#!/usr/bin/env bash
set -euo pipefail

rust_source="$1"
output="$2"
shift 2
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to the installed NDK}"
: "${AW_WEBUI_DIR:?Set AW_WEBUI_DIR to a built WebUI dist directory}"
: "${CARGO_TARGET_DIR:?Set CARGO_TARGET_DIR to the native build cache directory}"
if [ ! -f "$rust_source/aw-server/Cargo.toml" ]; then
    echo 'Rust server source missing; initialize the submodule or set -PrustSource.' >&2
    exit 1
fi
if [ ! -f "$AW_WEBUI_DIR/index.html" ]; then
    echo 'Built WebUI missing; build it first and set -PwebuiDist.' >&2
    exit 1
fi
test "$#" -gt 0
case "$(uname -s)" in
    Linux) host=linux-x86_64 ;;
    Darwin) host=darwin-x86_64 ;;
    *) echo 'Build JNI on Linux or macOS with the Android NDK.' >&2; exit 1 ;;
esac
toolchain="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host/bin"
export PATH="$toolchain:$PATH"

for abi in "$@"; do
    case "$abi" in
        arm64-v8a) target=aarch64-linux-android; compiler=aarch64-linux-android26 ;;
        x86_64) target=x86_64-linux-android; compiler=x86_64-linux-android26 ;;
        armeabi-v7a) target=armv7-linux-androideabi; compiler=armv7a-linux-androideabi26 ;;
        x86) target=i686-linux-android; compiler=i686-linux-android26 ;;
        *) echo "Unsupported ABI: $abi" >&2; exit 1 ;;
    esac
    target_env="${target//-/_}"
    linker_env="$(printf '%s' "$target_env" | tr '[:lower:]' '[:upper:]')"
    env "CC_$target_env=$toolchain/$compiler-clang" \
        "AR_$target_env=$toolchain/llvm-ar" \
        "RANLIB_$target_env=$toolchain/llvm-ranlib" \
        "CARGO_TARGET_${linker_env}_LINKER=$toolchain/$compiler-clang" \
        "RUSTFLAGS=${RUSTFLAGS:-} -C link-arg=-Wl,-z,max-page-size=16384" \
        cargo build --manifest-path "$rust_source/Cargo.toml" --locked \
            -p aw-server --lib --target "$target" --release \
            --no-default-features --features encryption-vendored
    mkdir -p "$output/$abi"
    cp "$CARGO_TARGET_DIR/$target/release/libaw_server.so" "$output/$abi/"
done
python3 "$(dirname "$0")/check-jnilibs.py" --directory "$output" "$@"
