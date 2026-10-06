#!/bin/sh
# Shader compilation cost of a game from a MoltenVK shader dump (shaders.mm: SPIR-V -> MSL, MSL -> MTLLibrary,
# pipeline states; per stage and shader kind, wall time with several threads, cold and warm).
#
#   host/moltenvk/bench/shaders.sh <dump or pack dir> [shaders.mm options: --limit N --match TEXT --math safe|fast]
#
# A pack (pack.py: a seeded 10% of the dump's pipelines and compute shaders, e.g. work/bench/packs/<game>) gives
# the same per-shader picture in a tenth of the time; most shaders of a game are variants of each other.
#
#   THREADS="1 4 8 16"  thread counts (default "1 8"): the first gets the per-shader table, the others one line
#   WARM=0              skip the warm run (same sources again, Metal's caches kept: a second run of the game)
#
# Each configuration runs in its own process with Metal's shader cache of command line tools deleted
# ($DARWIN_USER_CACHE_DIR/com.apple.metal; only a cache). Dump: run the game once with MVK_CONFIG_SHADER_DUMP_DIR
# in the launcher's environment, e.g.
#   launchctl setenv MVK_CONFIG_SHADER_DUMP_DIR "$PWD/work/scratch/mvk-dump"   (start the .app; unsetenv after)
# Uses the SPIRV-Cross library host/moltenvk/build.sh built for libMoltenVK (patched; namespace MVK_spirv_cross).
# Run on an idle Mac (quit the VM).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
work=$root/work/build/host-moltenvk/bench
spvc=$root/work/build/host-moltenvk/SPIRV-Cross
lib=$root/work/build/host-moltenvk/src/External/build/Release/SPIRVCross.xcframework/macos-arm64_x86_64/libSPIRVCross.a
threads=${THREADS:-1 8}
[ $# -ge 1 ] || { echo "usage: $0 <dump dir> [options]" >&2; exit 2; }
[ -f "$lib" ] || { echo "$lib missing: run host/moltenvk/build.sh" >&2; exit 1; }
mkdir -p "$work"
xcrun clang++ -std=c++17 -O2 -fobjc-arc -DSPIRV_CROSS_NAMESPACE_OVERRIDE=MVK_spirv_cross -I"$spvc" \
	"$here/shaders.mm" "$lib" -framework Metal -framework Foundation -o "$work/shaders"

nonce=$(date +%s)000000
first=
for t in $threads; do
	if [ -z "$first" ]; then
		first=$t
		"$work/shaders" "$@" --threads "$t" --nonce "$nonce"
		echo
	else
		"$work/shaders" "$@" --threads "$t" --nonce "$((nonce + t * 1000000000))" --summary
	fi
done
if [ "${WARM:-1}" != 0 ]; then
	# Warm: the first configuration's sources again, with the caches its run left.
	"$work/shaders" "$@" --threads "$first" --nonce "$nonce" --keep-cache --summary
fi
