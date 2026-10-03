#!/bin/bash
# Step 20 (builder container): work/out/initramfs.cpio.gz
#   /init      = guest/initramfs/init
#   /bin/*     = static busybox (Debian busybox-static, pinned via the snapshot
#                in config.env) + one symlink per applet
#   /dev/console node so the kernel can hand PID 1 a console before devtmpfs.
# The kernel has every driver built in (GuestKernel), so no modules.
# Reproducible: fixed mtimes, sorted entries, root ownership.
set -euo pipefail
. /src/scripts/config.env

OUT=/work/out/initramfs.cpio.gz
ST=$(mktemp -d)
trap 'rm -rf "$ST"' EXIT

mkdir -p "$ST"/{bin,dev,proc,sys,run,tmp,esp,efi,newroot}
install -m 0755 /bin/busybox "$ST/bin/busybox"
file "$ST/bin/busybox" | grep -q 'statically linked' || { echo "busybox is not static" >&2; exit 1; }
for a in $("$ST/bin/busybox" --list); do
    [[ $a == busybox ]] || ln -s busybox "$ST/bin/$a"
done
ln -s bin "$ST/sbin"
install -m 0755 /src/guest/initramfs/init "$ST/init"
mknod -m 0600 "$ST/dev/console" c 5 1
mknod -m 0666 "$ST/dev/null" c 1 3

# sanity: every applet /init relies on is present
for a in sh mount umount switch_root setsid cttyhack sed grep tr od dd mkdir mv \
         rm ln cat sleep sync chroot poweroff; do
    [[ -e $ST/bin/$a ]] || { echo "busybox lacks applet $a" >&2; exit 1; }
done
"$ST/bin/sh" -n "$ST/init"

epoch=${SOURCE_DATE_EPOCH:-1767225600}   # 2026-01-01
find "$ST" -exec touch -h -d "@$epoch" {} +
(cd "$ST" && find . -mindepth 1 | LC_ALL=C sort | cpio --quiet -o -H newc -R 0:0 --reproducible) \
    | gzip -9 -n > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "[initramfs] $OUT: $(stat -c %s "$OUT") bytes, $("$ST/bin/busybox" | head -1)"
