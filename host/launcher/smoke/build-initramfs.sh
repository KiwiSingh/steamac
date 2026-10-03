#!/usr/bin/env bash
# Build the launcher smoke-test initramfs (static busybox + smoke/init) in an arm64 Alpine
# container -> work/out/smoke/initramfs.cpio.gz. Idempotent.
set -euo pipefail

ALPINE="alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc"
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
OUT="$ROOT/work/out/smoke"
mkdir -p "$OUT"

docker run --rm --platform linux/arm64 -v "$HERE:/src:ro" -v "$OUT:/out" "$ALPINE" sh -euc '
    apk add --no-cache busybox-static cpio >/dev/null
    rm -rf /r && mkdir -p /r/bin /r/dev /r/proc /r/sys /r/tmp /r/run /r/etc
    cp /bin/busybox.static /r/bin/busybox
    cp /src/init /r/init && chmod 755 /r/init
    mknod -m 600 /r/dev/console c 5 1
    mknod -m 666 /r/dev/null c 1 3
    cd /r && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet | gzip -9n > /out/initramfs.cpio.gz.tmp
    mv /out/initramfs.cpio.gz.tmp /out/initramfs.cpio.gz
    /r/bin/busybox | head -1
'
ls -l "$OUT/initramfs.cpio.gz"
