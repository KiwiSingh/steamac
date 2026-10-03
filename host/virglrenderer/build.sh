#!/bin/sh
# Build the host virglrenderer (Venus over MoltenVK) that libkrun links against.
#
#   host/virglrenderer/build.sh        build/refresh work/out/host/{lib,include}/virgl...
#   host/virglrenderer/build.sh clean  drop the source/build tree (next build is from scratch)
#
# Source: UTM's virglrenderer fork (github.com/utmapp/virglrenderer, branch macos-next) at its
# head 5d26f605 (UTM's own pin, utmapp/UTM scripts/sources VIRGLRENDERER_COMMIT), merged with
# upstream virglrenderer main at UPSTREAM_COMMIT (aafa9bd2, 2026-09-28: venus-protocol 1.1.3
# cf6c62da, the vkr object-id / blob-storage / pNext validation fixes, vrend-less builds).
# The fork sits on upstream 9ae1fb1c (2026-07-20) and is 48 upstream commits behind; the guest's
# Mesa 26.3 speaks venus-protocol 1.1.3. The merge is redone on every build with a fixed
# identity and its five conflicts are resolved by merge-resolve.py (see its header). The fork
# adds osy's macOS Venus work: VK_EXT_external_memory_dma_buf, VK_KHR_external_memory_fd,
# VK_EXT_image_drm_format_modifier (LINEAR only) and VK_KHR_external_fence_fd are emulated
# for the guest; every host-visible or exportable allocation (device-local included) is POSIX
# shm imported into the driver with VK_EXT_external_memory_host and handed to the VMM as a
# VIRGL_RESOURCE_FD_SHM fd. Importing into non-host-visible memory types needs MoltenVK
# PR #2834, which the steamac MoltenVK (host/moltenvk, utmapp/MoltenVK 05604465) carries.
#
# Vulkan: the steamac MoltenVK in work/out/host/lib, linked directly (no loader, no ICD lookup
# at runtime; built by host/moltenvk/build.sh if missing).
# Venus only runs behind virglrenderer's render server; it is built in "thread" mode
# (server + workers are threads inside the VMM process, no extra executable).
# Output install_name: @rpath/libvirglrenderer.1.dylib.
#
# Installation never rewrites a file in place (a running VM may have the dylib mapped): meson
# installs into a staging DESTDIR and every file is moved into work/out/host (new inode).
set -eu

REPO=https://github.com/utmapp/virglrenderer.git
COMMIT=5d26f605f50f8e22002ec6db5fb775e1992d4e96
UPSTREAM_REPO=https://gitlab.freedesktop.org/virgl/virglrenderer.git
UPSTREAM_COMMIT=aafa9bd234a43c31004ec768ce000b21cf7b99ca
PYYAML_VERSION=6.0.3
MAKO_VERSION=1.3.10
BREW_DEPS="libepoxy meson ninja pkgconf"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$root/work/build/host-virglrenderer
src=$work/src
build=$work/build
stage=$work/stage
out=$root/work/out/host
mvk_lib=$out/lib/libMoltenVK.dylib
mvk_vk_include=$root/work/build/host-moltenvk/src/Package/Release/MoltenVK/include

if [ "${1:-}" = clean ]; then
	rm -rf "$work"
	exit 0
fi

for dep in $BREW_DEPS; do
	brew list --versions "$dep" > /dev/null 2>&1 || brew install "$dep"
done
if [ ! -f "$mvk_lib" ] || [ ! -f "$mvk_vk_include/vulkan/vulkan_core.h" ]; then
	"$root/host/moltenvk/build.sh"
fi

mkdir -p "$work" "$out"

# --- source at the pinned commit + local patches
if [ ! -d "$src/.git" ]; then
	git init -q "$src"
	git -C "$src" remote add origin "$REPO"
fi
if ! git -C "$src" cat-file -e "$COMMIT^{commit}" 2> /dev/null; then
	git -C "$src" fetch -q origin "$COMMIT"
fi
if ! git -C "$src" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2> /dev/null; then
	git -C "$src" fetch -q "$UPSTREAM_REPO" "$UPSTREAM_COMMIT"
