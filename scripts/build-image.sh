#!/bin/bash
# Build the guest disk artifacts for steamac (run on the macOS host).
#
#   work/out/steamos.img          raw sparse GPT disk  -> guest /dev/vda
#   work/out/initramfs.cpio.gz    boot stage (busybox + guest/initramfs/init)
#   work/out/steamac-layer.img    read-only erofs /usr layer -> guest /dev/vdb
#                                 (includes guest/progress-agent, built in Rust)
#
# All loop/mkfs/btrfs work runs in a privileged linux/arm64 OrbStack container
# built from scripts/builder/Dockerfile (pinned). Idempotent: the verified
# rootfs reconstruction is cached in work/cache/, everything else is rebuilt.
#
# Usage: scripts/build-image.sh [step...]
#   steps: builder rootfs initramfs layer disk check   (default: all, in order)
# Env:   HOME_SIZE_GIB (default 64), STEAMOS_PASSWORD (default "steamos"),
#        FORCE_DISK=1 to rebuild steamos.img even if it exists (it holds user
#        state once booted, so it is never overwritten silently),
#        ALLOW_NO_VENUS=1 to build a test layer without work/out/mesa-venus.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$REPO/work
. "$REPO/scripts/config.env"

steps=("$@")
[[ ${#steps[@]} -gt 0 ]] || steps=(builder rootfs initramfs layer disk check)

DISK_DIR=${STEAMAC_DISK_DIR:-/Volumes/Zweidrive/steamac}
[[ -d /Volumes/Zweidrive && -w /Volumes/Zweidrive && $(df -P /Volumes/Zweidrive | awk 'NR == 2 {print $NF}') == /Volumes/Zweidrive ]] || { echo "Mount writable Zweidrive before building." >&2; exit 1; }
mkdir -p "$WORK/out" "$WORK/cache" "$DISK_DIR"

run_in_builder() {
    # /src: repo (read-only), /work: work dir. --privileged for loop devices.
    docker run --rm --privileged --platform linux/arm64 \
        -e HOME_SIZE_GIB -e STEAMOS_PASSWORD -e FORCE_DISK -e ALLOW_NO_VENUS \
        -e STEAMAC_DISK_DIR=/disk -v "$DISK_DIR:/disk" -v "$REPO:/src:ro" -v "$WORK:/work" \
        "$BUILDER_IMAGE" "$@"
}

for step in "${steps[@]}"; do
    echo "=== step: $step"
    case $step in
        builder)
            docker build --platform linux/arm64 -t "$BUILDER_IMAGE" \
                --build-arg BUILDER_BASE="$BUILDER_BASE" \
                --build-arg DEBIAN_SNAPSHOT="$DEBIAN_SNAPSHOT" \
                --build-arg DESYNC_VERSION="$DESYNC_VERSION" \
                --build-arg DESYNC_SHA256="$DESYNC_SHA256" \
                "$REPO/scripts/builder"
            ;;
        rootfs)    run_in_builder /src/scripts/steps/10-rootfs.sh ;;
        initramfs) run_in_builder /src/scripts/steps/20-initramfs.sh ;;
        layer)
            # guest/progress-agent (Rust, static musl) in the pinned rust container,
            # then the erofs layer (which installs the binary).
            docker run --rm --platform linux/arm64 \
                -v "$REPO:/src:ro" -v "$WORK:/work" \
                "$RUST_IMAGE" /src/scripts/steps/25-progress-agent.sh
            run_in_builder /src/scripts/steps/30-layer.sh
            ;;
        disk)      run_in_builder /src/scripts/steps/40-disk.sh ;;
        check)     run_in_builder /src/scripts/steps/50-check.sh ;;
        *) echo "unknown step $step" >&2; exit 2 ;;
    esac
done
