#!/usr/bin/env bash
# Repack the current guest layer with this checkout's startup files, then
# produce an ad-hoc signed, non-notarized app ZIP. Requires Docker and macOS.
# Kernel, initramfs, Venus and progress agent are preserved from work/out.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
DOCKER=${DOCKER:-docker}
TAG=${1:?usage: package-fork-release.sh <release-tag>}
[[ $TAG =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid release tag" >&2; exit 2; }
SRC="$ROOT/work/out/FX Steam Launcher.app"
WORK="$ROOT/work/release"
mkdir -p "$WORK"
"$DOCKER" run --rm -v "$ROOT":/src:ro -v "$ROOT/work":/work alpine:latest sh -c '
  apk add --no-cache erofs-utils bash coreutils findutils >/dev/null
  rm -rf /work/release/layer
  mkdir -p /work/release/layer
  fsck.erofs --extract=/work/release/layer /work/out/steamac-layer.img
  cp -a /src/guest/layer/usr/. /work/release/layer/usr/
  bash -n /work/release/layer/usr/share/deckard/RUNSTEAM.sh
  find /work/release/layer -type d -exec chmod 0755 {} +
  find /work/release/layer -type f -perm -u+x -exec chmod 0755 {} +
  find /work/release/layer -type f ! -perm -u+x -exec chmod 0644 {} +
  tree_hash=$(cd /work/release/layer && find usr -type f ! -path "usr/lib/steamac/layer-release" -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)
  printf "steamac-fork-layer content=%s base=work/out/steamac-layer.img\n" "$tree_hash" > /work/release/layer/usr/lib/steamac/layer-release
  rm -f /work/release/steamac-layer.img.new
  mkfs.erofs -zlz4hc -T 1767225600 -U 5fea1f2a-0c6b-4d5e-9a1e-0000000000a1 --all-root -L steamac-layer /work/release/steamac-layer.img.new /work/release/layer >/dev/null
  fsck.erofs /work/release/steamac-layer.img.new
  mv /work/release/steamac-layer.img.new /work/release/steamac-layer.img
'
STAGE="$WORK/package-$TAG"
[[ ! -e "$STAGE" ]] || { echo "Package stage already exists: $STAGE" >&2; exit 1; }
mkdir -p "$STAGE"
APP="$STAGE/FX Steam Launcher.app"
ditto "$SRC" "$APP"
/usr/libexec/PlistBuddy -c 'Delete :SteamacBuildOut' "$APP/Contents/Info.plist" 2>/dev/null || true
cp "$WORK/steamac-layer.img" "$APP/Contents/Resources/steamac-layer.img"
cp README.md "$STAGE/README.md"
mkdir -p "$STAGE/docs"
cp docs/fork-setup.md "$STAGE/docs/fork-setup.md"
# Fork builds are not represented as Developer-ID signed or notarized.
codesign --force --sign - --timestamp=none --entitlements host/launcher/steamac-vm.entitlements "$APP"
codesign --verify --deep --strict "$APP"
ZIP="$WORK/Steamac-$TAG-arm64.zip"
ditto -c -k --keepParent "$STAGE" "$ZIP"
(cd "$WORK" && shasum -a 256 "$(basename "$ZIP")" > "Steamac-$TAG-SHA256SUMS.txt")
printf 'Built %s\n' "$ZIP"
