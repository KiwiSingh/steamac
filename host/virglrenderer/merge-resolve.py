#!/usr/bin/env python3
"""Resolve the conflicts of merging upstream virglrenderer main (UPSTREAM_COMMIT in
build.sh) into UTM's fork (COMMIT). Run in the source tree after a conflicted `git merge`.

- meson.build: the fork's vtest option, which upstream additionally gates on vrend.
- src/meson.build: both source lists (fork: vrend/vrend_metal.m, upstream:
  vrend/vrend_venus_interop.c).
- vrend_renderer.h / vrend_winsys_egl.h: both sides' new declarations.
- src/venus/vkr_metal_helpers.m: deleted by the fork (5d26f605 imports shm with
  VK_EXT_external_memory_host and drops the Objective-C helper), only touched by upstream.
"""
import re
import subprocess
import sys

RESOLUTIONS = {
    "meson.build": lambda ours, theirs: (
        "with_vtest = get_option('vtest') and with_vrend and not with_host_windows\n"
        "if with_vtest\n"
    ),
    "src/meson.build": lambda ours, theirs: ours + "]\n\n" + theirs,
    "src/vrend/vrend_renderer.h": lambda ours, theirs: ours + "\n" + theirs,
    "src/vrend/vrend_winsys_egl.h": lambda ours, theirs: ours + theirs,
}
DELETED = ["src/venus/vkr_metal_helpers.m"]

CONFLICT = re.compile(r"<<<<<<< [^\n]*\n(.*?)=======\n(.*?)>>>>>>> [^\n]*\n", re.S)

unmerged = set(
    subprocess.run(["git", "diff", "--name-only", "--diff-filter=U"], check=True,
                   capture_output=True, text=True).stdout.split()
)
expected = set(RESOLUTIONS) | set(DELETED)
if unmerged != expected:
    sys.exit(f"unexpected conflict set: {sorted(unmerged ^ expected)}")

for path, resolve in RESOLUTIONS.items():
    text = open(path).read()
    text, count = CONFLICT.subn(lambda m: resolve(m.group(1), m.group(2)), text)
    if count != 1:
        sys.exit(f"{path}: expected 1 conflict, found {count}")
    open(path, "w").write(text)
    subprocess.run(["git", "add", path], check=True)
subprocess.run(["git", "rm", "-q", *DELETED], check=True)
