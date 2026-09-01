#!/usr/bin/env python3
"""Mock of the 17track v2.2 API for end-to-end engine testing.

Run `python3 test/mock17track.py`, then temporarily point the two
api.17track.net URLs in ProviderRegistry.js at http://127.0.0.1:8765
(register first, then gettrackinfo returns in-transit, then delivered).
Requests are logged to /tmp/mock17track-requests.log.
"""
import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

CALLS = {"gettrackinfo": 0}

IN_TRANSIT = {
    "code": 0,
    "data": {
        "accepted": [{
            "number": "RB123456789DE",
            "track": {
                "e": 10,
                "z0": [
                    {"a": "2026-08-28 09:12", "c": "Hamburg", "z": "Shipment picked up"},
                    {"a": "2026-08-29 14:30", "c": "Frankfurt", "z": "Departed facility"}
                ],
                "z1": [
                    {"a": "2026-08-30 08:05", "c": "New York, NY", "z": "Arrived at sort facility"},
                    {"a": "2026-08-30 19:44", "c": "Brooklyn, NY", "z": "In transit to destination"}
                ]
            }
        }],
        "rejected": []
    }
}

DELIVERED = {
    "code": 0,
    "data": {
        "accepted": [{
            "number": "RB123456789DE",
            "track": {
                "e": 40,
                "z0": [],
                "z1": [
                    {"a": "2026-08-30 19:44", "c": "Brooklyn, NY", "z": "In transit to destination"},
                    {"a": "2026-08-31 09:02", "c": "Brooklyn, NY", "z": "Out for delivery"},
                    {"a": "2026-08-31 11:37", "c": "Brooklyn, NY", "z": "Delivered - Left at front door"}
                ]
            }
        }],
        "rejected": []
    }
}

REGISTER_OK = {"code": 0, "data": {"accepted": [{"number": "RB123456789DE"}], "rejected": []}}
REGISTER_EXISTS = {
    "code": 0,
    "data": {"accepted": [], "rejected": [{"number": "RB123456789DE", "error_code": -18019901, "error_message": "The tracking number has been registered"}]}
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", "replace")
        auth = self.headers.get("17token", "")
        with open("/tmp/mock17track-requests.log", "a") as f:
            f.write(json.dumps({"path": self.path, "token": auth, "body": body}) + "\n")

        if "register" in self.path:
            resp = REGISTER_EXISTS if CALLS["gettrackinfo"] > 0 else REGISTER_OK
        else:
            CALLS["gettrackinfo"] += 1
            resp = DELIVERED if CALLS["gettrackinfo"] > 1 else IN_TRANSIT

        payload = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
