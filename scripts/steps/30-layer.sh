#!/bin/bash
# Step 30 (builder container): work/out/steamac-layer.img
# Read-only erofs image; its usr/ becomes the top lowerdir of the guest /usr
# overlay (lowerdir=<layer>/usr:<rootfs>/usr), see guest/initramfs/init.
# Contents: guest/layer/usr (steamac files) + work/out/mesa-venus/usr (Venus
# ICDs from guest/mesa; required unless ALLOW_NO_VENUS=1).
set -euo pipefail
. /src/scripts/config.env

OUT=/work/out/steamac-layer.img
VENUS=/work/out/mesa-venus
ST=$(mktemp -d)
trap 'rm -rf "$ST"' EXIT

cp -a /src/guest/layer/usr "$ST/usr"

if [[ -d $VENUS/usr ]]; then
    cp -a "$VENUS/usr/." "$ST/usr/"
    venus_info=$(cd "$VENUS/usr" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)
    echo "[layer] included Venus tree from $VENUS ($venus_info)"
elif [[ ${ALLOW_NO_VENUS:-} == 1 ]]; then
    venus_info="ABSENT (ALLOW_NO_VENUS=1)"
    echo "[layer] WARNING: $VENUS/usr missing, building layer WITHOUT Venus (ALLOW_NO_VENUS=1)" >&2
else
    echo "[layer] $VENUS/usr missing: build guest/mesa first (or ALLOW_NO_VENUS=1 for a test layer)" >&2
    exit 1
fi

# Sanity: the pieces the initramfs and the A/B flow depend on.
for f in usr/bin/splctl usr/lib/rauc/post-install.sh usr/lib/steamac/kernelsetup.sh \
         usr/lib/steamac/rauc-shims/steamos-chroot usr/lib/steamac/steam-gfx-env \
         usr/lib/steamos/gamescope-session; do
    [[ -x $ST/$f ]] || { echo "[layer] $f missing or not executable" >&2; exit 1; }
    bash -n "$ST/$f"
done
ls "$ST"/usr/lib/steamac/masks.d/*.list >/dev/null

# layer-release: content hash (excluding itself) so a boot log identifies the layer.
tree_hash=$(cd "$ST" && find usr -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)
cat > "$ST/usr/lib/steamac/layer-release" <<EOF
steamac-layer content=$tree_hash rootfs-pin=$STEAMOS_BUILDID venus=$venus_info
EOF

# Directory/file modes come from the repo checkout; normalise and make root-owned.
find "$ST" -type d -exec chmod 0755 {} +
find "$ST" -type f -perm -u+x -exec chmod 0755 {} +
find "$ST" -type f ! -perm -u+x -exec chmod 0644 {} +

epoch=${SOURCE_DATE_EPOCH:-1767225600}
rm -f "$OUT.tmp"
mkfs.erofs -zlz4hc -T "$epoch" -U 5fea1f2a-0c6b-4d5e-9a1e-0000000000a1 --all-root -L steamac-layer "$OUT.tmp" "$ST" >/dev/null
mv "$OUT.tmp" "$OUT"
echo "[layer] $OUT: $(stat -c %s "$OUT") bytes; $(cat "$ST/usr/lib/steamac/layer-release")"
