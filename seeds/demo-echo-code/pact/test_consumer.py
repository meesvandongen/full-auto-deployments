import os
import sys
import unittest
from pathlib import Path

from pact import Pact

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app"))
from double_client import double


class ConsumerContractTests(unittest.TestCase):
    def test_echo_depends_on_double_result(self):
        pact = Pact("echo-app", "demo-app")
        (
            pact.upon_receiving("a request to double 7")
            .with_request("GET", "/api/double")
            .with_query_parameter("value", "7")
            .will_respond_with(200)
            .with_body({"result": 14}, content_type="application/json")
        )
        with pact.serve() as mock:
            self.assertEqual(double(7, str(mock.url)), 14)
        pact.write_file(Path(os.environ.get("PACT_DIR", "/tmp/pacts")))
