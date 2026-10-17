#!/usr/bin/env python3
"""Unit tests for the rendezvous Store (no network).

Run with:  python3 tools/rendezvous_server/test_rendezvous.py
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from rendezvous_server import Store  # noqa: E402


class StoreTest(unittest.TestCase):
    def setUp(self) -> None:
        self.store = Store()

    def test_direct_round_trip(self) -> None:
        self.store.register({
            "code": "ABCD12", "kind": "direct", "host": "10.0.0.5", "port": 45899,
            "token": "tok", "ttl": 600, "project_id": "p", "mode": 0,
        })
        entry = self.store.lookup("abcd12")
        assert entry is not None
        self.assertEqual(entry["kind"], "direct")
        self.assertEqual(entry["host"], "10.0.0.5")
        self.assertEqual(entry["port"], 45899)

    def test_register_without_kind_is_direct(self) -> None:
        self.store.register({"code": "OLD123", "host": "1.2.3.4", "port": 1})
        entry = self.store.lookup("OLD123")
        assert entry is not None
        self.assertEqual(entry["kind"], "direct")

    def test_relay_round_trip(self) -> None:
        self.store.register({
            "code": "RELAY1", "kind": "relay", "relay_host": "relay.example.net",
            "relay_port": 45900, "room": "AB12CD", "token": "tok", "mode": 0,
        })
        entry = self.store.lookup("RELAY1")
        assert entry is not None
        self.assertEqual(entry["kind"], "relay")
        self.assertEqual(entry["relay_host"], "relay.example.net")
        self.assertEqual(entry["relay_port"], 45900)
        self.assertEqual(entry["room"], "AB12CD")

    def test_relay_requires_room_and_host(self) -> None:
        with self.assertRaises(ValueError):
            self.store.register({"code": "BADREL", "kind": "relay", "relay_host": "", "relay_port": 1, "room": "R"})
        with self.assertRaises(ValueError):
            self.store.register({"code": "BADREL", "kind": "relay", "relay_host": "h", "relay_port": 1, "room": ""})

    def test_invalid_code_rejected(self) -> None:
        with self.assertRaises(ValueError):
            self.store.register({"code": "bad!", "host": "h", "port": 1})

    def test_unregister_checks_token(self) -> None:
        self.store.register({"code": "DEL123", "host": "h", "port": 1, "token": "right"})
        self.store.unregister({"code": "DEL123", "token": "wrong"})
        self.assertIsNotNone(self.store.lookup("DEL123"))
        self.store.unregister({"code": "DEL123", "token": "right"})
        self.assertIsNone(self.store.lookup("DEL123"))


if __name__ == "__main__":
    unittest.main()
