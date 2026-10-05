#!/usr/bin/env python3
"""Check that a second real disk creator refuses to touch shared output/cache."""
import fcntl
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
binary = root / 'work/out/steamac-vm'
cache = Path('/Volumes/Zweidrive/steamac/cache')
if not binary.is_file() or not cache.is_dir():
    raise SystemExit('Build the launcher and mount Zweidrive before running this check.')
with tempfile.TemporaryDirectory(dir=root / 'work', prefix='creation-lock-check-') as tmp:
    disk = Path(tmp) / 'must-not-be-created.img'
    with (cache / 'creation.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = subprocess.run(
            [str(binary), '--create-disk', str(disk), '--no-crash-reports'],
            env=dict(os.environ, TMPDIR=tmp), capture_output=True, text=True, timeout=20,
        )
        assert result.returncode == 1, result.stdout + result.stderr
        assert 'Another Steamac disk creation is already running' in result.stderr, result.stderr
        assert not list(Path(tmp).glob('must-not-be-created.img*'))
print('PASS concurrent creator refuses before downloading or writing an image')
