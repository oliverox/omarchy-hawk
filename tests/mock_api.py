#!/usr/bin/env python3
"""A stand-in for both APIs hawk-status talks to.

Serves Convex's /api/query and Hyperliquid's /info from fixtures in the
FIXTURE_DIR, and records every request body to REQUEST_LOG so tests can
assert on pagination. Prints the bound port on the first line of stdout.
"""
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

FIXTURES = os.environ["FIXTURE_DIR"]
LOG = os.environ.get("REQUEST_LOG", "")


def load(name):
    with open(os.path.join(FIXTURES, name)) as f:
        return json.load(f)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(n).decode() if n else "{}"
        try:
            body = json.loads(raw)
        except Exception:
            body = {}
        if LOG:
            with open(LOG, "a") as f:
                f.write(json.dumps({"path": self.path, "body": body}) + "\n")
        if self.path == "/api/query":
            path = body.get("path", "")
            name = path.replace(":", "_") + ".json"
            if os.path.exists(os.path.join(FIXTURES, name)):
                return self._send(200, {"status": "success", "value": load(name)})
            return self._send(200, {"status": "error", "errorMessage": "no fixture " + path})
        if self.path == "/info":
            t = body.get("type", "")
            if t == "clearinghouseState":
                return self._send(200, load("clearinghouseState.json"))
            if t == "userFillsByTime":
                fills = load("fills.json")
                start = int(body.get("startTime", 0))
                page = [f for f in fills if f["time"] >= start][:2000]
                return self._send(200, page)
            return self._send(400, {"error": "unknown type"})
        self._send(404, {"error": "not found"})


srv = HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
