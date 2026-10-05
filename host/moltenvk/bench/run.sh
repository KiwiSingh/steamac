#!/bin/sh
# Performance of the steamac MoltenVK/SPIRV-Cross changes (bench.c), compared between MoltenVK builds.
#
#   host/moltenvk/bench/run.sh <libdir A> [<libdir B> ...]      (ROUNDS=5 by default)
#
# Each libdir holds a libMoltenVK.dylib (for example work/out/host/lib, or the work/out/host/lib of a git
# worktree of an earlier commit built with host/moltenvk/build.sh). The builds run alternately, ROUNDS
# times each; per benchmark and build the table shows the median over the rounds of the median time of a
# submit + wait in ms, the vkQueueSubmit part (MoltenVK's Metal encoding; synchronous queue submits) in
# parentheses, and each build relative to the first. Metal API validation is off. Run on an idle Mac.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
work=$root/work/build/host-moltenvk/bench
inc=$root/work/build/host-moltenvk/src/Package/Release/MoltenVK/include
rounds=${ROUNDS:-5}
[ $# -ge 1 ] || { echo "usage: $0 <libdir> [<libdir> ...]" >&2; exit 2; }

brew list --versions glslang > /dev/null 2>&1 || brew install glslang
spv=$work/spv
repro_spv=$work/repro-spv
rm -rf "$spv" "$repro_spv" "$work/results"
mkdir -p "$spv" "$repro_spv" "$work/results"
for s in "$here"/shaders/*.comp; do
	glslangValidator -V --quiet --target-env vulkan1.3 "$s" -o "$spv/$(basename "$s").spv"
done
for s in so.vert so_points.geom; do
	glslangValidator -V --quiet "$root/host/moltenvk/repro/shaders/$s" -o "$repro_spv/$s.spv"
done

i=0
for libdir in "$@"; do
	i=$((i + 1))
	xcrun clang -std=c11 -Wall -Werror -O2 -I"$inc" "$here/bench.c" \
		-L"$libdir" -lMoltenVK -Wl,-rpath,"$libdir" -o "$work/bench$i"
	echo "[$i] $libdir" >&2
done
builds=$i

r=0
while [ $r -lt "$rounds" ]; do
	r=$((r + 1))
	i=0
	while [ $i -lt "$builds" ]; do
		i=$((i + 1))
		echo ">> round $r/$rounds, build [$i]" >&2
		MVK_CONFIG_LOG_LEVEL=1 MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1 "$work/bench$i" "$spv" "$repro_spv" \
			2> "$work/results/$i.$r.log" | grep '^BENCH ' > "$work/results/$i.$r.txt"
	done
done

# Lines "BENCH name median min submit" from results/<build>.<round>.txt.
awk -v builds="$builds" '
	function median(key, cnt,    a, k, m, t) {
		for (k = 1; k <= cnt; k++) a[k] = vals[key, k]
		for (k = 2; k <= cnt; k++) for (m = k; m > 1 && a[m - 1] > a[m]; m--) { t = a[m]; a[m] = a[m - 1]; a[m - 1] = t }
		return a[int((cnt + 1) / 2)]
	}
	{
		n_parts = split(FILENAME, parts, "/")
		split(parts[n_parts], id, ".")
		b = id[1]
		name = $2
		if (!(name in seen)) { seen[name] = 1; order[++n] = name }
		if ($3 == "n/a") { na[name, b] = 1; next }
		cnt[name, b]++
		vals[name SUBSEP b SUBSEP "t", cnt[name, b]] = $3
		vals[name SUBSEP b SUBSEP "s", cnt[name, b]] = $5
	}
	END {
		printf "%-18s", "benchmark"
		for (k = 1; k <= builds; k++) printf "  %-22s", "[" k "] ms (submit)"
		for (k = 2; k <= builds; k++) printf "  %-8s", "[" k "]/[1]"
		printf "\n"
		for (j = 1; j <= n; j++) {
			name = order[j]
			printf "%-18s", name
			for (k = 1; k <= builds; k++) {
				if ((name, k) in cnt) {
					t[k] = median(name SUBSEP k SUBSEP "t", cnt[name, k])
					printf "  %-22s", sprintf("%.3f (%.3f)", t[k], median(name SUBSEP k SUBSEP "s", cnt[name, k]))
				} else {
					t[k] = -1
					printf "  %-22s", "n/a"
				}
			}
			for (k = 2; k <= builds; k++)
				if (t[1] > 0 && t[k] > 0) printf "  %-8.2f", t[k] / t[1]
				else printf "  %-8s", "-"
			printf "\n"
		}
	}' "$work"/results/*.txt
