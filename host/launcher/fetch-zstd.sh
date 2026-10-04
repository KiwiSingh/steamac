#!/usr/bin/env bash
# Fetch the pinned zstd release and unpack its decompression sources into Sources/CZstd/zstd
# (gitignored), compiled into the launcher by the CZstd target (Sources/CZstd/czstd.c, the
# single-file decoder recipe of zstd's build/single_file_libs/zstddeclib-in.c). The launcher's
# own squashfs reader needs it for the zstd-compressed RAUC bundle (Docker-free disk creation).
# Idempotent: re-downloads only if the unpacked version stamp does not match.
set -euo pipefail

VERSION=1.5.7
SHA256=eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3   # zstd-1.5.7.tar.gz
URL="https://github.com/facebook/zstd/releases/download/v${VERSION}/zstd-${VERSION}.tar.gz"

HERE=$(cd "$(dirname "$0")" && pwd)
DEST="$HERE/Sources/CZstd/zstd"
STAMP="$DEST/VERSION"

if [[ "$(cat "$STAMP" 2>/dev/null)" == "$VERSION $SHA256" ]]; then
    echo "zstd $VERSION already at $DEST"
    exit 0
fi

tmp="$HERE/Sources/CZstd/.zstd.$$"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp"
curl -fsSL --retry 3 -o "$tmp/zstd.tar.gz" "$URL"
got=$(shasum -a 256 "$tmp/zstd.tar.gz" | awk '{print $1}')
if [[ "$got" != "$SHA256" ]]; then
    echo "zstd checksum mismatch: got $got want $SHA256" >&2
    exit 1
fi
tar -xzf "$tmp/zstd.tar.gz" -C "$tmp" \
    "zstd-$VERSION/LICENSE" "zstd-$VERSION/lib/zstd.h" "zstd-$VERSION/lib/zstd_errors.h" \
    "zstd-$VERSION/lib/common" "zstd-$VERSION/lib/decompress"
mkdir -p "$tmp/out"
mv "$tmp/zstd-$VERSION/lib/common" "$tmp/zstd-$VERSION/lib/decompress" \
    "$tmp/zstd-$VERSION/lib/zstd.h" "$tmp/zstd-$VERSION/lib/zstd_errors.h" "$tmp/zstd-$VERSION/LICENSE" "$tmp/out/"
echo "$VERSION $SHA256" > "$tmp/out/VERSION"
rm -rf "$DEST"
mv "$tmp/out" "$DEST"
echo "zstd $VERSION -> $DEST"
