#!/bin/sh
# Host reproductions of guest workloads on the built MoltenVK (no VM needed).
#
#   host/moltenvk/repro/run.sh [libdir]
#
# 1. gamescope_cs.c: fetches gamescope 3.16.28 (pinned), compiles src/shaders/cs_*.comp with
#    glslang like gamescope's meson build (glslangValidator -V) and creates every pipeline
#    variant; cs_composite_blit must write the expected pixels from s_samplers[0] and from
#    the Y'CbCr (NV12) array s_ycbcr_samplers[0]. Metal argument buffers stay on (default). Run twice:
#    as gamescope creates its device, and with robustBufferAccess + robustBufferAccess2 (bounds-checked
#    MSL; the packed mat3x4 u_ctm[] select of the composite shaders failed to compile).
# 2. geometry.c: shaders/ (zink-style passthrough geometry shader with gl_PrimitiveIDIn,
#    list and strip draws) and draws/dispatches with a VK_NULL_HANDLE pipeline bound (what
#    Venus replays when host pipeline creation failed).
# 3. depth_stencil.c: depth/stencil images with the usages zink gives GL renderbuffers (with
#    and without HOST_TRANSFER): every accepted usage must be allocatable and read back the
#    cleared depth/stencil values.
# 4. linear_pitch.c: LINEAR image with VkImageDrmFormatModifierExplicitCreateInfoEXT rowPitch
#    (virglrenderer dma-buf imports): layouts, memory size and pixel data use that pitch.
# 5. xfb.c: transform feedback captured by geometry shaders (DXVK stream-output style without
#    position and with rasterizer discard, strips with varying vertex counts, lines, 2 buffers,
#    buffer offsets/sizes, counter buffers), buffer contents checked.
# 6. zero_init.c: compute shaders with zero-initialized workgroup memory (literal and
#    specialization-constant workgroup sizes), read back after a dispatch dirtied the memory.
# 7. free_after_signal.c: memory freed after a timeline semaphore signalled while the command buffer
#    that signalled it still runs (DXVK; Heroes Olden Era device loss).
# 8. robust_access.c: robustBufferAccess2 MSL (texel buffer atomic store, struct/packed matrix/array
#    loads, read-modify-write, runtime array after a header) with limited buffer ranges: in-bounds data,
#    out-of-bounds zeros, out-of-bounds stores discarded.
# 9. invalid_usage.c: VK_NULL_HANDLE set layouts in a pipeline layout (independent sets, from Venus) and
#    rasterizationSamples 8 (not supported by Apple GPUs); then a pipeline whose MSL does not compile, whose
#    MSL must be logged as "[mvk-msl] " lines on stderr.
# 10. vertex_input.c: vertex input layouts Metal's always-on vertex descriptor validation aborts on (zero
#    strides, static/dynamic/per instance/zero divisor, attributes past the stride, attributes of undescribed
#    bindings, with and without geometry shader emulation), one process per case; points check the
#    elements read.
# All run with Metal API validation in assert mode (MTL_DEBUG_LAYER), so a Metal validation error
# fails the run instead of aborting a VM later.
# All are built against libMoltenVK in [libdir] (default work/out/host/lib) and must pass.
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
brew list --versions spirv-tools > /dev/null 2>&1 || brew install spirv-tools
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
MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert MVK_CONFIG_LOG_LEVEL=1 "$work/gamescope_cs" "$spv"
MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert MVK_CONFIG_LOG_LEVEL=1 "$work/gamescope_cs" "$spv" robust2

