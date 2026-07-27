#!/usr/bin/env python3
# Test double for api.anthropic.com plus the OAuth token endpoint, used by
# test/proxy.bats and test/runtime.bats. Binds an ephemeral 127.0.0.1 port
# and prints it on stdout once listening.
#   POST /v1/oauth/token -> canned refreshed-token response (counts calls,
#                           records the request body)
#   GET  /oauth-hits     -> number of refresh calls so far (text/plain)
#   GET  /oauth-last     -> JSON body of the most recent refresh request
#   *    /status-503     -> 503, body "upstream-error"
#   *    /echo-401-once  -> 401 on the first call ever, then echoes
#   GET  /sse            -> two SSE events 2s apart, no Content-Length
#   *    anything else   -> JSON echo of method/path/headers/body
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {"oauth_hits": 0, "oauth_last": {}, "returned_401": False}
LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, status, body, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _echo(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self._send(200, json.dumps({
            "method": self.command,
            "path": self.path,
            "headers": {k.lower(): v for k, v in self.headers.items()},
            "body": body.decode("utf-8", "replace"),
        }).encode())

    def _handle(self):
        if self.path == "/v1/oauth/token":
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            with LOCK:
                STATE["oauth_hits"] += 1
                STATE["oauth_last"] = req
            self._send(200, json.dumps({
                "access_token": "refreshed-access-token",
                "refresh_token": "rotated-refresh-token",
                "expires_in": 28800,
            }).encode())
        elif self.path == "/oauth-hits":
            self._send(200, str(STATE["oauth_hits"]).encode(), "text/plain")
        elif self.path == "/oauth-last":
            self._send(200, json.dumps(STATE["oauth_last"]).encode())
        elif self.path == "/status-503":
            self._send(503, b"upstream-error", "text/plain")
        elif self.path == "/echo-401-once":
            with LOCK:
                first = not STATE["returned_401"]
                STATE["returned_401"] = True
            if first:
                self._send(401, b'{"error":"token expired"}')
            else:
                self._echo()
        elif self.path == "/sse":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.close_connection = True
            self.end_headers()
            self.wfile.write(b"data: first\n\n")
            self.wfile.flush()
            time.sleep(2)
            self.wfile.write(b"data: second\n\n")
        else:
            self._echo()

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = _handle


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
