#!/usr/bin/env python3
"""Run an existing steam-presence installation against desktop Discord IPC."""
import os
from pathlib import Path
import runpy
import stat
import sys
import time


def find_ipc(pipe=None):
    root = Path(f'/run/user/{os.getuid()}')
    roots = [Path(os.environ.get('XDG_RUNTIME_DIR', str(root))), root, root / 'nested_plasma']
    suffixes = ['', 'app/dev.vencord.Vesktop', 'app/com.discordapp.Discord',
                'app/com.discordapp.DiscordCanary', 'snap.discord']
    name = f'discord-ipc-{pipe}' if pipe is not None else 'discord-ipc-*'
    for runtime in roots:
        for suffix in suffixes:
            for candidate in sorted((runtime / suffix).glob(name)):
                try:
                    info = candidate.stat()
                    if info.st_uid == os.getuid() and stat.S_ISSOCK(info.st_mode):
                        return str(candidate)
                except OSError:
                    continue
    return None


def main():
    project = Path(sys.argv[1]).resolve()
    sys.path.insert(0, str(project))
    import pypresence.baseclient
    import pypresence.utils
    pypresence.utils.get_ipc_path = find_ipc
    pypresence.baseclient.get_ipc_path = find_ipc
    print('Waiting for Discord/Vesktop Rich Presence connection.', flush=True)
    while not find_ipc():
        time.sleep(5)
    print('Discord connection found; starting steam-presence.', flush=True)
    os.chdir(project)
    runpy.run_path(str(project / 'main.py'), run_name='__main__')


if __name__ == '__main__':
    main()
