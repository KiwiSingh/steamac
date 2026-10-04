#!/usr/bin/env bash
# Fetch the pinned official desync release (folbricht/desync, BSD-3-Clause; static Go binary,
# system frameworks only) into work/out/host/bin/desync, its licence into
# work/out/host/share/desync/LICENSE. The launcher runs it to rebuild the SteamOS rootfs from
# Valve's casync chunk store (Docker-free disk creation); bundle.sh ships both in the .app.
# Idempotent: re-downloads only if missing or the recorded archive checksum does not match.
set -euo pipefail

VERSION=1.1.4
SHA256=860f8ca3fc5b3be542a036e7ea894e0e423caef0c9698439580c28548c0739a5   # desync_1.1.4_darwin_arm64.tar.gz
URL="https://github.com/folbricht/desync/releases/download/v${VERSION}/desync_${VERSION}_darwin_arm64.tar.gz"

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
DEST="${DESYNC_DEST:-$ROOT/work/out/host/bin/desync}"
LICENSE="$ROOT/work/out/host/share/desync/LICENSE"
STAMP="$DEST.source"

if [[ -x "$DEST" && -f "$LICENSE" && "$(cat "$STAMP" 2>/dev/null)" == "$VERSION $SHA256" ]]; then
    echo "desync $VERSION already at $DEST"
    exit 0
fi

mkdir -p "$(dirname "$DEST")" "$(dirname "$LICENSE")"
tmp="$DEST.download.$$"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp"
curl -fsSL --retry 3 -o "$tmp/desync.tgz" "$URL"
got=$(shasum -a 256 "$tmp/desync.tgz" | awk '{print $1}')
if [[ "$got" != "$SHA256" ]]; then
    echo "desync checksum mismatch: got $got want $SHA256" >&2
    exit 1
fi
tar -xzf "$tmp/desync.tgz" -C "$tmp" desync LICENSE
chmod 755 "$tmp/desync"
xattr -d com.apple.quarantine "$tmp/desync" 2>/dev/null || true
"$tmp/desync" --version | grep -q "v$VERSION" || { echo "desync --version is not v$VERSION" >&2; exit 1; }
mv -f "$tmp/LICENSE" "$LICENSE"
mv -f "$tmp/desync" "$DEST"
echo "$VERSION $SHA256" > "$STAMP"
echo "desync $VERSION -> $DEST"
