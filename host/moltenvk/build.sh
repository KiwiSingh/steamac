#!/bin/sh
# Build MoltenVK for the host Venus renderer (virglrenderer -> MoltenVK -> Metal).
#
#   host/moltenvk/build.sh        build/refresh work/out/host (MoltenVK dylib, ICD json, headers)
#   host/moltenvk/build.sh clean  drop the source/build tree (next build is from scratch)
#
# Inputs (all pinned):
#   MoltenVK     utmapp/MoltenVK branch geometry-shaders @ 05604465 (UTM's pin,
#                patches/sources in utmapp/UTM): v1.4.1 + geometry shaders via Metal
#                mesh shaders, robustness2 RBA2/RIA2/nullDescriptor, shaderCullDistance
#                flag, VK_EXT_transform_feedback
#   SPIRV-Cross  utmapp/SPIRV-Cross @ 939b40b3 (the fork's ExternalRevisions pin)
#   patches/moltenvk/     applied in order on MoltenVK (git format-patch series)
#   patches/spirv-cross/  applied in order on SPIRV-Cross, passed to fetchDependencies
#                         via --spirv-cross-root
#   Xcode        command line tools + Metal toolchain (built and tested with Xcode 26.3)
#
# Build is UTM's (scripts/build_dependencies.sh build_moltenvk): ./fetchDependencies --macos
# then `make macos` (Release, universal), then the arm64 slice is extracted.
#
# Metal private API (MVK_USE_METAL_PRIVATE_API=1: logicOp, wideLines, ...) is NOT enabled, same
# as UTM and Homebrew: the fork's geometry-shader mesh pipeline path does not compile with it
# (MTLMeshRenderPipelineDescriptor has no logicOperation*/sampleMask private properties).
# See MOLTENVK.txt.
#
# Output (work/out/host):
#   lib/libMoltenVK.dylib                     arm64, install_name @rpath/libMoltenVK.dylib, ad-hoc signed
#   share/vulkan/icd.d/MoltenVK_icd.json      library_path ../../../lib/libMoltenVK.dylib
#   include/MoltenVK/                         mvk_vulkan.h, mvk_private_api.h, ... (they
#                                             include <vulkan/...>, from the Vulkan SDK/Homebrew
#                                             vulkan-headers or from the MoltenVK package in
#                                             work/build/host-moltenvk/src/Package/Release/MoltenVK/include)
#   MOLTENVK.txt                              provenance + enabled features
# The dylib is first staged in work/build/host-moltenvk/stage and verified there: the probe in
# probe/ (fails when a feature steamac depends on is missing) and the repros in repro/ (all of
# gamescope 3.16.28's cs_*.comp pipelines + a pixel check; zink-style geometry shaders + pixel
# checks; draws with a VK_NULL_HANDLE pipeline bound). Only then is it installed, by temp file +
# rename (a running VM may have the old dylib mapped).
set -eu

MVK_REPO=https://github.com/utmapp/MoltenVK.git
MVK_BRANCH=geometry-shaders
MVK_COMMIT=05604465d691118cfd20f53a48ecf1aad9c12f93
SPVC_REPO=https://github.com/utmapp/SPIRV-Cross.git
SPVC_COMMIT=939b40b33a44443c404c4078823c406e3c94866f

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$root/work/build/host-moltenvk
src=$work/src
spvc=$work/SPIRV-Cross
out=$root/work/out/host

if [ "${1:-}" = clean ]; then
	rm -rf "$work"
	exit 0
fi

xcrun --find metal > /dev/null

mkdir -p "$work"

# fetch_pinned <dir> <repo> <commit>: shallow checkout of one commit, patches dropped
fetch_pinned() {
	if [ ! -d "$1/.git" ]; then
		git init -q "$1"
		git -C "$1" remote add origin "$2"
	fi
	if ! git -C "$1" cat-file -e "$3^{commit}" 2> /dev/null; then
		git -C "$1" fetch -q --depth 1 origin "$3"
	fi
	git -C "$1" checkout -q -f --detach "$3"
}

