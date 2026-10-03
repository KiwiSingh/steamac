#!/bin/sh
# Live display resize check on a clone of the guest disk (needs host/libkrun/build.sh output
# and the work/out guest images). Boots the guest headless with test/resize.c, waits for the
# Steam UI, then walks through display sizes at a constant 96 DPI (krun_display_resize)
# and records for each: the guest connector modes, the X screen size gamescope gives
# Steam (xrandr), gamescope's mode switches, and a frame dump.
#
#   host/libkrun/test/resize-test.sh [OUTDIR]   (default work/scratch/resize-test)
#
# Env: SSH_PORT (default 2230), SIZES ("1600x1000 1024x640"), BOOT_WAIT (s, default 600),
# SETTLE (s after each resize, default 20), KEEP_CLONE=1 keeps the cloned disk.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
out=$root/work/out
dir=${1:-$root/work/scratch/resize-test}
port=${SSH_PORT:-2230}
sizes=${SIZES:-1600x1000 1024x640}
boot_wait=${BOOT_WAIT:-600}
settle=${SETTLE:-20}

mkdir -p "$dir"
run=$(mktemp -d /tmp/krun-resize.XXXXXX)
clone=$dir/steamos.img
bin=$root/work/build/host-libkrun/resize

clang -std=c11 -Wall -Wextra -Werror -o "$bin" "$here/resize.c" \
	-I"$out/host/include" -L"$out/host/lib" -lkrun -Wl,-rpath,"$out/host/lib" \
	-framework CoreFoundation -framework CoreGraphics -framework ImageIO
codesign --force -s - --entitlements "$here/hypervisor.entitlements" "$bin"

rm -f "$clone"
cp -c "$out/steamos.img" "$clone"

vm_pid=
gv_pid=
cleanup() {
	[ -n "$vm_pid" ] && kill "$vm_pid" 2> /dev/null || true
	[ -n "$gv_pid" ] && kill "$gv_pid" 2> /dev/null || true
	wait 2> /dev/null || true
	rm -rf "$run"
	[ "${KEEP_CLONE:-0}" = 1 ] || rm -f "$clone"
}
trap cleanup EXIT INT TERM

"$out/host/bin/gvproxy" -listen-vfkit "unixgram://$run/net.sock" -listen "unix://$run/api.sock" \
	-ssh-port "$port" -log-file "$run/gvproxy.log" > /dev/null 2>&1 &
gv_pid=$!
while [ ! -S "$run/net.sock" ]; do sleep 0.1; done

mkfifo "$run/control"
: > "$dir/console.log"
"$bin" --kernel "$out/Image" --initrd "$out/initramfs.cpio.gz" \
	--disk "$clone" --disk "$out/steamac-layer.img:ro" --net "$run/net.sock" \
	--console "$dir/console.log" --control "$run/control" --size 1280x800 --mm 339x212 \
	2> "$dir/harness.log" &
vm_pid=$!
exec 3> "$run/control"

g() {
	sshpass -p steamos ssh -q -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o ConnectTimeout=5 steamos@127.0.0.1 "$@"
}

# The X display gamescope gives Steam, and its auth file, from the Steam process.
xenv='pid=$(pgrep -u steamos -x steam | head -1);
	eval "$(tr "\0" "\n" < /proc/$pid/environ | grep -E "^(DISPLAY|XAUTHORITY)=" | sed "s/^/export /")"'

report() { # label
	{
		echo "=== $1"
		echo "--- /sys/class/drm/card0-Virtual-1/modes (first 3)"
		g 'head -3 /sys/class/drm/card0-Virtual-1/modes'
		echo "--- xrandr (Steam's X display)"
		g "$xenv; xrandr --current 2>&1 | head -4"
		echo "--- gamescope mode selection"
		g 'echo steamos | sudo -S -p "" journalctl -b --no-pager -o short-monotonic 2>/dev/null |
			grep -E "drm: (selecting mode|selecting connector)|Got change event for KMS" | tail -6'
	} >> "$dir/report.txt" 2>&1
	echo "dump $dir/$1.png" >&3
	sleep 2
}

echo "waiting for the Steam UI (up to ${boot_wait}s)"
t=0
until g "$xenv"' && [ -n "$DISPLAY" ] && pgrep -u steamos -f steamwebhelper > /dev/null' 2> /dev/null; do
	sleep 10
	t=$((t + 10))
	kill -0 "$vm_pid" || { echo "VM exited"; exit 1; }
	[ "$t" -lt "$boot_wait" ] || { echo "no Steam UI after ${boot_wait}s"; exit 1; }
done
sleep 60 # Steam UI load
: > "$dir/report.txt"
report 1280x800

for s in $sizes; do
	w=${s%x*} h=${s#*x}
	# constant DPI: 96 px per inch
	wmm=$(((w * 254 + 480) / 960)) hmm=$(((h * 254 + 480) / 960))
	echo "resize $w $h $wmm $hmm" >&3
	sleep "$settle"
	report "$s"
done

cat "$dir/report.txt"
grep -E "configure_scanout|krun_display_resize|dump" "$dir/harness.log"
g 'echo steamos | sudo -S -p "" systemctl poweroff' > /dev/null 2>&1 || true
for _ in $(seq 60); do kill -0 "$vm_pid" 2> /dev/null || break; sleep 1; done
