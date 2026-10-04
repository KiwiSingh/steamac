#!/usr/bin/env bash
# Build the steamac-vm launcher (release), sign it with the hypervisor entitlement and
# install it as work/out/steamac-vm. Also fetches the pinned zstd decoder sources (compiled in),
# gvproxy and desync into work/out/host/bin and assembles work/out/FX Steam Launcher.app
# (bundle.sh; skipped with STEAMAC_NO_BUNDLE=1 or when the kernel/initramfs/layer images are
# not built yet).
#
# libkrun (v1.19.6 C API, built with GPU=1 INPUT=1 BLK=1 NET=1) is taken from
# $KRUN_PREFIX (default: work/out/host, produced by host/libkrun). The binary's rpath is
# @executable_path/host/lib (= work/out/host/lib) first, then $KRUN_PREFIX/lib.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT="$ROOT/work/out"
KRUN_PREFIX="${KRUN_PREFIX:-$OUT/host}"

for h in libkrun.h libkrun_display.h libkrun_input.h; do
    [[ -f "$KRUN_PREFIX/include/$h" ]] || { echo "missing $KRUN_PREFIX/include/$h (build host/libkrun first or set KRUN_PREFIX)" >&2; exit 1; }
done
ls "$KRUN_PREFIX"/lib/libkrun*.dylib >/dev/null 2>&1 || { echo "missing $KRUN_PREFIX/lib/libkrun*.dylib" >&2; exit 1; }

SWIFT_FLAGS=(
    -c release
    --package-path "$HERE"
    --scratch-path "$HERE/.build"
    -Xcc "-I$KRUN_PREFIX/include"
    -Xlinker "-L$KRUN_PREFIX/lib"
    -Xlinker -rpath -Xlinker @executable_path/host/lib
    -Xlinker -rpath -Xlinker "$KRUN_PREFIX/lib"
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$HERE/Info.plist"
)

"$HERE/fetch-zstd.sh"
swift build "${SWIFT_FLAGS[@]}"
BIN="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)/steamac-vm"

mkdir -p "$OUT"
tmp="$OUT/.steamac-vm.$$"
cp -f "$BIN" "$tmp"

# Make the libkrun reference rpath-relative even if the dylib's install name is absolute.
ref=$(otool -L "$tmp" | awk '/libkrun[.0-9]*\.dylib/ {print $1; exit}')
[[ -n "$ref" ]] || { echo "steamac-vm does not link libkrun?" >&2; exit 1; }
if [[ "$ref" != @rpath/* ]]; then
    install_name_tool -change "$ref" "@rpath/$(basename "$ref")" "$tmp"
fi

codesign --force --sign - --entitlements "$HERE/steamac-vm.entitlements" "$tmp"
mv -f "$tmp" "$OUT/steamac-vm"

"$HERE/fetch-gvproxy.sh"
"$HERE/fetch-desync.sh"

echo "built $OUT/steamac-vm"
otool -L "$OUT/steamac-vm" | awk '/libkrun/'
codesign -d --entitlements - "$OUT/steamac-vm" 2>&1 | grep -E 'hypervisor|library-validation' || true

if [[ "${STEAMAC_NO_BUNDLE:-}" == 1 ]]; then
    echo "STEAMAC_NO_BUNDLE=1: app bundle skipped"
elif [[ -f "$OUT/Image" && -f "$OUT/initramfs.cpio.gz" && -f "$OUT/steamac-layer.img" ]]; then
    KRUN_PREFIX="$KRUN_PREFIX" "$HERE/bundle.sh" "$OUT/steamac-vm"
else
    echo "app bundle skipped: build Image, initramfs.cpio.gz and steamac-layer.img first" >&2
fi
