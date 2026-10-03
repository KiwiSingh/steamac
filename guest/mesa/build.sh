#!/usr/bin/env bash
# Builds the guest Venus (virtio) Vulkan ICD for the Steam Frame SteamOS image:
#   aarch64 (native: Steam, Proton ARM64EC/WoW64 unix side, gamescope, zink)
#   x86_64 + i386 (FEX-emulated x86 apps; installed into the fex-mesa pressure-vessel provider)
# Output: work/out/mesa-venus/ = tree rooted at guest "/" + MANIFEST.txt.
# Verification runs against the stock rootfs image (work/frame/rootfsA.img) in a chroot.
#
# Usage: guest/mesa/build.sh [--clean] [step...]
#   steps: fetch aarch64 x86 verify   (default: all, in that order)
#   --clean  drop the cached source volume and all outputs first
# Env overrides: ROOTFS_IMG (stock SteamOS rootfs image, btrfs).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
set -a
# shellcheck source=versions.env
source "$HERE/versions.env"
set +a

OUT=$REPO/work/out/mesa-venus
WORK=$REPO/work/build/mesa-venus
ROOTFS_IMG=${ROOTFS_IMG:-$REPO/work/frame/rootfsA.img}
SRC_VOLUME=steamac-mesa-src

clean=0
steps=()
for arg in "$@"; do
    case $arg in
        --clean) clean=1 ;;
        fetch|aarch64|x86|verify) steps+=("$arg") ;;
        *) echo "unknown argument: $arg" >&2; exit 64 ;;
    esac
done
[ ${#steps[@]} -gt 0 ] || steps=(fetch aarch64 x86 verify)

if [ "$clean" = 1 ]; then
    docker volume rm -f "$SRC_VOLUME" >/dev/null
    rm -rf "$OUT" "$WORK"
fi
mkdir -p "$OUT" "$WORK"

log() { printf '\n=== %s\n' "$*"; }

for step in "${steps[@]}"; do
    case $step in
    fetch)
        log "fetch mesa $MESA_COMMIT"
        docker run --rm --platform linux/arm64 \
            -e MESA_URL -e MESA_COMMIT -e VENUS_PROTOCOL_URL -e VENUS_PROTOCOL_COMMIT \
            -v "$SRC_VOLUME:/src" -v "$HERE/container:/scripts:ro" \
            "$TOOLS_IMAGE" sh /scripts/fetch-mesa.sh
        ;;
    aarch64)
        log "build aarch64 (log: $WORK/build-aarch64.log)"
        rm -rf "$OUT/usr/lib" "$OUT/usr/share/vulkan"
        docker run --rm --platform linux/arm64 \
            -v "$SRC_VOLUME:/src:ro" -v "$HERE/container:/scripts:ro" -v "$OUT:/out" -v "$WORK:/work" \
            "$AARCH64_IMAGE" bash /scripts/build-aarch64.sh > "$WORK/build-aarch64.log" 2>&1 \
            || { tail -40 "$WORK/build-aarch64.log"; exit 1; }
        ;;
    x86)
        log "build x86_64 + i386 (log: $WORK/build-x86.log)"
        rm -rf "$OUT/usr/share/guestos"
        docker run --rm --platform linux/amd64 \
            -e STEAMOS_X86_MIRROR -e STEAMOS_X86_BRANCH -e FEX_PROVIDER -e HOLO_KEYRING_PKG -e HOLO_KEYRING_SHA256 \
            -e LIBDISPLAY_INFO_PKG -e LIBDISPLAY_INFO_SHA256 \
            -e LIB32_LIBDISPLAY_INFO_PKG -e LIB32_LIBDISPLAY_INFO_SHA256 \
            -v "$SRC_VOLUME:/src:ro" -v "$HERE/container:/scripts:ro" -v "$OUT:/out" -v "$WORK:/work" \
            "$X86_IMAGE" bash /scripts/build-x86.sh > "$WORK/build-x86.log" 2>&1 \
            || { tail -40 "$WORK/build-x86.log"; exit 1; }
        ;;
    verify)
        log "manifest + verify against $ROOTFS_IMG (log: $WORK/verify.log)"
        [ -f "$ROOTFS_IMG" ] || { echo "missing stock rootfs image: $ROOTFS_IMG" >&2; exit 1; }
        docker run --rm --platform linux/arm64 --privileged \
            -e MESA_URL -e MESA_COMMIT -e VENUS_PROTOCOL_COMMIT -e AARCH64_IMAGE -e X86_IMAGE \
            -e STEAMOS_X86_MIRROR -e STEAMOS_X86_BRANCH -e FEX_PROVIDER \
            -v "$ROOTFS_IMG:/rootfs.img:ro" -v "$HERE/container:/scripts:ro" -v "$OUT:/out" -v "$WORK:/work" \
            "$TOOLS_IMAGE" sh -c 'sh /scripts/manifest.sh && sh /scripts/verify.sh' 2>&1 | tee "$WORK/verify.log"
        ;;
    esac
done
log "done: $OUT"
