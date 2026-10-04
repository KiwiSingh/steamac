#!/bin/bash
# Step 20 (builder container): work/out/initramfs.cpio.gz
#   /init      = guest/initramfs/init
#   /bin/*     = static busybox (Debian busybox-static, pinned via the snapshot
#                in config.env) + one symlink per applet
#   /dev/console node so the kernel can hand PID 1 a console before devtmpfs.
#   /bin/fsck.fat = dosfstools (pinned tarball, sha256-checked), built static
#                here: /init checks/repairs esp and efi-X before mounting them
#                (busybox has no FAT fsck).
#   /bin/mkfs.fat, /bin/mke2fs, /bin/btrfstune + /etc/mke2fs.conf: first-boot
#                provisioning of a disk the launcher created without Docker
#                (steamac.provision=1, see /init): dosfstools, e2fsprogs and
#                btrfs-progs pinned in config.env, built static here; the
#                mke2fs.conf is the builder's (Debian) one, so mke2fs creates
#                the same ext4 features as 40-disk.sh's mkfs.ext4.
# The kernel has every driver built in (GuestKernel), so no modules.
# Reproducible: fixed mtimes, sorted entries, root ownership.
set -euo pipefail
. /src/scripts/config.env

OUT=/work/out/initramfs.cpio.gz
ST=$(mktemp -d)
trap 'rm -rf "$ST"' EXIT

fetch() { # fetch <url> <sha256> <file>
    if [[ ! -f $3 ]]; then
        curl -fL --retry 5 -o "$3.part" "$1"
        mv "$3.part" "$3"
    fi
    echo "$2  $3" | sha256sum -c - >/dev/null || { echo "sha256 mismatch: $3" >&2; exit 1; }
}
is_static() { file "$1" | grep -q 'statically linked' || { echo "$1 is not static" >&2; exit 1; }; }

# --- static fsck.fat + mkfs.fat (cached per version in /work/cache/dosfstools)
DOSFS=/work/cache/dosfstools/$DOSFSTOOLS_VERSION
if [[ ! -x $DOSFS/fsck.fat || ! -x $DOSFS/mkfs.fat ]]; then
    mkdir -p "$DOSFS"
    tarball=$DOSFS/dosfstools-$DOSFSTOOLS_VERSION.tar.gz
    fetch "$DOSFSTOOLS_URL" "$DOSFSTOOLS_SHA256" "$tarball"
    B=$(mktemp -d)
    tar -xzf "$tarball" -C "$B"
    (cd "$B/dosfstools-$DOSFSTOOLS_VERSION" \
        && ./configure --without-udev --disable-compat-symlinks LDFLAGS=-static >/dev/null \
        && make -j"$(nproc)" >/dev/null)
    install -m 0755 "$B/dosfstools-$DOSFSTOOLS_VERSION/src/fsck.fat" "$DOSFS/fsck.fat"
    install -m 0755 "$B/dosfstools-$DOSFSTOOLS_VERSION/src/mkfs.fat" "$DOSFS/mkfs.fat"
    rm -rf "$B"
fi

# --- static mke2fs (cached per version in /work/cache/e2fsprogs); private
# libuuid/libblkid, no NLS/libarchive (nothing dlopen()ed at runtime)
E2FS=/work/cache/e2fsprogs/$E2FSPROGS_VERSION
if [[ ! -x $E2FS/mke2fs ]]; then
    mkdir -p "$E2FS"
    tarball=$E2FS/e2fsprogs-$E2FSPROGS_VERSION.tar.xz
    fetch "$E2FSPROGS_URL" "$E2FSPROGS_SHA256" "$tarball"
    B=$(mktemp -d)
    tar -xJf "$tarball" -C "$B"
    (cd "$B/e2fsprogs-$E2FSPROGS_VERSION" \
        && ./configure --disable-nls --disable-fuse2fs --disable-e2initrd-helper --disable-uuidd \
            --disable-debugfs --disable-imager --disable-defrag --disable-tdb \
            --enable-libuuid --enable-libblkid --without-libarchive LDFLAGS=-static >/dev/null \
        && make -j"$(nproc)" libs >/dev/null \
        && make -j"$(nproc)" -C misc mke2fs >/dev/null)
    install -m 0755 "$B/e2fsprogs-$E2FSPROGS_VERSION/misc/mke2fs" "$E2FS/mke2fs"
    rm -rf "$B"