fi
git -C "$src" merge --abort 2> /dev/null || true
git -C "$src" checkout -q -f --detach "$COMMIT"
git -C "$src" clean -q -fdx
export GIT_AUTHOR_NAME=steamac GIT_AUTHOR_EMAIL=steamac@local GIT_COMMITTER_NAME=steamac \
	GIT_COMMITTER_EMAIL=steamac@local GIT_AUTHOR_DATE=2026-10-03T00:00:00Z \
	GIT_COMMITTER_DATE=2026-10-03T00:00:00Z
if ! git -C "$src" merge -q --no-ff --no-edit "$UPSTREAM_COMMIT" > /dev/null 2>&1; then
	(cd "$src" && python3 "$here/merge-resolve.py")
	git -C "$src" commit -q --no-edit
fi
if git -C "$src" grep -qE '^(<<<<<<<|>>>>>>>) ' -- '*.c' '*.h' '*.build'; then
	echo "unresolved merge conflict markers" >&2
	exit 1
fi
for p in "$here"/patches/*.patch; do
	[ -e "$p" ] || continue
	echo ">> applying $(basename "$p")"
	git -C "$src" apply --whitespace=nowarn "$p"
done

# --- build-time python (src/gallium needs PyYAML, venus-protocol 1.1.3 needs Mako)
if [ ! -x "$work/venv/bin/python3" ]; then
	python3 -m venv "$work/venv"
fi
"$work/venv/bin/pip" -q install "pyyaml==$PYYAML_VERSION" "mako==$MAKO_VERSION"

# --- the steamac MoltenVK as the `vulkan` dependency
mkdir -p "$work/pkgconfig"
cat > "$work/pkgconfig/vulkan.pc" << EOF
Name: vulkan
Description: steamac MoltenVK (host/moltenvk), linked directly as the Vulkan implementation
Version: 1.4.0
Libs: -L$out/lib -lMoltenVK
Cflags: -I$mvk_vk_include
EOF

rm -rf "$build" "$stage"
PATH="$work/venv/bin:$PATH" PKG_CONFIG_PATH="$work/pkgconfig" meson setup "$build" "$src" \
	--prefix="$out" --libdir=lib --buildtype=release \
	-Dvenus=true -Dvulkan-dload=false \
	-Drender-server-mode=thread -Drender-server-worker=thread \
	-Dneptune=false -Dvtest=false -Dtests=false -Dvideo=false \
	-Dcheck-gl-errors=false
ninja -C "$build"
DESTDIR="$stage" ninja -C "$build" install
staged=$stage$out

lib=$staged/lib/libvirglrenderer.1.dylib
install_name_tool -id @rpath/libvirglrenderer.1.dylib "$lib"
if otool -L "$lib" | grep -q /opt/homebrew/opt/molten-vk; then
	echo "libvirglrenderer links Homebrew MoltenVK" >&2
	exit 1
fi
codesign --force -s - "$lib"

# The installed .pc lists the private `vulkan` package, which only exists in the
# build-time pkgconfig dir above; consumers of the shared library get MoltenVK
# as a private link flag instead.
pc=$staged/lib/pkgconfig/virglrenderer.pc
sed -i '' \
	-e 's/^\(Requires.private:.*\), vulkan$/\1/' \
	-e "s|^Libs.private: |Libs.private: -L$out/lib -lMoltenVK |" \
	"$pc"
if grep -q 'vulkan' "$pc"; then
	echo "unexpected virglrenderer.pc layout:" >&2
	cat "$pc" >&2
	exit 1
fi

# --- move into place (rename = new inode; symlinks are recreated the same way)
(cd "$staged" && find . ! -type d) | while read -r f; do
	f=${f#./}
	mkdir -p "$(dirname "$out/$f")"
	mv -f "$staged/$f" "$out/$f"
done
rm -rf "$stage"

echo ">> $out/lib/libvirglrenderer.1.dylib"
otool -L "$out/lib/libvirglrenderer.1.dylib"

# --- standalone Venus check: renderer init, capset, context, host blob exported as shm fd
check=$work/venus_check
clang -std=c11 -Wall -Werror -o "$check" "$here/test/venus_check.c" \
	-I"$out/include" -L"$out/lib" -lvirglrenderer -Wl,-rpath,"$out/lib"
"$check"
