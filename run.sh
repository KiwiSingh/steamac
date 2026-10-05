#!/usr/bin/env bash
# Boot SteamOS in a window. Extra arguments go to steamac-vm (see `work/out/steamac-vm --help`),
# e.g. ./run.sh --display 1920x1080 --cpus 10 --mem 24576
set -euo pipefail
out="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/work/out"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -n ${STEAMAC_DISK_PATH:-} ]]; then
    disk=$STEAMAC_DISK_PATH
elif [[ -n ${STEAMAC_STORAGE_VOLUME:-} ]]; then
    disk="$STEAMAC_STORAGE_VOLUME/steamac/steamos.img"
else
    echo 'Set STEAMAC_STORAGE_VOLUME to your external drive, or STEAMAC_DISK_PATH to its image.' >&2
    exit 1
fi
python3 "$root/scripts/external-storage.py" "$disk" >/dev/null
exec "$out/steamac-vm" \
    --kernel "$out/Image" \
    --initrd "$out/initramfs.cpio.gz" \
    --disk "$disk" \
    --disk "$out/steamac-layer.img:ro" \
    "$@"
