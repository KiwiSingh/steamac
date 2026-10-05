#!/usr/bin/env bash
# Stage the selected ICD and the loader used by both supported host paths.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/work/out/host"
case ${STEAMAC_VULKAN_DRIVER:-moltenvk} in
    moltenvk) "$ROOT/host/moltenvk/build.sh" ;;
    kosmickrisp) exec "$ROOT/host/kosmickrisp/build.sh" ;;
    *) echo "Unknown STEAMAC_VULKAN_DRIVER: ${STEAMAC_VULKAN_DRIVER}" >&2; exit 2 ;;
esac
for dep in vulkan-loader vulkan-headers; do
    brew list --versions "$dep" >/dev/null 2>&1 || { echo "Missing build prerequisite: $dep" >&2; exit 1; }
done
mkdir -p "$OUT/lib" "$OUT/include"
cp -L "$(brew --prefix vulkan-loader)/lib/libvulkan.1.dylib" "$OUT/lib/libvulkan.1.dylib.new"
install_name_tool -id @rpath/libvulkan.1.dylib "$OUT/lib/libvulkan.1.dylib.new"
codesign --force -s - "$OUT/lib/libvulkan.1.dylib.new"
mv "$OUT/lib/libvulkan.1.dylib.new" "$OUT/lib/libvulkan.1.dylib"
ln -sf libvulkan.1.dylib "$OUT/lib/libvulkan.dylib"
cp -R "$(brew --prefix vulkan-headers)/include/vulkan" "$OUT/include/"
cp -R "$(brew --prefix vulkan-headers)/include/vk_video" "$OUT/include/"
