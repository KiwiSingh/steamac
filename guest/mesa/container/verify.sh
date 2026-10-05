#!/bin/sh
# Runs privileged in TOOLS_IMAGE (arm64). Verifies /out against the stock SteamOS rootfs
# (/rootfs.img, mounted read-only, with a tmpfs overlay that receives /out/usr):
#   1. ELF machine/class of every library, ICD json library_path/library_arch
#   2. static resolution: every NEEDED soname exists in the target root and every required
#      symbol version (GLIBC_*, ...) is defined by the library that provides it
#   3. runtime: ldd -r and vkprobe (dlopen + ICD entry points + loader instance) inside chroots
#      of the stock rootfs (aarch64) and of the fex-mesa provider (x86_64 via Rosetta, i386 via qemu)
set -eu
: "${FEX_PROVIDER:?}"
apk add --no-cache -q binutils coreutils grep >/dev/null

fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

mkdir -p /lower /ovl /merged
# Explicit loop device (the container's /dev may lack the node loop-control hands out).
lo=$(losetup -f)
[ -b "$lo" ] || mknod "$lo" b 7 "${lo#/dev/loop}"
losetup -r "$lo" /rootfs.img
cleanup() {
    for m in $(awk '$2 ~ "^/(merged|ovl|lower)" {print $2}' /proc/mounts | sort -r); do umount "$m" 2>/dev/null || true; done
    losetup -d "$lo" 2>/dev/null || true
}
trap cleanup EXIT
mount -t btrfs -o ro "$lo" /lower
mount -t tmpfs tmpfs /ovl
mkdir -p /ovl/upper /ovl/work
mount -t overlay overlay -o lowerdir=/lower,upperdir=/ovl/upper,workdir=/ovl/work /merged
cp -a /out/usr/. /merged/usr/
PROV=/merged$FEX_PROVIDER

echo "stock rootfs: $(grep -E '^(BUILD_ID|VERSION_ID)=' /lower/etc/os-release | tr '\n' ' ')"

# resolve <root> <abs path>: follow symlinks inside <root>, print the final in-root path.
resolve() {
    r=$1 p=$2 n=0
    while [ -L "$r$p" ] && [ $n -lt 40 ]; do
        t=$(readlink "$r$p")
        case $t in /*) p=$t ;; *) p=$(dirname "$p")/$t ;; esac
        n=$((n + 1))
    done
    [ -e "$r$p" ] && echo "$p"
}

# check_elf <file> <machine> <class>
check_elf() {
    m=$(readelf -h "$1" | sed -n 's/^ *Machine: *//p')
    c=$(readelf -h "$1" | sed -n 's/^ *Class: *//p')
    if [ "$m" = "$2" ] && [ "$c" = "$3" ]; then pass "elf ${1#/merged}: $m $c"
    else fail "elf ${1#/merged}: got '$m' '$c', want '$2' '$3'"; fi
}

# check_json <root> <json> <library_path> <library_arch>
check_json() {
    lp=$(sed -n 's/.*"library_path": *"\([^"]*\)".*/\1/p' "$1$2")
    la=$(sed -n 's/.*"library_arch": *"\([^"]*\)".*/\1/p' "$1$2")
    if [ "$lp" = "$3" ] && [ "$la" = "$4" ] && [ -f "$1$lp" ]; then
        pass "json $2 (root ${1#/merged}): library_path $lp, library_arch $la"
    else
        fail "json $2 (root ${1#/merged}): library_path '$lp' library_arch '$la', want '$3' '$4' present"
    fi
}

