#!/bin/sh
# Build libepoxy 1.5.10 for the macOS 15 launcher, not the build host's Homebrew bottle.
#
#   host/libepoxy/build.sh        build/refresh work/out/host/{lib,include}/epoxy...
#   host/libepoxy/build.sh clean  drop the source/build tree (next build is from scratch)
#
# Source and Meson options match Homebrew's libepoxy formula (macOS: upstream defaults,
# release, no fallback subprojects). Installed dylib: @rpath/libepoxy.0.dylib, ad-hoc signed.
# Meson installs into a staging DESTDIR; files are renamed into place (new inode) so a
# running VM's mapped library is never rewritten.
set -eu

VERSION=1.5.10
URL=https://download.gnome.org/sources/libepoxy/1.5/libepoxy-1.5.10.tar.xz
SHA256=072cda4b59dd098bba8c2363a6247299db1fa89411dc221c8b81b8ee8192e623
BREW_DEPS="meson ninja pkgconf"
export MACOSX_DEPLOYMENT_TARGET=15.0

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$root/work/build/host-libepoxy
src=$work/src
build=$work/build
stage=$work/stage
out=$root/work/out/host
archive=$work/libepoxy-$VERSION.tar.xz

# Like Homebrew's isolated formula environment, exclude unrelated host packages (e.g. XQuartz).
export PKG_CONFIG_PATH="$out/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$out/lib/pkgconfig"
if [ "${1:-}" = clean ]; then
	rm -rf "$work"
	exit 0
fi

for dep in $BREW_DEPS; do
	brew list --versions "$dep" > /dev/null 2>&1 || brew install "$dep"
done
mkdir -p "$work" "$out"
if [ ! -f "$archive" ]; then
	curl -fL --retry 3 -o "$archive.tmp" "$URL"
	mv -f "$archive.tmp" "$archive"
fi
echo "$SHA256  $archive" | shasum -a 256 -c -
rm -rf "$src" "$build" "$stage"
mkdir -p "$src"
tar -xf "$archive" -C "$src" --strip-components=1

meson setup "$build" "$src" --prefix="$out" --libdir=lib \
	--buildtype=release --wrap-mode=nofallback
ninja -C "$build"
meson test -C "$build" --print-errorlogs
DESTDIR="$stage" ninja -C "$build" install
staged=$stage$out
lib=$staged/lib/libepoxy.0.dylib
install_name_tool -id @rpath/libepoxy.0.dylib "$lib"
codesign --force -s - "$lib"

(cd "$staged" && find . ! -type d) | while read -r f; do
	f=${f#./}
	mkdir -p "$(dirname "$out/$f")"
	mv -f "$staged/$f" "$out/$f"
done
rm -rf "$stage"
echo ">> $out/lib/libepoxy.0.dylib"
otool -L "$out/lib/libepoxy.0.dylib"
