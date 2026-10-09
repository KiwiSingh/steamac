#!/bin/sh
# Build libkrun v1.19.6 + steamac patches for the macOS launcher.
#
#   host/libkrun/build.sh        build/refresh work/out/host/{lib,include}
#   host/libkrun/build.sh clean  drop the source/build tree (next build is from scratch)
#
# Inputs (all pinned):
#   libkrun        tag v1.19.6 (227b2de6), github.com/libkrun/libkrun
#   patches/       applied in order (git format-patch series, see each header)
#   virglrenderer  host/virglrenderer/build.sh output in work/out/host (built first if
#                  missing); Venus over the steamac MoltenVK (host/moltenvk)
#   Rust           $RUST_TOOLCHAIN via rustup (deps need >= 1.87)
#   libepoxy       host/libepoxy/build.sh output (built first if missing)
#   Homebrew       dtc, xz, lld (init cross-link), pkgconf
#
# Features: make GPU=1 BLK=1 NET=1 INPUT=1 SND=1. v1.19.6 has no TIMESYNC make flag (the
# vsock timesync is always built). SND on macOS uses the CoreAudio virtio-snd backend from
# patch 0014 (no PipeWire); its debug knob STEAMAC_SND_DUMP=/path.wav records the playback
# stream as handed to CoreAudio.
#
# Output (work/out/host):
#   lib/libkrun.1.dylib      install_name @rpath/libkrun.1.dylib, ad-hoc signed
#   lib/libkrun.dylib        -> libkrun.1.dylib
#   lib/pkgconfig/libkrun.pc
#   include/libkrun.h, include/libkrun_display.h, include/libkrun_input.h
# Binaries using it need an rpath to work/out/host/lib (it also loads
# @rpath/libvirglrenderer.1.dylib and @rpath/libMoltenVK.dylib from there) and the
# com.apple.security.hypervisor entitlement. The virtio-gpu unit tests run after the build,
# the smoke test in test/ is built, signed and run at the end. test/resize-test.sh is a
# separate live check of krun_display_resize on a clone of the guest disk.
# Installed files are written next to their destination and renamed over it (new inode),
# never rewritten in place: a running VM may have the dylib mapped.
set -eu

REPO=https://github.com/libkrun/libkrun.git
TAG=v1.19.6
COMMIT=227b2de6ed323fe180e02f871c5f325a90c13cc2
RUST_TOOLCHAIN=${RUST_TOOLCHAIN:-1.90.0}
BREW_DEPS="dtc xz lld pkgconf"
export MACOSX_DEPLOYMENT_TARGET=15.0 # rustc and cc build scripts inherit this target
MAKE_FLAGS="GPU=1 BLK=1 NET=1 INPUT=1 SND=1"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$root/work/build/host-libkrun
src=$work/src
out=$root/work/out/host

if [ "${1:-}" = clean ]; then
	rm -rf "$work"
	exit 0
fi

for dep in $BREW_DEPS; do
	brew list --versions "$dep" > /dev/null 2>&1 || brew install "$dep"
done
rustup toolchain list | grep -q "^$RUST_TOOLCHAIN-" ||
	rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal

if [ ! -f "$out/lib/libepoxy.0.dylib" ] || [ ! -f "$out/lib/pkgconfig/epoxy.pc" ]; then
	"$root/host/libepoxy/build.sh"
fi

if [ ! -f "$out/lib/pkgconfig/virglrenderer.pc" ]; then
	"$root/host/virglrenderer/build.sh"
fi

mkdir -p "$work" "$out/lib/pkgconfig" "$out/include"

# --- source at the pinned tag + patches (target/ and the auto-fetched Debian sysroot
#     for the init binary survive re-runs)
if [ ! -d "$src/.git" ]; then
	git init -q "$src"
	git -C "$src" remote add origin "$REPO"
fi
if ! git -C "$src" cat-file -e "$COMMIT^{commit}" 2> /dev/null; then
	git -C "$src" fetch -q --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG"
