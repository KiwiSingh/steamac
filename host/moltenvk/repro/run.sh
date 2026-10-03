#!/bin/sh
# Host reproduction of gamescope's compute pipelines on the built MoltenVK (no VM needed).
#
#   host/moltenvk/repro/run.sh [libdir]
#
# Fetches gamescope 3.16.28 (pinned), compiles src/shaders/cs_*.comp with glslang exactly
# like gamescope's meson build (glslangValidator -V), builds gamescope_cs.c against
# libMoltenVK in [libdir] (default work/out/host/lib) and runs it: every pipeline variant
# must compile and cs_composite_blit must write the expected pixels from s_samplers[0]
# and from the Y'CbCr (NV12) array s_ycbcr_samplers[0]. Metal argument buffers stay at
# MoltenVK's default (on).
set -eu

GAMESCOPE_REPO=https://github.com/ValveSoftware/gamescope.git
GAMESCOPE_TAG=3.16.28
GAMESCOPE_COMMIT=fa0b4d3342078f01eadff0193e09c3b561f40c03

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
work=$root/work/build/host-moltenvk/repro
libdir=${1:-$root/work/out/host/lib}
inc=$root/work/build/host-moltenvk/src/Package/Release/MoltenVK/include

brew list --versions glslang > /dev/null 2>&1 || brew install glslang
mkdir -p "$work"

src=$work/gamescope
if [ ! -d "$src/.git" ]; then
	git init -q "$src"
	git -C "$src" remote add origin "$GAMESCOPE_REPO"
fi
if ! git -C "$src" cat-file -e "$GAMESCOPE_COMMIT^{commit}" 2> /dev/null; then
	git -C "$src" fetch -q --depth 1 origin "refs/tags/$GAMESCOPE_TAG:refs/tags/$GAMESCOPE_TAG"
fi
test "$(git -C "$src" rev-parse "$GAMESCOPE_TAG^{commit}")" = "$GAMESCOPE_COMMIT"
git -C "$src" checkout -q -f --detach "$GAMESCOPE_COMMIT"

spv=$work/spv
rm -rf "$spv"
mkdir -p "$spv"
for s in "$src"/src/shaders/cs_*.comp; do
	glslangValidator -V --quiet "$s" -o "$spv/$(basename "$s" .comp).spv"
done

xcrun clang -std=c11 -Wall -Werror -O1 -I"$inc" "$here/gamescope_cs.c" \
	-L"$libdir" -lMoltenVK -Wl,-rpath,"$libdir" -o "$work/gamescope_cs"
MVK_CONFIG_LOG_LEVEL=1 "$work/gamescope_cs" "$spv"
