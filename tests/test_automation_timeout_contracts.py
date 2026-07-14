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

    def test_open_url_requests_unlock_for_passwordless_automation_vm(self):
        self.assertIn("FBSOpenApplicationOptionKeyUnlockDevice", self.impl)
        self.assertRegex(
            self.impl,
            r"dlsym\([^;]+FBSOpenApplicationOptionKeyUnlockDevice",
        )
        self.assertRegex(
            self.impl,
            r"openURLSel,\s*url,\s*vp_url_open_options\(\)",
        )


class HostControlConcurrencyContracts(unittest.TestCase):
    def setUp(self):
        self.source = read_source("sources/vphone-cli/VPhoneHostControl.swift")
        self.reader_source = read_source(
            "sources/vphone-cli/VPhoneHostRequestReader.swift"
        )

    def test_accepted_clients_are_dispatched_independently(self):
        self.assertRegex(
            self.source,
            r"clientQueue\s*=\s*DispatchQueue\([^)]*attributes:\s*\.concurrent",
            "host control needs a dedicated concurrent client queue",
        )
        self.assertRegex(
            self.source,
            r"clientQueue\.async\s*\{[\s\S]{0,160}?handleClient\(clientFD,\s*controller:\s*controller\)",
            "acceptLoop must hand each fd to an independent client task",
        )
        self.assertNotRegex(
            self.source,
            r"guard clientFD >= 0 else \{ break \}\s*handleClient\(clientFD",
            "acceptLoop must not process clients inline on the accept queue",
        )

    def test_accepted_clients_cannot_terminate_host_with_sigpipe(self):
        option = re.search(
            r"setsockopt\(\s*clientFD,\s*SOL_SOCKET,\s*SO_NOSIGPIPE",
            self.source,
        )
        dispatch = re.search(
            r"clientQueue\.async\s*\{[\s\S]{0,160}?handleClient\(clientFD",
            self.source,
        )
        self.assertIsNotNone(
            option,
            "each accepted socket must suppress SIGPIPE before delayed writes",
        )
        self.assertIsNotNone(dispatch, "accepted sockets must be dispatched independently")
        self.assertLess(
            option.start(),
            dispatch.start(),
            "SO_NOSIGPIPE must be applied before client work is dispatched",
        )

    def test_host_control_accepts_bounded_multi_megabyte_json_requests(self):
        self.assertRegex(
            self.reader_source,
            r"MaxRequestBytes\s*=\s*16\s*\*\s*1024\s*\*\s*1024",
            "file_put JSON requests need a documented bounded size above 10 KB",
        )
        self.assertNotIn("while accumulated.count < 4096", self.source)
        self.assertIn("VPhoneHostRequestReader.readLine", self.source)

    def test_slow_clients_are_bounded_by_deadlines_and_slots(self):
        self.assertRegex(
            self.source,
            r"fcntl\([^;]+F_SETFL[^;]+O_NONBLOCK",
        )
        self.assertRegex(
            self.source,
            r"MaxActiveClients\s*=\s*8\b",
        )
        self.assertRegex(
            self.source,
            r"clientSlots\.wait\(timeout:\s*\.now\(\)\)",
        )
        self.assertRegex(
            self.source,
            r"defer\s*\{\s*clientSlots\.signal\(\)\s*\}",
        )
        self.assertRegex(
            self.reader_source,
            r"RequestTimeoutNanoseconds\s*=\s*10\s*\*\s*NSEC_PER_SEC",
        )
        self.assertRegex(
            self.reader_source,
            r"ResponseTimeoutNanoseconds\s*=\s*10\s*\*\s*NSEC_PER_SEC",
        )
        self.assertIn("DispatchTime.now().uptimeNanoseconds", self.reader_source)
        self.assertRegex(self.reader_source, r"Darwin\.poll\(")
        self.assertIn("VPhoneHostResponseWriter.writeAll", self.source)

    def test_action_timing_parameters_are_validated_before_conversion(self):
        self.assertIn(
            "VPhoneHostRequestTiming.screenDelayMilliseconds",
            self.source,
        )
        self.assertIn(
            "VPhoneHostRequestTiming.swipeDurationMilliseconds",
            self.source,
        )
        self.assertNotRegex(self.source, r"UInt64\((?:screenDelay|totalDelay|durationMs)\)")


if __name__ == "__main__":
    unittest.main()