gspv=$work/geometry-spv
rm -rf "$gspv"
mkdir -p "$gspv"
for s in "$here"/shaders/*.vert "$here"/shaders/*.geom "$here"/shaders/*.frag; do
	glslangValidator -V --quiet "$s" -o "$gspv/$(basename "$s").spv"
done
for s in "$here"/shaders/*.comp; do
	glslangValidator -V --quiet --target-env vulkan1.3 "$s" -o "$gspv/$(basename "$s").spv"
done
for s in "$here"/shaders/*.spvasm; do
	spirv-as --target-env vulkan1.0 "$s" -o "$gspv/$(basename "$s" .spvasm).spv"
done
xcrun clang -std=c11 -Wall -Werror -O1 -I"$inc" "$here/geometry.c" \
	-L"$libdir" -lMoltenVK -Wl,-rpath,"$libdir" -o "$work/geometry"
MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert MVK_CONFIG_LOG_LEVEL=1 "$work/geometry" "$gspv"

xcrun clang -std=c11 -Wall -Werror -O1 -I"$inc" "$here/depth_stencil.c" \
	-L"$libdir" -lMoltenVK -Wl,-rpath,"$libdir" -o "$work/depth_stencil"
MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert MVK_CONFIG_LOG_LEVEL=1 "$work/depth_stencil"

xcrun clang -std=c11 -Wall -Werror -O1 -I"$inc" "$here/linear_pitch.c" \
	-L"$libdir" -lMoltenVK -Wl,-rpath,"$libdir" -o "$work/linear_pitch"
MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert MVK_CONFIG_LOG_LEVEL=1 "$work/linear_pitch"

xcrun clang -std=c11 -Wall -Werror -O1 -I"$inc" "$here/xfb.c" \
	-L"$libdir" -lMoltenVK -Wl,-rpath,"$libdir" -o "$work/xfb"
MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert MVK_CONFIG_LOG_LEVEL=1 "$work/xfb" "$gspv"

xcrun clang -std=c11 -Wall -Werror -O1 -I"$inc" "$here/zero_init.c" \
	-L"$libdir" -lMoltenVK -Wl,-rpath,"$libdir" -o "$work/zero_init"
MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert MVK_CONFIG_LOG_LEVEL=1 "$work/zero_init" "$gspv"

glslangValidator -V --quiet -x "$here/shaders/busy.comp" -o "$work/busy.comp.inc"
xcrun clang -std=c11 -Wall -Werror -O1 -I"$work" -I"$inc" "$here/free_after_signal.c" \
	-L"$libdir" -lMoltenVK -Wl,-rpath,"$libdir" -o "$work/free_after_signal"
MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert MVK_CONFIG_LOG_LEVEL=1 "$work/free_after_signal"

xcrun clang -std=c11 -Wall -Werror -O1 -I"$inc" "$here/robust_access.c" \
	-L"$libdir" -lMoltenVK -Wl,-rpath,"$libdir" -o "$work/robust_access"
MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert MVK_CONFIG_LOG_LEVEL=1 "$work/robust_access" "$gspv"

xcrun clang -std=c11 -Wall -Werror -O1 -I"$inc" "$here/invalid_usage.c" \
	-L"$libdir" -lMoltenVK -Wl,-rpath,"$libdir" -o "$work/invalid_usage"
MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert MVK_CONFIG_LOG_LEVEL=1 "$work/invalid_usage" "$gspv"
# The failing MSL is logged after the error: the first lines, and the lines around the error location.
msl_log=$work/msl-log.txt
MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert MVK_CONFIG_LOG_LEVEL=1 "$work/invalid_usage" "$gspv" msl-log 2> "$msl_log"
if grep -q '^\[mvk-msl\] #include <metal_stdlib>$' "$msl_log" && grep -q '^\[mvk-msl\] [0-9][0-9]*: .*double' "$msl_log"; then
	echo "OK   failing MSL logged: $(grep -c '^\[mvk-msl\] ' "$msl_log") [mvk-msl] lines, error context:"
	grep '^\[mvk-msl\] [0-9][0-9]*: ' "$msl_log"
else
	echo "FAIL failing MSL not logged as [mvk-msl] lines:"
	cat "$msl_log"
	exit 1
fi

xcrun clang -std=c11 -Wall -Werror -O1 -I"$inc" "$here/vertex_input.c" \
	-L"$libdir" -lMoltenVK -Wl,-rpath,"$libdir" -o "$work/vertex_input"
MTL_DEBUG_LAYER=1 MTL_DEBUG_LAYER_ERROR_MODE=assert MVK_CONFIG_LOG_LEVEL=1 "$work/vertex_input" "$gspv"