fi
test "$(git -C "$src" rev-parse "$TAG^{commit}")" = "$COMMIT"
git -C "$src" checkout -q -f --detach "$COMMIT"
git -C "$src" clean -q -fdx -e /target -e /linux-sysroot
for p in "$here"/patches/*.patch; do
	echo ">> applying $(basename "$p")"
	git -C "$src" apply "$p"
done

# libkrun's init_blob build script splits CC_LINUX on ASCII whitespace.
# The macOS cross-compiler command contains absolute sysroot paths, so a
# Steamac checkout whose path contains spaces gets split into bogus clang
# arguments. Give the Linux sysroot a temporary no-space alias and rewrite
# the Darwin CC_LINUX command to use that alias.
sysroot_link="/tmp/steamac-libkrun-sysroot-$$"
rm -f "$sysroot_link"
ln -s "$src/linux-sysroot" "$sysroot_link"
trap 'rm -f "$sysroot_link"' EXIT INT TERM

python3 - "$src/Makefile" "$sysroot_link" <<'PYFIX'
from pathlib import Path
import sys

path = Path(sys.argv[1])
sysroot = sys.argv[2]
text = path.read_text()

old = (
    "    CC_LINUX=$(CLANG) -target $(GCC_TRIPLET) -fuse-ld=lld "
    "-Wl,-strip-debug --sysroot $(abspath $(SYSROOT_LINUX)) "
    "-B$(GCC_LIB_DIR) -L$(GCC_LIB_DIR) -Wno-c23-extensions\n"
)

new = (
    "    CC_LINUX=$(CLANG) -target $(GCC_TRIPLET) -fuse-ld=lld "
    f"-Wl,-strip-debug --sysroot {sysroot} "
    f"-B{sysroot}/usr/lib/gcc/$(GCC_TRIPLET)/$(GCC_VERSION) "
    f"-L{sysroot}/usr/lib/gcc/$(GCC_TRIPLET)/$(GCC_VERSION) "
    "-Wno-c23-extensions\n"
)

if old not in text:
    raise SystemExit(
        "Refusing libkrun whitespace fix: expected Darwin CC_LINUX line not found"
    )

path.write_text(text.replace(old, new, 1))
print(">> libkrun: using no-space Linux sysroot alias")
PYFIX

# --- build
(
	cd "$src"
	export RUSTUP_TOOLCHAIN="$RUST_TOOLCHAIN"
	export PKG_CONFIG_PATH="$out/lib/pkgconfig"
	# Do not fall back to Homebrew bottles; Cargo also tracks this pkg-config environment.
	export PKG_CONFIG_LIBDIR="$out/lib/pkgconfig"
	# No rustc strip: its llvm-objcopy debuginfo strip leaves LC_SYMTAB.stroff 4-byte aligned,
	# which ld and dyld reject for images built against the macOS 27 SDK ("mis-aligned LINKEDIT
	# string pool"; rust-lang/rust#157750, fixed in LLVM by llvm/llvm-project#203680).
	export CARGO_PROFILE_RELEASE_STRIP=false
	# shellcheck disable=SC2086
	make $MAKE_FLAGS
	make PREFIX="$out" libkrun.pc
	# Unit tests of the patched virtio-gpu code (EDID/display resize, blob scanouts).
	# RUSTFLAGS is whitespace-tokenized by Cargo/rustc, so use a no-space
	# alias when the Steamac checkout path itself contains whitespace.
	test_lib_link="/tmp/steamac-libkrun-test-lib-$$"
	rm -f "$test_lib_link"
	ln -s "$out/lib" "$test_lib_link"
	cd src/devices
	RUSTFLAGS="-L native=$test_lib_link -C link-args=-Wl,-rpath,$test_lib_link" \
		cargo test -q --features gpu --lib -- virtio::gpu
	rm -f "$test_lib_link"
)

# --- install (temp file + rename for every output)
lib=$out/lib/libkrun.1.dylib
cp "$src/target/release/libkrun.1.19.6.dylib" "$lib.tmp"
install_name_tool -id @rpath/libkrun.1.dylib "$lib.tmp"
codesign --force -s - "$lib.tmp"
mv -f "$lib.tmp" "$lib"
ln -sfh libkrun.1.dylib "$out/lib/libkrun.dylib.tmp"
mv -f "$out/lib/libkrun.dylib.tmp" "$out/lib/libkrun.dylib"
cp "$src/libkrun.pc" "$out/lib/pkgconfig/libkrun.pc.tmp"
mv -f "$out/lib/pkgconfig/libkrun.pc.tmp" "$out/lib/pkgconfig/libkrun.pc"
for h in libkrun.h libkrun_display.h libkrun_input.h; do
	cp "$src/include/$h" "$out/include/$h.tmp"
	mv -f "$out/include/$h.tmp" "$out/include/$h"
done

echo ">> $lib"
otool -L "$lib"

"$here/test/run.sh"
