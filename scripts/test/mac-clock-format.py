#!/usr/bin/env python3
"""Host-side parser/ownership checks; VM coverage also requires real Steam files."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[2] / "guest/layer/usr/lib/steamac/mac-clock-format"
loader = importlib.machinery.SourceFileLoader("mac_clock_format", str(path))
spec = importlib.util.spec_from_loader(loader.name, loader)
clock = importlib.util.module_from_spec(spec)
loader.exec_module(clock)
KEY = ("UserLocalConfigStore", "Software", "Valve", "Steam", "FriendsUI", "FriendsUIJSON")


class ClockFormatTests(unittest.TestCase):
    def test_missing_containers(self):
        for depth in range(1, len(KEY)):
            text = "".join('"' + k + '"\n{\n' for k in KEY[:depth]) + '"Unrelated" "keep"\n' + "}\n" * depth
            changed = clock.vdf_set(text, KEY, '{"b24HourClock":true}')
            values, _ = clock.vdf_entries(changed)
            self.assertEqual(json.loads(values[tuple(k.lower() for k in KEY)][0]), {"b24HourClock": True})
            self.assertIn('"Unrelated" "keep"', changed)

    def test_existing_json_keeps_other_settings(self):
        prefs = {"b24HourClock": False, "name": 'quoted "name" \\ path', "other": 3}
        text = '"UserLocalConfigStore" { "Software" { "Valve" { "Steam" { "FriendsUI" { "FriendsUIJSON" ' + clock.vdf_quote(json.dumps(prefs)) + ' } } } } } // retained\n'
        values, _ = clock.vdf_entries(text)
        prefs = json.loads(values[tuple(k.lower() for k in KEY)][0])
        prefs["b24HourClock"] = True
        changed = clock.vdf_set(text, KEY, json.dumps(prefs))
        values, _ = clock.vdf_entries(changed)
        self.assertEqual(json.loads(values[tuple(k.lower() for k in KEY)][0]), prefs)
        self.assertTrue(changed.endswith('// retained\n'))

    def test_user_override_is_sticky(self):
        marker = {}
        self.assertTrue(clock.follows(marker, None))
        marker["last"] = True
        self.assertTrue(clock.follows(marker, True))
        self.assertFalse(clock.follows(marker, False))
        self.assertFalse(clock.follows(marker, True))
        self.assertTrue(marker["user"])

    def test_malformed_vdf_is_rejected(self):
        for text in ['"UserLocalConfigStore" {', '}', '"key"', '"store" { "key" }', '"store" { "key" "1" "key" "2" }']:
            with self.assertRaises(ValueError):
                clock.vdf_entries(text)


if __name__ == "__main__":
    unittest.main()
