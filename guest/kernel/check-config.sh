#!/bin/sh
# Verify a kernel .config against the steamac requirements.
#   check-config.sh <.config> [requirements-fragment]   (default: config/20-steamac.config)
# Every assignment in the fragment must hold exactly in the .config (=y, string/int
# values, "is not set"), and no option may be built as a module (=m): the guest boots
# without any module tree. Prints one line per requirement; exits 1 on any failure.
set -eu
cfg=$1
req=${2:-$(dirname "$0")/config/20-steamac.config}
[ -f "$cfg" ] || { echo "check-config: no such file: $cfg" >&2; exit 2; }

fail=0
total=0
while IFS= read -r line; do
	case $line in
	CONFIG_*=*)
		sym=${line%%=*}
		want=${line#*=}
		got=$(grep -E "^${sym}=" "$cfg" | head -n1 | cut -d= -f2- || true)
		[ -n "$got" ] || got="(unset)"
		;;
	"# CONFIG_"*" is not set")
		sym=${line#\# }
		sym=${sym%% *}
		want="n"
		if grep -qE "^${sym}=" "$cfg"; then
			got=$(grep -E "^${sym}=" "$cfg" | head -n1 | cut -d= -f2-)
		else
			got="n"
		fi
		;;
	*) continue ;;
	esac
	total=$((total + 1))
	if [ "$got" = "$want" ]; then
		printf 'ok    %s=%s\n' "$sym" "$got"
	else
		printf 'FAIL  %s: want %s, got %s\n' "$sym" "$want" "$got"
		fail=$((fail + 1))
	fi
done < "$req"

mods=$(grep -cE '^CONFIG_[A-Za-z0-9_]+=m$' "$cfg" || true)
if [ "$mods" -ne 0 ]; then
	echo "FAIL  $mods options are =m (everything must be built in):"
	grep -E '^CONFIG_[A-Za-z0-9_]+=m$' "$cfg" | sed 's/^/      /'
	fail=$((fail + 1))
else
	echo "ok    no =m options"
fi

if [ "$fail" -ne 0 ]; then
	echo "check-config: $fail of $((total + 1)) checks FAILED ($cfg)"
	exit 1
fi
echo "check-config: all $((total + 1)) checks passed ($cfg)"
