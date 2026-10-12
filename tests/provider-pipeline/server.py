"""Mock OpenAI-compatible endpoint plus a second listener that records what reaches it.

usage: server.py PORTS_FILE
Binds two free loopback ports and writes {"main": A, "capture": B} to PORTS_FILE
once both are listening. `main` answers plans; a body containing "redirect"
makes it answer 307 to the capture listener (another host name / port), and
"redirect-same" to another path on itself. `capture` records every request it
receives; GET /seen returns them as JSON.
"""
import json, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer

PLAN = {"summary": "3.2 GB can go", "items": [
    {"title": "npm cache", "detail": "Caches", "group": "safe", "bytes": 1500000000,
     "paths": ["~/Library/Caches/npm"], "action": "trash", "command": ""},
    {"title": "brew cleanup", "detail": "Old versions", "group": "safe", "bytes": 300000000,
     "paths": [], "action": "command", "command": "brew cleanup"}]}

SEEN = []
PORTS = {}


class Capture(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def record(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        if self.command == "GET" and self.path == "/seen":
            out = json.dumps(SEEN).encode()
        else:
            SEEN.append({"method": self.command, "path": self.path,
                         "headers": {k.lower(): v for k, v in self.headers.items()}, "body": body})
            out = b"{}"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    do_GET = do_POST = do_PUT = record


class Main(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def redirect(self, location):
        self.send_response(307)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        # Model-list requests: redirect on demand, else a one-model list.
        if self.path.startswith("/redirect"):
            self.redirect("http://localhost.:%d/captured" % PORTS["capture"])
            return
        out = json.dumps({"data": [{"id": "m"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"])).decode()
        if self.path.startswith("/same/"):
            pass  # reached after a same-origin redirect: answer like any other
        elif "redirect-same" in body:
            self.redirect("/same/v1/chat/completions")
            return
        elif "redirect-port" in body:
            self.redirect("http://127.0.0.1:%d/captured" % PORTS["capture"])
            return
        elif "redirect" in body:
            self.redirect("http://localhost.:%d/captured" % PORTS["capture"])
            return
        if "401" in body:
            self.send_response(401)
            self.send_header("Content-Length", str(len('{"error":{"message":"bad key"}}')))
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"bad key"}}')
            return
        content = json.dumps(PLAN)
        if "fenced" in body:
            content = "Here is the plan:\n```json\n" + content + "\n```"
        if "plain" in body:
            out = json.dumps({"choices": [{"message": {"content": content}}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers(); self.wfile.write(out)
            return
        # SSE: two deltas so partial items stream first
        mid = len(content) // 2
        out = b""
        for part in (content[:mid], content[mid:]):
            out += b"data: " + json.dumps({"choices": [{"delta": {"content": part}}]}).encode() + b"\n\n"
        out += b"data: [DONE]\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers(); self.wfile.write(out)


main = HTTPServer(("127.0.0.1", 0), Main)
capture = HTTPServer(("127.0.0.1", 0), Capture)
PORTS["main"] = main.server_address[1]
PORTS["capture"] = capture.server_address[1]
for s in (main, capture):
    threading.Thread(target=s.serve_forever, daemon=True).start()
with open(sys.argv[1] + ".tmp", "w") as f:
    json.dump(PORTS, f)
os.replace(sys.argv[1] + ".tmp", sys.argv[1])
while True:
    time.sleep(1)
