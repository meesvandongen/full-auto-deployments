import json
import threading
import unittest
from http.server import ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import urlopen
from unittest.mock import patch

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
    def test_api_and_probes(self):
        self.assertEqual(self.request("/api/greet?name=World"), (200, {"message": "hello World", "version": "test"}))
        self.assertEqual(self.request("/livez"), (200, {"status": "ok"}))
        self.assertEqual(self.request("/readyz"), (200, {"status": "ok"}))
        self.assertEqual(self.request("/check"), (200, {"ok": True, "version": "test"}))
        self.assertEqual(self.request("/api/greet")[0], 400)

    def test_metrics_reflect_requests(self):
        self.request("/check")
        self.request("/api/greet")
        with urlopen(f"http://127.0.0.1:{self.server.server_port}/metrics") as response:
            metrics = response.read().decode()
        self.assertIn('echo_requests_total{status="ok"} 1\n', metrics)
        self.assertIn('echo_requests_total{status="error"} 1\n', metrics)
        self.assertIn('echo_check_success{version="test"} 1\n', metrics)

    def test_greeting_with_double_calls_provider(self):
        with patch("server.double", return_value=14) as request_double:
            self.assertEqual(
                self.request("/api/greet?name=World&value=7"),
                (200, {"message": "hello World", "version": "test", "doubled": 14}),
            )
        request_double.assert_called_once_with(7, "http://demo-app.demo-dev.svc.cluster.local")

    def test_provider_failure_is_reported(self):
        with patch("server.double", side_effect=ValueError("invalid response")):
            self.assertEqual(
                self.request("/api/greet?name=World&value=7"),
                (502, {"error": "Double provider unavailable"}),
            )
        self.assertEqual(self.request("/api/greet?name=World&value=bad")[0], 400)
        self.assertEqual(self.request("/api/greet?name=World&value=")[0], 400)


class FaultyServerTests(ServerTests):
    def faulty(self):
        return True

    def test_fault_is_detectable_while_ready(self):
        self.assertEqual(self.request("/readyz")[0], 200)
        self.assertEqual(self.request("/api/greet?name=World")[1]["message"], "hello World!")
        self.assertEqual(self.request("/check"), (200, {"ok": False, "version": "test"}))
        with urlopen(f"http://127.0.0.1:{self.server.server_port}/metrics") as response:
            self.assertIn('echo_check_success{version="test"} 0\n', response.read().decode())
