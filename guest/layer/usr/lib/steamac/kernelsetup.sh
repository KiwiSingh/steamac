#!/bin/bash
# steamac: bind-mounted by the initramfs over the booted slot's
# /boot/kernelsetup.sh (rootfs stays pristine).
#
# The stock script is the Frame "bootloader_and_firmware_update_hook": it dd's
# U-Boot / XBL / boot firmware images to the UFS LUN partitions on /dev/sdb
# (uboot_X, ubootfw_X, ubootenv_X, *_a/*_b bootfw), edits that GPT with sgdisk
# and flips the boot-firmware slot via splctl. None of that hardware exists in
# the VM: the kernel comes from the host launcher, the bootloader is our
# initramfs. steamos-finalize-install runs this file when called without
# --no-boot-install; it must succeed without touching any device.
#
# For the *newly installed* slot (post-install chroot, where this bind mount is
# absent) see /usr/lib/steamac/rauc-shims/steamos-chroot.
echo "kernelsetup: steamac VM, no bootloader/firmware to update (stock hook skipped)"
exit 0
