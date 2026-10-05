#!/usr/bin/env bash
# Read-only volume checks; scratch files stay in this checkout's work directory.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
volume=${1:?usage: external-storage-check.sh /Volumes/YourSSD}
volume=$(python3 "$root/scripts/external-storage.py" "$volume")
mkdir -p "$root/work"
tmp=$(mktemp -d "$root/work/storage-check.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
ln -s "$volume" "$tmp/SSD alias with spaces"
ln -s /tmp "$tmp/internal alias"
cat > "$tmp/main.swift" <<'SWIFT'
import Foundation
let volume = CommandLine.arguments[1], tmp = CommandLine.arguments[2]
precondition(ExternalStorage.volume(forPath: volume + "/new-directory/steamos.img")?.path == volume)
precondition(ExternalStorage.volume(forPath: tmp + "/SSD alias with spaces/new-directory/steamos.img")?.path == volume)
precondition(ExternalStorage.cacheRoot(forDisk: tmp + "/SSD alias with spaces/image.img") == volume + "/steamac/cache")
for path in ["/tmp/no-disk.img", "/Volumes/Definitely-Missing-SSD/image.img", "relative.img", tmp + "/internal alias/image.img"] {
    precondition(ExternalStorage.volume(forPath: path) == nil, path)
}
print("PASS external destination/cache, spaced symlink alias, internal and disconnected volume refusal")
SWIFT
swiftc -module-cache-path "$tmp/module-cache" "$root/host/launcher/Sources/steamac-vm/ExternalStorage.swift" "$tmp/main.swift" -o "$tmp/check"
"$tmp/check" "$volume" "$tmp"
python3 "$root/scripts/external-storage.py" "$tmp/SSD alias with spaces/new-directory/image.img" | grep -Fx "$volume"
if python3 "$root/scripts/external-storage.py" "$tmp/internal alias/image.img"; then
    echo 'Internal symlink target was accepted' >&2
    exit 1
fi
