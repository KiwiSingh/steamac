#!/usr/bin/env python3
"""Smoke checks without creating a disk or booting a VM. Run from any directory."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
(root / "work").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(dir=root / "work", prefix="fork-check-") as tmp:
    t = Path(tmp)
    env = dict(os.environ, TMPDIR=str(t))
    for name in ("build.sh", "run.sh", "scripts/build-image.sh", "scripts/steps/40-disk.sh",
                 "scripts/steps/50-check.sh", "host/kosmickrisp/build.sh",
                 "host/virglrenderer/build.sh", "host/launcher/build.sh", "host/launcher/bundle.sh"):
        subprocess.run(["bash", "-n", str(root / name)], env=env, check=True)
    (t / "work/out").mkdir(parents=True)
    (t / "scripts").mkdir()
    (t / "bin").mkdir()
    shutil.copy(root / "run.sh", t / "run.sh")
    shutil.copy(root / "scripts/build-image.sh", t / "scripts/build-image.sh")
    shutil.copy(root / "scripts/config.env", t / "scripts/config.env")
    printer = '#!/bin/bash\nprintf "%s\\n" "$@"\n'
    for p in (t / "work/out/steamac-vm", t / "bin/docker"):
        p.write_text(printer)
        p.chmod(0o755)
    df = t / "bin/df"
    df.write_text('#!/bin/bash\nprintf "Filesystem Blocks Used Available Capacity Mounted\\n/dev/mock 100 1 99 1%% /Volumes/Zweidrive\\n"\n')
    df.chmod(0o755)
    env["PATH"] = str(t / "bin") + ":" + env["PATH"]
    args = subprocess.check_output(["bash", str(t / "run.sh")], env=env, text=True).splitlines()
    assert "/Volumes/Zweidrive/steamac/steamos.img" in args
    custom = str(t / "custom disk.img")
    env["STEAMAC_DISK_PATH"] = custom
    args = subprocess.check_output(["bash", str(t / "run.sh")], env=env, text=True).splitlines()
    assert custom in args
    env["STEAMAC_DISK_DIR"] = str(t / "disk directory")
    args = subprocess.check_output(["bash", str(t / "scripts/build-image.sh"), "disk", "check"], env=env, text=True).splitlines()
    assert args.count(env["STEAMAC_DISK_DIR"] + ":/disk") == 2
    assert args.count("STEAMAC_DISK_DIR=/disk") == 2
    df.write_text('#!/bin/bash\nprintf "Filesystem Blocks Used Available Capacity Mounted\\n/dev/mock 100 1 99 1%% /\\n"\n')
    assert subprocess.run(["bash", str(t / "run.sh")], env=env, capture_output=True).returncode != 0
    assert subprocess.run(["bash", str(t / "scripts/build-image.sh"), "disk"], env=env, capture_output=True).returncode != 0
print("PASS shell syntax, external image defaults/overrides, container mounts, missing-volume refusal")
