#!/bin/sh

set -eu

idevice_revision="d32c8189c51c2789496b0768039419c3705498c3"
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_root="${RUNNER_TEMP:-/tmp}/stikdebug-idevice"

rm -rf "$source_root"
git clone --filter=blob:none https://github.com/jkcoxson/idevice.git "$source_root"
git -C "$source_root" checkout --detach "$idevice_revision"
cp "$repository_root/.github/idevice/remote_control.rs" "$source_root/ffi/src/remote_control.rs"
git -C "$source_root" apply "$repository_root/.github/idevice/remote-control.patch"

rustup target add aarch64-apple-ios
sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
(
    cd "$source_root/ffi"
    SDKROOT="$sdk_path" \
        RUSTFLAGS="-C link-arg=-L$sdk_path/usr/lib" \
        BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$sdk_path" \
        IPHONEOS_DEPLOYMENT_TARGET=17.0 \
        cargo build --release --target aarch64-apple-ios --features obfuscate
)

cp "$source_root/target/aarch64-apple-ios/release/libidevice_ffi.a" \
    "$repository_root/StikDebug/idevice/libidevice_ffi.a"
cp "$source_root/ffi/idevice.h" "$repository_root/StikDebug/idevice/idevice.h"
