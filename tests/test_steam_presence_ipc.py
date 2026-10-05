"""Regression checks for host-visible Discord Flatpak sockets."""
import importlib.util
import os
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch

source = Path(__file__).resolve().parents[1] / 'guest/layer/usr/lib/steamac/steam-presence-runner.py'
spec = importlib.util.spec_from_file_location('presence_runner', source)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class IPCDiscoveryTests(unittest.TestCase):
    def test_flatpak_private_runtime(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as temp:
            with patch.dict(os.environ, XDG_RUNTIME_DIR=temp):
                for app in ['dev.vencord.Vesktop', 'com.discordapp.Discord', 'com.discordapp.DiscordCanary']:
                    with self.subTest(app=app):
                        directory = Path(temp) / '.flatpak' / app / 'xdg-run'
                        directory.mkdir(parents=True)
                        path = directory / 'discord-ipc-0'
                        with socket.socket(socket.AF_UNIX) as sock:
                            sock.bind(str(path))
                            self.assertEqual(runner.find_ipc(), str(path))
                            self.assertEqual(runner.find_ipc(0), str(path))
                            self.assertIsNone(runner.find_ipc(1))
                        path.unlink()
                        path.write_text('Not a socket')
                        self.assertIsNone(runner.find_ipc())
                        path.unlink()


if __name__ == '__main__':
    unittest.main()
