#!/usr/bin/env bash
# Fetch a pinned gvproxy (containers/gvisor-tap-vsock) into work/out/host/bin/gvproxy.
# Idempotent: re-downloads only if missing or the checksum does not match.
set -euo pipefail

VERSION=v0.8.9
SHA256=c6f7b4bc7f21bf810b5cf54e04d979b014c5d96472a03a9e97fe62a00940067c   # gvproxy-darwin (universal)
URL="https://github.com/containers/gvisor-tap-vsock/releases/download/${VERSION}/gvproxy-darwin"

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
DEST="${GVPROXY_DEST:-$ROOT/work/out/host/bin/gvproxy}"

sum() { shasum -a 256 "$1" | awk '{print $1}'; }

if [[ -x "$DEST" && "$(sum "$DEST")" == "$SHA256" ]]; then
    echo "gvproxy $VERSION already at $DEST"
    exit 0
fi

mkdir -p "$(dirname "$DEST")"
tmp="$DEST.download.$$"
trap 'rm -f "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp" "$URL"
got=$(sum "$tmp")
if [[ "$got" != "$SHA256" ]]; then
    echo "gvproxy checksum mismatch: got $got want $SHA256" >&2
    exit 1
fi
chmod 755 "$tmp"
xattr -d com.apple.quarantine "$tmp" 2>/dev/null || true
mv -f "$tmp" "$DEST"
echo "gvproxy $VERSION -> $DEST"