# apply_series <dir> <patch dir>
apply_series() {
	for p in "$2"/*.patch; do
		echo ">> $(basename "$1"): applying $(basename "$p")"
		git -C "$1" apply "$p"
	done
}

# --- SPIRV-Cross (pinned by the fork) + patches
fetch_pinned "$spvc" "$SPVC_REPO" "$SPVC_COMMIT"
git -C "$spvc" clean -q -fdx
apply_series "$spvc" "$here/patches/spirv-cross"

# --- MoltenVK + patches (External/ survives re-runs; it is rebuilt when its inputs change)
fetch_pinned "$src" "$MVK_REPO" "$MVK_COMMIT"
test "$(cat "$src/ExternalRevisions/SPIRV-Cross_repo_revision")" = "$SPVC_COMMIT"
git -C "$src" clean -q -fdx -e /External
apply_series "$src" "$here/patches/moltenvk"

# --- external dependencies (SPIRV-Cross, SPIRV-Tools, Vulkan-Headers, ... -> xcframeworks)
deps_key=$(cat "$src/ExternalRevisions/"* "$here"/patches/spirv-cross/*.patch | shasum -a 256 | cut -d' ' -f1)
deps_stamp=$src/External/.steamac-deps
if [ "$(cat "$deps_stamp" 2> /dev/null)" != "$deps_key" ]; then
	rm -f "$deps_stamp"
	# Same environment scrub as UTM (env -i): no Homebrew/SDK variables leak into xcodebuild.
	(cd "$src" && env -i PATH="$PATH" HOME="$HOME" LANG="${LANG:-en_US.UTF-8}" \
		./fetchDependencies --macos --spirv-cross-root "$spvc")
	echo "$deps_key" > "$deps_stamp"
fi

# --- MoltenVK (Release, universal)
(cd "$src" && env -i PATH="$PATH" HOME="$HOME" LANG="${LANG:-en_US.UTF-8}" make macos)

pkg=$src/Package/Release/MoltenVK
built=$pkg/dynamic/dylib/macOS

# --- stage
stage=$work/stage
rm -rf "$stage"
mkdir -p "$stage/lib"
staged=$stage/lib/libMoltenVK.dylib
lipo "$built/libMoltenVK.dylib" -thin arm64 -output "$staged"
test "$(otool -D "$staged" | sed -n 2p)" = "@rpath/libMoltenVK.dylib"
codesign --force -s - "$staged"

# --- probe (links the staged dylib directly, like virglrenderer)
probe=$work/probe
xcrun clang -std=c11 -Wall -Werror -O1 -I"$pkg/include" "$here/probe/probe.c" \
	-L"$stage/lib" -lMoltenVK -Wl,-rpath,"$stage/lib" -o "$probe"
echo ">> probe: $staged"
probe_log=$work/probe.log
MVK_CONFIG_LOG_LEVEL=1 "$probe" > "$probe_log" 2>&1 || { cat "$probe_log"; exit 1; }
cat "$probe_log"
# MoltenVK validates its shader-cache (cereal) archive layouts at vkCreateInstance and prints
# [MVK-BUILD-ERROR] when a patch changed a serialized struct without updating it.
if grep -q 'MVK-BUILD-ERROR' "$probe_log"; then
	echo "probe: MoltenVK reported a build error (see above)" >&2
	exit 1
fi

# --- repros: gamescope compute pipelines, geometry shaders, null pipeline binds
echo ">> repro: gamescope compute pipelines, geometry shaders, null pipeline binds"
repro_log=$work/repro.log
"$here/repro/run.sh" "$stage/lib" > "$repro_log" 2>&1 || { cat "$repro_log"; exit 1; }
grep -v '^\[mvk-info\]\|^	' "$repro_log"

# --- install (temp + rename, never rewrite a mapped dylib in place)
mkdir -p "$out/lib" "$out/share/vulkan/icd.d" "$out/include"
lib=$out/lib/libMoltenVK.dylib
cp "$staged" "$lib.tmp.$$"
mv -f "$lib.tmp.$$" "$lib"

icd=$out/share/vulkan/icd.d/MoltenVK_icd.json
sed 's#"library_path"[[:space:]]*:[[:space:]]*"[^"]*"#"library_path": "../../../lib/libMoltenVK.dylib"#' \
	"$built/MoltenVK_icd.json" > "$icd.tmp.$$"
grep -q '"library_path": "../../../lib/libMoltenVK.dylib"' "$icd.tmp.$$"
mv -f "$icd.tmp.$$" "$icd"

rm -rf "$out/include/MoltenVK.tmp.$$"
cp -R "$pkg/include/MoltenVK" "$out/include/MoltenVK.tmp.$$"
rm -rf "$out/include/MoltenVK"
mv "$out/include/MoltenVK.tmp.$$" "$out/include/MoltenVK"

# --- provenance
mvk_version=$(sed -n 's/.*"api_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$built/MoltenVK_icd.json")
{
	echo "MoltenVK for steamac (host Venus renderer)"
	echo
	echo "source:       $MVK_REPO"
	echo "branch:       $MVK_BRANCH"
	echo "commit:       $MVK_COMMIT  (UTM's pin; utmapp/MoltenVK = v1.4.1 + 16 commits)"
	echo "SPIRV-Cross:  $SPVC_REPO @ $SPVC_COMMIT"
	echo "ICD api_version: $mvk_version"
	echo "Xcode:        $(xcodebuild -version | tr '\n' ' ')"
	echo "built:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo
	echo "Fork features (05604465): geometry shaders via Metal mesh shaders (no GS with"
	echo "  indirect draws), robustness2 robustBufferAccess2/robustImageAccess2/nullDescriptor,"
	echo "  shaderCullDistance (flag only, no culling), VK_EXT_transform_feedback (1 buffer,"
	echo "  geometryStreams faked, no transformFeedbackQueries); host-pointer imports on"
	echo "  non-host-visible memory types (osy, upstreamed as MoltenVK PR #2834)."
	echo
	echo "MoltenVK patches (host/moltenvk/patches/moltenvk):"
	for p in "$here"/patches/moltenvk/*.patch; do echo "  $(basename "$p")"; done
	echo "  0001 = KhronosGroup/MoltenVK 74850136 (reversed-depth viewport emulation;"
	echo "         prerequisite of 0002, only active on AMD Mac2 GPUs)"
	echo "  0002 = KhronosGroup/MoltenVK PR #2712 dc89e437 (VK_EXT_depth_clip_enable, conformant"
	echo "         KosmicKrisp-style emulation); Metal OpenGL-mode compensation dropped, GS stages"
	echo "         excluded from depth-clip emulation (see patch header)"
	echo "  0003 = steamac: Y'CbCr immutable-sampler arrays got the SUM of the samplers' plane counts"
	echo "         (16 NV12 samplers -> 32 'planes' -> Tex3SampSoA) instead of the maximum; broke"
	echo "         gamescope's s_ycbcr_samplers[16] (same bug in KhronosGroup/MoltenVK main)"
	echo "  0004 = steamac: nullDescriptor -> image size/levels/samples queries on null descriptors"
	echo "         return 0 (was only with robustImageAccess2; Metal reports 1 mip level for nil)"
	echo "  0005 = steamac: vkCmdBindPipeline(VK_NULL_HANDLE) (Venus replays it when host pipeline"
	echo "         creation failed) skips draws/dispatches instead of crashing the process"
	echo "  0006 = steamac: GS draw info (list/strip) was passed to Metal before it was filled in"
	echo "  0007 = steamac: geometry shaders on line lists / line strips (was 'Unsupported topology')"
	echo "  0008 = steamac: indirect and indexed-indirect draws with geometry shaders (GPU conversion"
	echo "         to mesh threadgroups), firstVertex/vertexOffset/firstInstance for GS draws"
	echo "  0009 = upstream 2da7c3cb: linear color formats renderable again on Apple GPUs (the fork"
	echo "         read renderLinearTextures before it was initialised: linear tiling lost"
	echo "         COLOR_ATTACHMENT/BLEND/BLIT_DST, breaking zink rendering into linear dma-bufs)"
	echo "  0010 = steamac: depth/stencil formats no longer report HOST_IMAGE_TRANSFER (their images"
	echo "         need private memory; with HOST_TRANSFER memoryTypeBits was 0, so zink could not"
	echo "         allocate any depth/stencil renderbuffer: GL FBOs incomplete, CEF/Skia no stencil)"
	echo "  0011 = steamac: GS object stage fetches vertices with the bound (dynamic) strides; zink's"
	echo "         provoking-vertex GS on every draw with dynamic stride read vertex 0 (all black)"
	echo "  0012 = steamac: LINEAR images use the row pitch of a chained"
	echo "         VkImageDrmFormatModifierExplicitCreateInfoEXT (virglrenderer dma-buf imports)"
	echo "  0013 = steamac: GS with *_WITH_ADJACENCY topologies (zink GL_QUADS: second triangle was"
	echo "         missing) and per-instance vertex attributes (glamor instanced rectangles)"
	echo "  0014 = steamac: GS input primitive from the shader (dynamic topology: zink pipelines with a"
	echo "         static TRIANGLE_FAN failed), triangle fans assembled by the GS object stage"
	echo "  0015 = steamac: GS object stage vertex attributes read with their memory type (SCALED/NORM"
	echo "         formats such as glamor's R16G16_SSCALED were read as float bits)"
	echo "SPIRV-Cross patches (host/moltenvk/patches/spirv-cross):"
	for p in "$here"/patches/spirv-cross/*.patch; do echo "  $(basename "$p")"; done
	echo "  0001/0002 = KhronosGroup/SPIRV-Cross 35f52882+da223760 and 0706157e (PR #2666), library only"
	echo "  0003 = steamac: arrays of Y'CbCr combined image-samplers with argument buffers (plane"
	echo "         indexes, plane/sampler expressions for array elements, spvDynamicImageSampler for"
	echo "         elements passed to functions, padding of multiplanar bindings, constant gather"
	echo "         component); needed by gamescope's compute shaders"
	echo "  0004 = steamac: MSL option null_descriptor (zero image queries on nil textures)"
	echo "  0005 = steamac: gl_PrimitiveIDIn / gl_PrimitiveID in the mesh-emulated geometry stage"
	echo "         (zink's passthrough GS failed to compile)"
	echo "  0006 = steamac: GS input primitive assembly (list primitives > 0 read wrong vertices;"
	echo "         strip winding)"
	echo "  0007 = steamac: robustBufferAccess2 on arrays of uniform/storage buffers (zink UBO arrays"
	echo "         did not compile), interface blocks no longer treated as buffers, GS wrappers pass"
	echo "         arrays of discrete buffers per element"
	echo "  0008 = steamac: variables named 'sampler'/'array' (MSL type names) are renamed (glamor)"
	echo "  0009 = steamac: base vertex / base instance in the GS object stage"
	echo "  0010 = steamac: an input builtin declared by several variables (zink gl_PrimitiveIDIn)"
	echo "         becomes one entry point argument"
	echo "  0011 = steamac: GS object stage vertex strides come from DrawInfo (dynamic strides)"
	echo "  0012 = steamac: vertex->geometry payload by builtin/location (GS may read any subset of"
	echo "         the vertex outputs; gl_in[] block inputs of glslang/DXVK geometry shaders work)"
	echo "  0013 = steamac: adjacency input topologies (incl. triangle-strip-adjacency vertex order)"
	echo "         and instance-rate attribute fetch in the GS object stage"
	echo "  0014 = steamac: triangle fans in the GS object stage"
	echo "  0015 = steamac: GS object stage vertex attribute conversion (8/16-bit SCALED/NORM types,"
	echo "         SNORM normalization, fill of missing components)"
	echo
	echo "Geometry shader emulation limits: no GS instancing (Invocations > 1); B8G8R8A8 and packed"
	echo "  (2_10_10_10, 11_11_10) vertex formats are not swizzled/unpacked by the object stage; vertex outputs are"
	echo "  limited to 32 locations, 8 clip and 8 cull distances; indirect GS draws are converted on"
	echo "  the GPU but drawCount comes from the CPU (no vkCmdDrawIndirectCount with GS)."
	echo
	echo "Not included: KhronosGroup/MoltenVK PR #2812 (indexed/indirect GS mesh draws). It is part of"
	echo "  a different geometry-shader implementation (stacked on PR #2786, rebase of #1815/#1943 with"
	echo "  its own SPIRV-Cross fork) and does not apply to the utmapp geometry-shaders branch;"
	echo "  steamac patch 0008 implements indirect GS draws for this branch instead."
	echo
	echo "Build: ./fetchDependencies --macos --spirv-cross-root <patched SPIRV-Cross>;"
	echo "  make macos; lipo -thin arm64 (UTM's recipe)."
	echo "Metal private API: OFF (MVK_USE_METAL_PRIVATE_API not set, like UTM/Homebrew), so logicOp,"
	echo "  wideLines, primitive-restart control and provoking-vertex-last are unavailable. Enabling it"
	echo "  fails to compile on this fork: the geometry-shader mesh pipeline path sets"
	echo "  logicOperationEnabledMVK/logicOperationMVK/sampleMaskMVK on MTLMeshRenderPipelineDescriptor,"
	echo "  which MoltenVK's private-API category only declares for MTLRenderPipelineDescriptor."
	echo
	echo "Probe (host/moltenvk/probe, $(sysctl -n machdep.cpu.brand_string), macOS $(sw_vers -productVersion)):"
	sed 's/^/  /' "$probe_log"
	echo
	echo "Repros (host/moltenvk/repro, Metal argument buffers on):"
	grep -v '^\[mvk-info\]\|^	' "$repro_log" | sed 's/^/  /'
} > "$out/MOLTENVK.txt"

echo ">> $lib"
otool -L "$lib"
