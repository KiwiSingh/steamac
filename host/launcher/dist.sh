#!/usr/bin/env bash
# Distributable FX Steam Launcher: a copy of work/out/FX Steam Launcher.app (build.sh / bundle.sh)
# re-signed with a Developer ID (hardened runtime, secure timestamp), notarized and stapled, inside
# a signed, notarized and stapled DMG with an /Applications link:
#   work/out/dist/FX Steam Launcher.app
#   work/out/dist/FX-Steam-Launcher-<CFBundleShortVersionString>.dmg
# The copy drops the dev-only SteamacBuildOut Info.plist key (this build tree's path). Every nested
# Mach-O (Frameworks dylibs, helper tools in Resources) is signed before the bundle, so helpers
# added to bundle.sh later are covered without changes here.
#
#   host/launcher/dist.sh [--no-notarize]
#
# Env:
#   STEAMAC_SIGN_IDENTITY  codesign identity (default: the keychain's only "Developer ID Application")
#   NOTARY_PROFILE         notarytool keychain profile (default steamac-notary), created once with
#                          xcrun notarytool store-credentials steamac-notary \
#                              --apple-id <Apple ID> --team-id <team> --password <app-specific password>
#   --no-notarize          sign only (local tests; Gatekeeper rejects downloaded copies)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT="$ROOT/work/out"
NAME="FX Steam Launcher"
SRC="$OUT/$NAME.app"
DIST="$OUT/dist"
ENTITLEMENTS="$HERE/steamac-vm.entitlements"

die() { echo "dist.sh: $*" >&2; exit 1; }

notarize=1
case ${1:-} in
    "") ;;
    --no-notarize) notarize=0 ;;
    *) die "usage: $0 [--no-notarize]" ;;
esac
[[ -d $SRC ]] || die "missing $SRC (run host/launcher/build.sh)"

identity=${STEAMAC_SIGN_IDENTITY:-}
if [[ -z $identity ]]; then
    ids=$(security find-identity -v -p codesigning | awk -F'"' '/"Developer ID Application: / {print $2}' | sort -u)
    [[ -n $ids ]] || die "no \"Developer ID Application\" identity in the keychain (set STEAMAC_SIGN_IDENTITY)"
    [[ $(wc -l <<<"$ids") -eq 1 ]] || die "several Developer ID identities, pick one with STEAMAC_SIGN_IDENTITY:"$'\n'"$ids"
    identity=$ids
fi
team=$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$identity")
[[ -n $team ]] || die "cannot read the team ID from identity '$identity'"

profile=${NOTARY_PROFILE:-steamac-notary}
if [[ $notarize == 1 ]]; then
    # Fail before signing if the credentials are missing.
    xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
        || die "notarytool profile '$profile' is not usable; create it with:
  xcrun notarytool store-credentials $profile --apple-id <Apple ID> --team-id $team --password <app-specific password>
(or set NOTARY_PROFILE, or pass --no-notarize for a local test build)"
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Contents/Info.plist")
DMG_NAME="FX-Steam-Launcher-$version.dmg"
mkdir -p "$DIST"
WORK="$DIST/.work.$$"
rm -rf "$WORK"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
APP="$WORK/$NAME.app"
ditto "$SRC" "$APP"
/usr/libexec/PlistBuddy -c 'Delete :SteamacBuildOut' "$APP/Contents/Info.plist" 2>/dev/null || true

echo "=== signing with \"$identity\" (hardened runtime)"
sign() { codesign --force --timestamp --options runtime --sign "$identity" "$@"; }
main_exe="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
nested=()
while IFS= read -r -d '' f; do
    [[ $f == "$main_exe" ]] && continue
    file -b "$f" | grep -q '^Mach-O' && nested+=("$f")
done < <(find "$APP/Contents" -type f -print0)
for f in "${nested[@]}"; do sign "$f"; done
sign --entitlements "$ENTITLEMENTS" "$APP"

codesign --verify --deep --strict "$APP"
for f in "$main_exe" "${nested[@]}"; do
    info=$(codesign -dv "$f" 2>&1)
    grep -q "TeamIdentifier=$team" <<<"$info" || die "${f#"$APP/"}: not signed by team $team"
    grep -q 'flags=0x10000(runtime)' <<<"$info" || die "${f#"$APP/"}: hardened runtime flag missing"
    grep -q '^Timestamp=' <<<"$info" || die "${f#"$APP/"}: no secure timestamp"
    echo "  ok ${f#"$APP/"}"
done
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - | sed 's/^/  /'

# notarize <file>: submit, wait, print the log and fail unless Accepted.
notarize() {
    local json id status
    json=$(xcrun notarytool submit "$1" --keychain-profile "$profile" --wait --output-format json) || true
    id=$(plutil -extract id raw -o - - <<<"$json" 2>/dev/null || true)
    status=$(plutil -extract status raw -o - - <<<"$json" 2>/dev/null || true)
    echo "  notarytool: ${id:-?} ${status:-no status}"
    if [[ $status != Accepted ]]; then
        echo "$json" >&2
        [[ -n $id ]] && xcrun notarytool log "$id" --keychain-profile "$profile" >&2
        die "notarization of ${1##*/} failed"
    fi
}

if [[ $notarize == 1 ]]; then
    echo "=== notarizing the app"
    ditto -c -k --keepParent "$APP" "$WORK/app.zip"
    notarize "$WORK/app.zip"
    xcrun stapler staple -q "$APP"
    xcrun stapler validate -q "$APP"
    spctl -a -t exec -vv "$APP"
fi

echo "=== building $DMG_NAME"
mkdir -p "$WORK/dmg"
ditto "$APP" "$WORK/dmg/$NAME.app"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -quiet -volname "$NAME" -srcfolder "$WORK/dmg" -fs HFS+ -format ULFO -ov "$WORK/$DMG_NAME"
codesign --force --timestamp --sign "$identity" "$WORK/$DMG_NAME"

if [[ $notarize == 1 ]]; then
    echo "=== notarizing the DMG"
    notarize "$WORK/$DMG_NAME"
    xcrun stapler staple -q "$WORK/$DMG_NAME"
    xcrun stapler validate -q "$WORK/$DMG_NAME"
    spctl -a -t open --context context:primary-signature -vv "$WORK/$DMG_NAME"
fi

rm -rf "$DIST/$NAME.app" "$DIST/$DMG_NAME"
mv "$APP" "$DIST/$NAME.app"
mv "$WORK/$DMG_NAME" "$DIST/$DMG_NAME"
echo "built $DIST/$DMG_NAME ($(du -h "$DIST/$DMG_NAME" | cut -f1), sha256 $(shasum -a 256 "$DIST/$DMG_NAME" | cut -d' ' -f1))"
[[ $notarize == 1 ]] || echo "NOT notarized (--no-notarize): Gatekeeper blocks this DMG once downloaded"