fi

# --- static btrfstune (cached per version in /work/cache/btrfs-progs)
BTRFS=/work/cache/btrfs-progs/$BTRFSPROGS_VERSION
if [[ ! -x $BTRFS/btrfstune ]]; then
    mkdir -p "$BTRFS"
    tarball=$BTRFS/btrfs-progs-v$BTRFSPROGS_VERSION.tar.xz
    fetch "$BTRFSPROGS_URL" "$BTRFSPROGS_SHA256" "$tarball"
    B=$(mktemp -d)
    tar -xJf "$tarball" -C "$B"
    (cd "$B/btrfs-progs-v$BTRFSPROGS_VERSION" \
        && ./configure --disable-documentation --disable-python --disable-convert --disable-libudev \
            --disable-zoned --disable-backtrace --disable-lzo --disable-zstd \
            --disable-shared --enable-static >/dev/null \
        && make -j"$(nproc)" btrfstune.static >/dev/null)
    install -m 0755 "$B/btrfs-progs-v$BTRFSPROGS_VERSION/btrfstune.static" "$BTRFS/btrfstune"
    rm -rf "$B"
fi
for t in "$DOSFS/fsck.fat" "$DOSFS/mkfs.fat" "$E2FS/mke2fs" "$BTRFS/btrfstune"; do is_static "$t"; done

mkdir -p "$ST"/{bin,dev,etc,proc,sys,run,tmp,esp,efi,newroot}
install -m 0755 /bin/busybox "$ST/bin/busybox"
file "$ST/bin/busybox" | grep -q 'statically linked' || { echo "busybox is not static" >&2; exit 1; }
for a in $("$ST/bin/busybox" --list); do
    [[ $a == busybox ]] || ln -s busybox "$ST/bin/$a"
done
ln -s bin "$ST/sbin"
install -m 0755 /src/guest/initramfs/init "$ST/init"
mknod -m 0600 "$ST/dev/console" c 5 1
mknod -m 0666 "$ST/dev/null" c 1 3
# real tools replace busybox applets of the same name (busybox has a mke2fs)
for t in "$DOSFS/fsck.fat" "$DOSFS/mkfs.fat" "$E2FS/mke2fs" "$BTRFS/btrfstune"; do
    rm -f "$ST/bin/${t##*/}"
    install -m 0755 "$t" "$ST/bin/${t##*/}"
    strip "$ST/bin/${t##*/}"
done
install -m 0644 /etc/mke2fs.conf "$ST/etc/mke2fs.conf"

# sanity: every applet /init relies on is present
for a in sh mount umount switch_root setsid cttyhack sed grep tr od dd mkdir mv \
         rm ln cat sleep sync chroot poweroff cpio awk cmp cp chmod install head wc readlink date; do
    [[ -e $ST/bin/$a ]] || { echo "busybox lacks applet $a" >&2; exit 1; }
done
"$ST/bin/sh" -n "$ST/init"

epoch=${SOURCE_DATE_EPOCH:-1767225600}   # 2026-01-01
find "$ST" -exec touch -h -d "@$epoch" {} +
(cd "$ST" && find . -mindepth 1 | LC_ALL=C sort | cpio --quiet -o -H newc -R 0:0 --reproducible) \
    | gzip -9 -n > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "[initramfs] $OUT: $(stat -c %s "$OUT") bytes, $("$ST/bin/busybox" | head -1)"
