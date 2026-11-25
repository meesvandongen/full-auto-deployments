import json
import threading
import unittest
from http.server import ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import urlopen

from server import handler


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler("test", self.faulty()))
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def faulty(self):
        return False

    def request(self, path):
        try:
            response = urlopen(f"http://127.0.0.1:{self.server.server_port}{path}")
        except HTTPError as error:
            response = error
        with response:
            return response.status, json.load(response)

class HealthyServerTests(ServerTests):
    def test_api_and_health(self):
        self.assertEqual(self.request("/api/double?value=21"), (200, {"result": 42, "version": "test"}))
        self.assertEqual(self.request("/livez"), (200, {"status": "ok"}))
        self.assertEqual(self.request("/readyz"), (200, {"status": "ok"}))
        self.assertEqual(self.request("/check"), (200, {"ok": True, "version": "test"}))
        self.assertEqual(self.request("/api/double?value=no")[0], 400)

    def test_metrics_reflect_requests(self):
        self.request("/check")
        self.request("/api/double?value=no")
        with urlopen(f"http://127.0.0.1:{self.server.server_port}/metrics") as response:
            metrics = response.read().decode()
        self.assertIn('demo_requests_total{status="ok"} 1\n', metrics)
        self.assertIn('demo_requests_total{status="error"} 1\n', metrics)


class FaultyServerTests(ServerTests):
    def faulty(self):
        return True

    def test_canary_fails_while_process_is_ready(self):
        self.assertEqual(self.request("/readyz")[0], 200)
        self.assertEqual(self.request("/api/double?value=21")[1]["result"], 43)
        self.assertEqual(self.request("/check"), (503, {"ok": False, "version": "test"}))
