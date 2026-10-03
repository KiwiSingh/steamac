#!/bin/sh
# Boot work/out/Image under QEMU (TCG, arm64 "virt" with virtio-mmio devices only, like
# libkrun: no PCI) with a busybox initramfs and check that the SteamOS-relevant drivers,
# filesystems and device nodes come up. Exits 1 if any check fails.
# This validates the kernel itself, not libkrun/HVF specifics (16K host pages, hv_gic).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
IMAGE=steamac-kernel-smoke:trixie

[ -f "$root/work/out/Image" ] || { echo "smoke-test: build work/out/Image first" >&2; exit 2; }
docker build --platform linux/arm64 -q -t "$IMAGE" "$here/smoke" > /dev/null

log=$root/work/out/kernel-smoke.log
docker run --rm --platform linux/arm64 \
	-v "$root/work/out/Image":/Image:ro \
	-v "$here/smoke/init":/smoke-init:ro \
	"$IMAGE" sh -euc '
		mkdir -p /ir/bin && cp /bin/busybox /ir/bin/busybox && cp /smoke-init /ir/init
		(cd /ir && find . | cpio -o -H newc --quiet | gzip -9) > /initramfs.cpio.gz
		timeout 600 qemu-system-aarch64 -M virt,gic-version=3 -cpu max,pauth-impdef=on \
			-smp 4 -m 2048 -nographic -no-reboot -global virtio-mmio.force-legacy=false \
			-kernel /Image -initrd /initramfs.cpio.gz \
			-append "console=ttyAMA0 loglevel=6 rdinit=/init panic=-1" \
			-device virtio-gpu-device -device virtio-keyboard-device \
			-device virtio-mouse-device -device virtio-rng-device \
			-device virtio-balloon-device \
			-netdev user,id=n0 -device virtio-net-device,netdev=n0
	' | tee "$log"

grep -q '^SMOKE done' "$log" || { echo "smoke-test: guest did not finish" >&2; exit 1; }
if grep -q '^SMOKE FAIL' "$log"; then
	echo "smoke-test: FAILED checks:" >&2
	grep '^SMOKE FAIL' "$log" >&2
	exit 1
fi
echo "smoke-test: all checks passed ($(grep -c '^SMOKE ok' "$log") ok)"