# check_deps <root> <lib (in-root path)> <libdir...>
check_deps() {
    r=$1 f=$2
    shift 2
    for so in $(readelf -d "$r$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
        found=
        for d in "$@"; do
            found=$(resolve "$r" "$d/$so") && break
        done
        if [ -z "$found" ]; then
            fail "deps $f (root ${r#/merged}): $so not found in $*"
            continue
        fi
        defs=$(readelf -V -W "$r$found" | awk '/Version definition section/{s=1;next} /Version needs section/{s=0} s' \
            | grep -oE 'Name: [^ ]+' | cut -d' ' -f2 | sort -u)
        missing=
        for v in $(readelf -V -W "$r$f" | awk '
                /Version needs section/ {s=1; next}
                /Version (definition|symbols) section/ {s=0}
                s && /File:/ {for (i = 1; i <= NF; i++) if ($i == "File:") file = $(i + 1)}
                s && /Name:/ {for (i = 1; i <= NF; i++) if ($i == "Name:") print file "@" $(i + 1)}' \
                | grep "^$so@" | cut -d@ -f2); do
            printf '%s\n' "$defs" | grep -qxF "$v" || missing="$missing $v"
        done
        if [ -n "$missing" ]; then fail "deps $f: $so ($found) lacks versions:$missing"
        else pass "deps $f: $so -> $found"; fi
    done
}

# in_chroot <root> <cmd...>
in_chroot() {
    r=$1
    shift
    mkdir -p "$r/dev" "$r/proc" "$r/tmp"
    mountpoint -q "$r/dev" || mount --bind /dev "$r/dev"
    mountpoint -q "$r/proc" || mount -t proc proc "$r/proc"
    chroot "$r" /usr/bin/env -i PATH=/usr/bin:/bin HOME=/tmp "$@"
}

# check_runtime <root> <lib> <vkprobe binary>
check_runtime() {
    r=$1 f=$2 probe=$3
    out=$(in_chroot "$r" /usr/bin/ldd -r "$f" 2>&1) || true
    echo "$out" | sed 's/^/    /'
    if echo "$out" | grep -qE 'not found|undefined symbol|not a dynamic'; then
        fail "ldd -r $f (root ${r#/merged})"
    else
        pass "ldd -r $f (root ${r#/merged})"
    fi
    cp "/work/bin/$probe" "$r/tmp/$probe"
    out=$(in_chroot "$r" VK_LOADER_DEBUG=driver "/tmp/$probe" "$f" 2>&1) && rc=0 || rc=$?
    echo "$out" | grep -iE 'virtio|^OK|^FAIL|^loader:' | sed 's/^/    /'
    if [ $rc -eq 0 ] && echo "$out" | grep -q '^OK dlopen'; then
        pass "vkprobe $f (root ${r#/merged})"
    else
        fail "vkprobe $f (root ${r#/merged}) rc=$rc"
        echo "$out" | tail -20 | sed 's/^/    /'
    fi
}

echo "== aarch64 (stock rootfs)"
check_elf /merged/usr/bin/steamac-dx12-check AArch64 ELF64
check_deps /merged /usr/bin/steamac-dx12-check /usr/lib
check_elf /merged/usr/lib/libvulkan_virtio.so AArch64 ELF64
check_json /merged /usr/share/vulkan/icd.d/virtio_icd.aarch64.json /usr/lib/libvulkan_virtio.so 64
check_deps /merged /usr/lib/libvulkan_virtio.so /usr/lib
check_runtime /merged /usr/lib/libvulkan_virtio.so vkprobe-aarch64

echo "== x86_64 (fex-mesa provider $FEX_PROVIDER)"
check_elf "$PROV/usr/lib/libvulkan_virtio.so" "Advanced Micro Devices X86-64" ELF64
check_json "$PROV" /usr/share/vulkan/icd.d/virtio_icd.x86_64.json /usr/lib/libvulkan_virtio.so 64
check_deps "$PROV" /usr/lib/libvulkan_virtio.so /usr/lib
check_runtime "$PROV" /usr/lib/libvulkan_virtio.so vkprobe-x86_64

echo "== i386 (fex-mesa provider $FEX_PROVIDER)"
check_elf "$PROV/usr/lib32/libvulkan_virtio.so" "Intel 80386" ELF32
check_json "$PROV" /usr/share/vulkan/icd.d/virtio_icd.x86.json /usr/lib32/libvulkan_virtio.so 32
check_deps "$PROV" /usr/lib32/libvulkan_virtio.so /usr/lib32
check_runtime "$PROV" /usr/lib32/libvulkan_virtio.so vkprobe-i386

echo
if [ "$fails" -eq 0 ]; then echo "VERIFY OK"; else echo "VERIFY FAILED: $fails check(s)"; exit 1; fi
