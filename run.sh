#!/usr/bin/env bash
# Boot SteamOS in a window. Extra arguments go to steamac-vm (see `work/out/steamac-vm --help`),
# e.g. ./run.sh --display 1920x1080 --cpus 10 --mem 24576
set -euo pipefail
out="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/work/out"
exec "$out/steamac-vm" \
    --kernel "$out/Image" \
    --initrd "$out/initramfs.cpio.gz" \
    --disk "$out/steamos.img" \
    --disk "$out/steamac-layer.img:ro" \
    "$@"
