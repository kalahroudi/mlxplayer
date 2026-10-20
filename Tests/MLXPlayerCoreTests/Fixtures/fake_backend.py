"""Stands in for mlx_lm.server in tests: /v1/models, plain and streaming chat completions."""
import json, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, *a): pass
    def do_GET(self):
        body = json.dumps({"object": "list", "data": [{"id": "fake"}]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(n) or b"{}")
        if req.get("stream"):
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
            n = min(int(req.get("max_tokens", 5)), 40)
            for i in range(n):
                self.wfile.write(f'data: {{"choices":[{{"delta":{{"content":"t{i}"}}}}]}}\n\n'.encode()); self.wfile.flush()
                time.sleep(0.05 if n <= 5 else 0.02)
            opts = req.get("stream_options") or {}
            if opts.get("include_usage"):
                self.wfile.write(b'data: {"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":5}}\n\n')
            self.wfile.write(b"data: [DONE]\n\n")
        else:
            body = json.dumps({"choices": [{"message": {"content": "hello"}}],
                               "usage": {"prompt_tokens": 3, "completion_tokens": 2}}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
