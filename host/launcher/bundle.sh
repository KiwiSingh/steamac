#!/usr/bin/env bash
# Assemble work/out/FX Steam Launcher.app (called by build.sh with the freshly built binary):
#   Contents/MacOS/steamac-vm           launcher, rpath @executable_path/../Frameworks only
#   Contents/Frameworks/*.dylib         libkrun, libvirglrenderer, libvulkan, KosmicKrisp + their non-system
#                                       dependencies (libepoxy), install names @rpath/<name>
#   Contents/Resources/                 gvproxy, Image, initramfs.cpio.gz, steamac-layer.img,
#                                       desync + steamdeck-images.pem (Valve RAUC CA) for
#                                       "Create New Disk…", licenses/ (desync, zstd),
#                                       Assets.car + AppIcon.icns (app icon, see below)
# The SteamOS disk is not bundled (Settings > Advanced "Disk image" / "Create New Disk…"). Ad-hoc
# signed with the hypervisor + disable-library-validation entitlements. Built in a temp dir,
# then moved in place.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT="$ROOT/work/out"
KRUN_PREFIX="${KRUN_PREFIX:-$OUT/host}"
BIN="${1:?usage: bundle.sh <steamac-vm binary>}"
NAME="FX Steam Launcher"
APP="$OUT/$NAME.app"
STAGE="$OUT/.bundle.$$"
TMP="$STAGE/$NAME.app"

ZSTD_LICENSE="$HERE/Sources/CZstd/zstd/LICENSE"
for f in Image initramfs.cpio.gz steamac-layer.img host/bin/gvproxy host/bin/desync host/share/desync/LICENSE; do
    [[ -f "$OUT/$f" ]] || { echo "bundle.sh: missing $OUT/$f" >&2; exit 1; }
done
[[ -f "$ZSTD_LICENSE" ]] || { echo "bundle.sh: missing $ZSTD_LICENSE (run fetch-zstd.sh)" >&2; exit 1; }

rm -rf "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$TMP/Contents/MacOS" "$TMP/Contents/Frameworks" "$TMP/Contents/Resources"

# build.sh's Info.plist carries the build identity crash reports use (SteamacGitCommit, ...).
PLIST="$HERE/.build/Info.plist"
[[ -f $PLIST ]] || PLIST="$HERE/Info.plist"
cp "$PLIST" "$TMP/Contents/Info.plist"
# Lets the app find the repo's work/out/steamos.img as its default disk when moved elsewhere.
/usr/libexec/PlistBuddy -c "Add :SteamacBuildOut string $OUT" "$TMP/Contents/Info.plist"
# Release defaults (AppBundle.releaseDefaults): SSH off, generated guest password, no default
# password on created disks. The dev launcher work/out/steamac-vm (embedded Info.plist) has none.
/usr/libexec/PlistBuddy -c "Add :SteamacReleaseDefaults bool true" "$TMP/Contents/Info.plist"
printf 'APPL????' > "$TMP/Contents/PkgInfo"

exe="$TMP/Contents/MacOS/steamac-vm"
cp "$BIN" "$exe"
chmod u+w "$exe"

