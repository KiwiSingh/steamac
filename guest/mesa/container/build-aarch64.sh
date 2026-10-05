#!/bin/bash
# Runs in AARCH64_IMAGE (holo-deckard base-devel = Steam Frame userspace, arm64).
# Mounts: /src (mesa source, ro), /scripts (ro), /out (guest tree), /work (test bins, logs).
set -euo pipefail
source /scripts/common.sh

# Build deps from the image's own pacman.conf (public, token-free pipeline/174308 + hotfix repo).
# --needed: never touch libraries that are already installed (they must stay identical to the image).
pacman -Sy --noconfirm --needed \
    meson ninja python-mako python-yaml python-packaging \
    libdrm wayland wayland-protocols libx11 libxcb libxshmfence libxrandr libdisplay-info \
    xcb-proto xorgproto vulkan-headers systemd-libs zstd expat zlib

build_venus /tmp/build-aarch64 lib /tmp/dest-aarch64

install -D -m 0755 /tmp/dest-aarch64/usr/lib/libvulkan_virtio.so /out/usr/lib/libvulkan_virtio.so
install -D -m 0644 /tmp/dest-aarch64/usr/share/vulkan/icd.d/virtio_icd.aarch64.json \
    /out/usr/share/vulkan/icd.d/virtio_icd.aarch64.json

mkdir -p /work/bin
gcc -O2 -Wall -o /work/bin/vkprobe-aarch64 /scripts/vkprobe.c -ldl
pacman -Q glibc gcc-libs libdrm wayland libxcb libxshmfence libdisplay-info systemd-libs zstd expat zlib \
    meson python-mako vulkan-headers > /work/packages-aarch64.txt
gcc --version | head -1 > /work/toolchain-aarch64.txt

gcc -O2 -Wall -Wextra -Werror -o /work/bin/steamac-dx12-check /scripts/dx12-check.c -ldl
install -D -m 0755 /work/bin/steamac-dx12-check /out/usr/bin/steamac-dx12-check
