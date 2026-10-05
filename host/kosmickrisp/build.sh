#!/usr/bin/env bash
# Build Mesa's KosmicKrisp ICD and stage the Vulkan loader for the VM and app bundle.
# All source/build output lives under the repository's work directory.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK="$ROOT/work/build/host-kosmickrisp"
OUT="$ROOT/work/out/host"
MESA_COMMIT=4cf0989083d25b92d02c6fef2bed934ad77b4ecd
[[ $(uname -m) == arm64 ]] || { echo "KosmicKrisp requires Apple Silicon." >&2; exit 1; }
[[ $(sw_vers -productVersion | cut -d. -f1) -ge 26 ]] || { echo "KosmicKrisp requires macOS 26+." >&2; exit 1; }
# Dependencies are checked, never silently installed on the system drive.
for dep in meson ninja pkgconf llvm libclc spirv-llvm-translator spirv-tools vulkan-loader vulkan-headers; do
    brew list --versions "$dep" >/dev/null 2>&1 || {
        echo "Missing $dep. Install build prerequisites before building (see docs/fork-setup.md)." >&2; exit 1;
    }
done
mkdir -p "$WORK" "$OUT/lib" "$OUT/include" "$OUT/share/vulkan/icd.d"
export TMPDIR="$WORK/tmp"
export PIP_CACHE_DIR="$WORK/pip-cache"
mkdir -p "$TMPDIR"
if [[ ! -d "$WORK/src/.git" ]]; then
    git init -q "$WORK/src"
    git -C "$WORK/src" remote add origin https://gitlab.freedesktop.org/mesa/mesa.git
fi
git -C "$WORK/src" fetch --depth=1 origin "$MESA_COMMIT"
git -C "$WORK/src" checkout --detach "$MESA_COMMIT"
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install mako==1.3.10 pyyaml==6.0.3 packaging==25.0
export PATH="$WORK/venv/bin:$(brew --prefix llvm)/bin:$(brew --prefix spirv-llvm-translator)/bin:$PATH"
export PKG_CONFIG_PATH="$(brew --prefix spirv-tools)/lib/pkgconfig:$(brew --prefix spirv-llvm-translator)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
# Homebrew's SPIR-V translator links shared LLVM. The CLC tools must use the same
# LLVM instance; static LLVM here duplicates analysis keys and crashes shader compilation.
if [[ -f "$WORK/build/build.ninja" ]]; then
    meson setup --reconfigure "$WORK/build" "$WORK/src" --prefix="$OUT" --libdir=lib \
        --buildtype=release -Dplatforms=macos -Dvulkan-drivers=kosmickrisp \
        -Dgallium-drivers= -Dopengl=false -Dzstd=disabled -Dshared-llvm=enabled -Dvulkan-loader-rpath=@loader_path --prefer-static
else
    meson setup "$WORK/build" "$WORK/src" --prefix="$OUT" --libdir=lib \
        --buildtype=release -Dplatforms=macos -Dvulkan-drivers=kosmickrisp \
        -Dgallium-drivers= -Dopengl=false -Dzstd=disabled -Dshared-llvm=enabled -Dvulkan-loader-rpath=@loader_path --prefer-static
fi
ninja -C "$WORK/build"
DESTDIR="$WORK/stage" ninja -C "$WORK/build" install
cp "$WORK/stage$OUT/lib/libvulkan_kosmickrisp.dylib" "$OUT/lib/libvulkan_kosmickrisp.dylib.new"
install_name_tool -id @rpath/libvulkan_kosmickrisp.dylib "$OUT/lib/libvulkan_kosmickrisp.dylib.new"
codesign --force -s - "$OUT/lib/libvulkan_kosmickrisp.dylib.new"
mv "$OUT/lib/libvulkan_kosmickrisp.dylib.new" "$OUT/lib/libvulkan_kosmickrisp.dylib"
loader="$(brew --prefix vulkan-loader)/lib/libvulkan.1.dylib"
cp -L "$loader" "$OUT/lib/libvulkan.1.dylib.new"
install_name_tool -id @rpath/libvulkan.1.dylib "$OUT/lib/libvulkan.1.dylib.new"
codesign --force -s - "$OUT/lib/libvulkan.1.dylib.new"
mv "$OUT/lib/libvulkan.1.dylib.new" "$OUT/lib/libvulkan.1.dylib"
ln -sf libvulkan.1.dylib "$OUT/lib/libvulkan.dylib"
cp -R "$(brew --prefix vulkan-headers)/include/vulkan" "$OUT/include/"
cp -R "$(brew --prefix vulkan-headers)/include/vk_video" "$OUT/include/"
python3 -c 'import json,sys; json.dump({"file_format_version":"1.0.0","ICD":{"library_path":"../../../lib/libvulkan_kosmickrisp.dylib","api_version":"1.4.0"}},open(sys.argv[1],"w"),indent=2)' "$OUT/share/vulkan/icd.d/kosmickrisp.json"
printf 'Mesa KosmicKrisp %s\n' "$MESA_COMMIT" > "$OUT/KOSMICKRISP.txt"
echo "Built KosmicKrisp; next build virglrenderer to run the Venus shared-memory check."
