import json
import logging
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock
from urllib.parse import parse_qs, urlsplit


VERSION = os.environ.get("APP_VERSION", "local")
FAULT_MODE = os.environ.get("FAULT_MODE") == "1"
logging.basicConfig(level=logging.INFO, format="%(message)s")


def greet(name, faulty=False):
    return f"hello {name}" + ("!" if faulty else "")


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
                body = {"ok": greet("World", faulty) == "hello World", "version": version}
            elif path.path == "/api/greet":
                names = parse_qs(path.query).get("name", [])
                if not names or not names[0].strip():
                    status = 400
                    body = {"error": "name is required"}
                else:
                    body = {"message": greet(names[0], faulty), "version": version}
            elif path.path == "/metrics":
                with lock:
                    lines = [
                        "# TYPE echo_requests_total counter",
                        f'echo_requests_total{{status="ok"}} {counts["ok"]}',
                        f'echo_requests_total{{status="error"}} {counts["error"]}',
                        "# TYPE echo_check_success gauge",
                        f"echo_check_success{{version={json.dumps(version)}}} "
                        f'{int(greet("World", faulty) == "hello World")}',
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
