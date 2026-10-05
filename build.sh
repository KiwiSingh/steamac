#!/usr/bin/env bash
# Build everything steamac needs, in dependency order. Each step is idempotent and can be
# re-run on its own (see README.md). Needs: macOS 26+ on Apple silicon, Xcode, Homebrew,
# rustup, OrbStack (or another Docker with arm64 + privileged containers).
#
#   ./build.sh            host stack, guest kernel, guest Venus Mesa, disk image
#   ./build.sh host       only the macOS side (MoltenVK, virglrenderer, libkrun, launcher)
#   ./build.sh guest      only the guest side (kernel, rootfs, Mesa, initramfs, layer, disk)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# Keep build scratch, Python downloads and Rust toolchains beside this external checkout.
export TMPDIR="$PWD/work/tmp"
export PIP_CACHE_DIR="$PWD/work/cache/pip"
export CARGO_HOME="$PWD/work/cargo"
export RUSTUP_HOME="$PWD/work/rustup"
mkdir -p "$TMPDIR" "$PIP_CACHE_DIR" "$CARGO_HOME" "$RUSTUP_HOME"

host() {
    host/vulkan/build.sh
    host/virglrenderer/build.sh
    host/libkrun/build.sh
    host/launcher/build.sh
}

guest() {
    guest/kernel/build.sh
    scripts/build-image.sh builder rootfs      # verified OTA rootfs, needed by the Mesa verify step
    guest/mesa/build.sh
    scripts/build-image.sh initramfs layer disk check
}

case ${1:-all} in
    host) host ;;
    guest) guest ;;
    all) host; guest ;;
    *) echo "usage: $0 [all|host|guest]" >&2; exit 64 ;;
esac
