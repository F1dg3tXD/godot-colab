#!/usr/bin/env python3
"""Optional rendezvous service for Godot Collab.

The rendezvous maps a short invitation code (for example ``K7P2QX``) to the
direct ENet endpoint of the hosting editor. It is deliberately *not* a relay:
after resolving a code the client still connects directly to the host over UDP.

Only the Python 3 standard library is used, so it can run anywhere without
extra dependencies:

    python3 rendezvous_server.py --host 0.0.0.0 --port 9080

Endpoints
---------
POST /register
    body: {"code","host","port","token","ttl","project_id","mode"}
    -> {"ok":true,"expires":<unix-ts>}
GET  /lookup?code=XXXX
    -> {"ok":true,"host","port","token","project_id","mode","expires"}
POST /unregister
    body: {"code","token"} -> {"ok":true}
GET  /health
    -> {"ok":true}

Security notes
--------------
* Invitation codes are temporary credentials, not identities. They expire.
* Failed lookups are rate limited per source IP.
* This service stores no files and never contacts the host itself.
* Traffic is plain HTTP; run it behind TLS or on a trusted network if the
  codes must stay confidential.
"""

from __future__ import annotations

import argparse
import json
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

CODE_RE = re.compile(r"^[A-Z0-9]{4,16}$")
MAX_BODY = 4096
DEFAULT_TTL = 600
LOOKUP_WINDOW_SECONDS = 60
MAX_FAILED_LOOKUPS = 30


class Store:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._entries: dict[str, dict] = {}
        self._failures: dict[str, list[float]] = {}

    def prune(self) -> None:
        now = time.time()
        expired = [c for c, e in self._entries.items() if e["expires"] <= now]
        for code in expired:
            self._entries.pop(code, None)

    def register(self, payload: dict) -> dict:
        code = str(payload.get("code", "")).upper()
        if not CODE_RE.match(code):
            raise ValueError("invalid code format")
        host = str(payload.get("host", "")).strip()
        if not host:
            raise ValueError("missing host")
        port = int(payload.get("port", 0))
        if not (1 <= port <= 65535):
            raise ValueError("invalid port")
        ttl = int(payload.get("ttl", DEFAULT_TTL))
        ttl = max(30, min(ttl, 3600))
        with self._lock:
            self.prune()
            self._entries[code] = {
                "host": host,
                "port": port,
                "token": str(payload.get("token", "")),
                "project_id": str(payload.get("project_id", "")),
                "mode": int(payload.get("mode", 0)),
                "expires": time.time() + ttl,
            }
            return {"ok": True, "expires": int(self._entries[code]["expires"])}

    def unregister(self, payload: dict) -> dict:
        code = str(payload.get("code", "")).upper()
        token = str(payload.get("token", ""))
        with self._lock:
            entry = self._entries.get(code)
            if entry is not None and entry["token"] == token:
                self._entries.pop(code, None)
        return {"ok": True}

    def lookup(self, code: str) -> dict | None:
        code = code.upper()
        with self._lock:
            self.prune()
            entry = self._entries.get(code)
            if entry is None:
                return None
            return dict(entry)

    def note_failure(self, ip: str) -> None:
        now = time.time()
        with self._lock:
            history = [t for t in self._failures.get(ip, []) if now - t < LOOKUP_WINDOW_SECONDS]
            history.append(now)
            self._failures[ip] = history

    def is_rate_limited(self, ip: str) -> bool:
        now = time.time()
        with self._lock:
            history = [t for t in self._failures.get(ip, []) if now - t < LOOKUP_WINDOW_SECONDS]
            self._failures[ip] = history
            return len(history) >= MAX_FAILED_LOOKUPS


class Handler(BaseHTTPRequestHandler):
    store: Store = Store()
    server_version = "GodotCollabRendezvous/0.1"

    def log_message(self, fmt: str, *args) -> None:  # noqa: N802
        print("[rendezvous] %s - %s" % (self.address_string(), fmt % args))

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > MAX_BODY:
            return {}
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return {}
        return data if isinstance(data, dict) else {}

    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self._send(200, {"ok": True})
            return
        if parsed.path == "/lookup":
            ip = self.client_address[0]
            if self.store.is_rate_limited(ip):
                self._send(429, {"ok": False, "error": "rate limited"})
                return
            code = (parse_qs(parsed.query).get("code", [""])[0]).upper()
            if not CODE_RE.match(code):
                self.store.note_failure(ip)
                self._send(400, {"ok": False, "error": "invalid code"})
                return
            entry = self.store.lookup(code)
            if entry is None:
                self.store.note_failure(ip)
                self._send(404, {"ok": False, "error": "unknown or expired code"})
                return
            entry["ok"] = True
            self._send(200, entry)
            return
        self._send(404, {"ok": False, "error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        payload = self._read_json()
        try:
            if parsed.path == "/register":
                self._send(200, self.store.register(payload))
                return
            if parsed.path == "/unregister":
                self._send(200, self.store.unregister(payload))
                return
        except ValueError as exc:
            self._send(400, {"ok": False, "error": str(exc)})
            return
        self._send(404, {"ok": False, "error": "not found"})


def main() -> None:
    parser = argparse.ArgumentParser(description="Godot Collab rendezvous service")
    parser.add_argument("--host", default="127.0.0.1", help="interface to bind (default 127.0.0.1)")
    parser.add_argument("--port", type=int, default=9080, help="TCP port (default 9080)")
    args = parser.parse_args()
    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    print("[rendezvous] listening on http://%s:%d" % (args.host, args.port))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
