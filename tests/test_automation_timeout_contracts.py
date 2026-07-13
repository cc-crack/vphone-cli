import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read_source(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


class VphonedURLTimeoutContracts(unittest.TestCase):
    def setUp(self):
        self.header = read_source("scripts/vphoned/vphoned_url.h")
        self.impl = read_source("scripts/vphoned/vphoned_url.m")

    def test_open_url_declares_hard_five_second_timeout(self):
        combined = f"{self.header}\n{self.impl}"
        self.assertRegex(
            combined,
            r"\bVPURLCommandTimeoutSeconds\b",
            "open_url must expose a named timeout contract",
        )
        self.assertRegex(
            combined,
            r"\bVPURLCommandTimeoutSeconds\s*=\s*5(?:\.0+)?\b",
            "open_url timeout must be exactly 5 seconds",
        )
        self.assertRegex(
            self.impl,
            r"dispatch_semaphore_wait\([^;]+VPURLCommandTimeoutSeconds[^;]+NSEC_PER_SEC",
            "open_url must use the named timeout as a hard wait bound",
        )

    def test_open_url_rejects_concurrent_requests_while_one_is_in_flight(self):
        self.assertRegex(
            self.impl,
            r"\burlOpenInFlight\b",
            "open_url needs an explicit in-flight guard",
        )
        self.assertRegex(
            self.impl,
            r"if\s*\(\s*urlOpenInFlight\s*\)\s*\{[\s\S]{0,500}?busy",
            "a second open_url request must receive a busy error immediately",
        )
        self.assertRegex(
            self.impl,
            r"@try\s*\{[\s\S]*?@finally\s*\{[\s\S]{0,300}?urlOpenInFlight\s*=\s*NO",
            "late LSApplicationWorkspace completion must clear the guard safely",
        )

    def test_lsapplicationworkspace_call_runs_on_dedicated_worker(self):
        self.assertRegex(
            self.impl,
            r"dispatch_queue_create\(\s*\"vphone\.vphoned\.url\.open\"",
            "LSApplicationWorkspace opens must run on a dedicated URL worker queue",
        )
        self.assertRegex(
            self.impl,
            r"dispatch_async\(\s*vp_url_open_queue\(\)[\s\S]*?objc_msgSend",
            "the private open call must be dispatched away from the guest request loop",
        )
        self.assertNotRegex(
            self.impl,
            r"\bvp_write_message\s*\(",
            "vphoned_url must return one response object, not write late responses itself",
        )


class HostControlConcurrencyContracts(unittest.TestCase):
    def setUp(self):
        self.source = read_source("sources/vphone-cli/VPhoneHostControl.swift")

    def test_accepted_clients_are_dispatched_independently(self):
        self.assertRegex(
            self.source,
            r"clientQueue\s*=\s*DispatchQueue\([^)]*attributes:\s*\.concurrent",
            "host control needs a dedicated concurrent client queue",
        )
        self.assertRegex(
            self.source,
            r"clientQueue\.async\s*\{\s*handleClient\(clientFD,\s*controller:\s*controller\)",
            "acceptLoop must hand each fd to an independent client task",
        )
        self.assertNotRegex(
            self.source,
            r"guard clientFD >= 0 else \{ break \}\s*handleClient\(clientFD",
            "acceptLoop must not process clients inline on the accept queue",
        )


if __name__ == "__main__":
    unittest.main()
