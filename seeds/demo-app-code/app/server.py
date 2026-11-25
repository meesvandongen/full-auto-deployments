import json
import logging
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock
from urllib.parse import parse_qs, urlsplit


VERSION = os.environ.get("APP_VERSION", "local")
FAULT_MODE = os.environ.get("FAULT_MODE") == "1"
logging.basicConfig(level=logging.INFO, format="%(message)s")


def double(value, faulty=False):
    return value * 2 + (1 if faulty else 0)


def handler(version=VERSION, faulty=FAULT_MODE):
    counts = {"ok": 0, "error": 0}
    lock = Lock()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = urlsplit(self.path)
            status = 200
            if path.path in ("/livez", "/readyz"):
                body = {"status": "ok"}
            elif path.path == "/check":
                passed = double(21, faulty) == 42
                body = {"ok": passed, "version": version}
            elif path.path == "/api/double":
                try:
                    value = int(parse_qs(path.query)["value"][0])
                except (KeyError, IndexError, ValueError):
                    status = 400
                    body = {"error": "value must be an integer"}
                else:
                    body = {"result": double(value, faulty), "version": version}
            elif path.path == "/metrics":
                with lock:
                    lines = [
                        "# TYPE demo_requests_total counter",
                        f'demo_requests_total{{status="ok"}} {counts["ok"]}',
                        f'demo_requests_total{{status="error"}} {counts["error"]}',
                        "# TYPE demo_check_success gauge",
                        f"demo_check_success{{version={json.dumps(version)}}} "
                        f"{int(double(21, faulty) == 42)}",
                    ]
                payload = ("\n".join(lines) + "\n").encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; version=0.0.4")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return
            else:
                status = 404
                body = {"error": "not found"}

            with lock:
                counts["ok" if status < 400 else "error"] += 1
            payload = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            logging.info(json.dumps({"path": path.path, "status": status, "version": version}))

        def log_message(self, format, *args):
            pass

    return Handler


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), handler()).serve_forever()
