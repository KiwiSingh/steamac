#!/usr/bin/env python3
"""Print the mounted writable external volume containing an image/directory path."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys

try:
    path = Path(sys.argv[1]).expanduser()
    if not path.is_absolute():
        raise ValueError('Choose an absolute path on an external drive.')
    ancestor = path.resolve()
    while not ancestor.exists() and ancestor != ancestor.parent:
        ancestor = ancestor.parent
    while not os.path.ismount(ancestor) and ancestor != ancestor.parent:
        ancestor = ancestor.parent
    info = plistlib.loads(subprocess.check_output(['diskutil', 'info', '-plist', str(ancestor)]))
    mount = info.get('MountPoint', '')
    if (info.get('Internal') is not False or not mount.startswith('/Volumes/')
            or mount != str(ancestor) or not info.get('Writable')
            or not os.access(mount, os.W_OK)):
        raise ValueError('Choose a mounted, writable external drive; internal storage is not used.')
    print(mount)
except (ValueError, OSError, subprocess.CalledProcessError, plistlib.InvalidFileException, IndexError) as error:
    sys.exit(str(error))