is_system() { [[ "$1" == /usr/lib/* || "$1" == /System/* ]]; }

# Copy a dylib (and, recursively, its non-system dependencies) into Frameworks.
FW="$TMP/Contents/Frameworks"
copy_lib() {
    local src="$1" name
    name=$(basename "$src")
    [[ -f "$FW/$name" ]] && return 0
    cp -L "$src" "$FW/$name"
    chmod u+w "$FW/$name"
    install_name_tool -id "@rpath/$name" "$FW/$name" 2>/dev/null
    local dep
    while read -r dep; do
        is_system "$dep" && continue
        local base
        base=$(basename "$dep")
        if [[ "$dep" == @rpath/* ]]; then
            [[ "$base" == "$name" ]] && continue
            [[ -f "$KRUN_PREFIX/lib/$base" ]] || { echo "bundle.sh: $name needs $dep, not in $KRUN_PREFIX/lib" >&2; exit 1; }
            copy_lib "$KRUN_PREFIX/lib/$base"
        else
            [[ -f "$dep" ]] || { echo "bundle.sh: $name needs $dep (not found)" >&2; exit 1; }
            install_name_tool -change "$dep" "@rpath/$base" "$FW/$name" 2>/dev/null
            copy_lib "$dep"
        fi
    done < <(otool -L "$FW/$name" | awk 'NR > 1 {print $1}')
    # Dependencies resolve next to each other.
    otool -l "$FW/$name" | grep -q '@loader_path$' || install_name_tool -add_rpath @loader_path "$FW/$name" 2>/dev/null
}

for lib in libkrun.1.dylib libvirglrenderer.1.dylib libvulkan.1.dylib libvulkan_kosmickrisp.dylib; do
    copy_lib "$KRUN_PREFIX/lib/$lib"
done

mkdir -p "$TMP/Contents/Resources/vulkan"
python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); p["ICD"]["library_path"]="../../Frameworks/libvulkan_kosmickrisp.dylib"; json.dump(p,open(sys.argv[2],"w"),indent=2)' "$KRUN_PREFIX/share/vulkan/icd.d/kosmickrisp.json" "$TMP/Contents/Resources/vulkan/kosmickrisp.json"

# The executable: only the bundle's Frameworks on its rpath.
while read -r rp; do
    install_name_tool -delete_rpath "$rp" "$exe" 2>/dev/null   # (re-signed below)
done < <(otool -l "$exe" | awk '/cmd LC_RPATH/ {getline; getline; print $2}')
install_name_tool -add_rpath @executable_path/../Frameworks "$exe" 2>/dev/null
while read -r dep; do
    is_system "$dep" && continue
    [[ "$dep" == @rpath/* ]] || { echo "bundle.sh: steamac-vm links $dep" >&2; exit 1; }
    [[ -f "$FW/$(basename "$dep")" ]] || { echo "bundle.sh: $dep not bundled" >&2; exit 1; }
done < <(otool -L "$exe" | awk 'NR > 1 {print $1}')

# Resources (APFS clones where possible; the layer and kernel are rebuilt by the guest scripts).
for f in Image initramfs.cpio.gz steamac-layer.img; do
    cp -c "$OUT/$f" "$TMP/Contents/Resources/$f" 2>/dev/null || cp "$OUT/$f" "$TMP/Contents/Resources/$f"
done
cp "$OUT/host/bin/gvproxy" "$TMP/Contents/Resources/gvproxy"
cp "$OUT/host/bin/desync" "$TMP/Contents/Resources/desync"
chmod 755 "$TMP/Contents/Resources/gvproxy" "$TMP/Contents/Resources/desync"
cp "$ROOT/scripts/keys/steamdeck-images.pem" "$TMP/Contents/Resources/steamdeck-images.pem"
mkdir -p "$TMP/Contents/Resources/licenses"
cp "$OUT/host/share/desync/LICENSE" "$TMP/Contents/Resources/licenses/desync-LICENSE"
cp "$ZSTD_LICENSE" "$TMP/Contents/Resources/licenses/zstd-LICENSE"

# App icon: AppIcon.icon (Icon Composer document) compiled by Xcode 26's actool into Assets.car
# (layered Liquid Glass icon for macOS 26, pre-rendered squircle renditions for macOS 15) and an
# AppIcon.icns fallback; Info.plist names them (CFBundleIconName / CFBundleIconFile = AppIcon).
if ! log=$(xcrun actool "$HERE/AppIcon.icon" --compile "$TMP/Contents/Resources" --platform macosx \
        --minimum-deployment-target 26.0 --app-icon AppIcon \
        --output-partial-info-plist "$STAGE/icon-info.plist" 2>&1) \
        || [[ ! -f "$TMP/Contents/Resources/Assets.car" || ! -f "$TMP/Contents/Resources/AppIcon.icns" ]]; then
    echo "$log" >&2
    echo "bundle.sh: actool did not compile $HERE/AppIcon.icon (needs Xcode 26 or newer)" >&2
    exit 1
fi
rm -f "$STAGE/icon-info.plist"

# Sign inside-out: libraries, helper executables, then the bundle (executable + sealed resources).
for f in "$FW"/*.dylib "$TMP/Contents/Resources/gvproxy" "$TMP/Contents/Resources/desync"; do
    codesign --force --sign - --timestamp=none "$f"
done
codesign --force --sign - --timestamp=none --entitlements "$HERE/steamac-vm.entitlements" "$TMP"
codesign --verify --deep --strict "$TMP"

rm -rf "$APP"
mv "$TMP" "$APP"
rmdir "$STAGE"
trap - EXIT
echo "built $APP"
