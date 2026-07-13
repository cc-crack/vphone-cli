import re
import unittest
from pathlib import Path


VPHONED_SOURCE = (
    Path(__file__).resolve().parents[1] / "scripts" / "vphoned" / "vphoned.m"
)
APPS_SOURCE = VPHONED_SOURCE.parent / "vphoned_apps.m"


class VphonedServiceContractsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = VPHONED_SOURCE.read_text()

    def test_optional_services_start_in_independent_dispatch_blocks(self) -> None:
        self.assertNotIn("if (!vp_hid_load())\n      return 1;", self.source)
        self.assertNotIn("gClipboardAvailable = vp_clipboard_load();", self.source)
        self.assertNotIn("gAppsAvailable = vp_apps_load();", self.source)

        blocks = re.findall(
            r"dispatch_async\s*\([^;]+?\^\{.*?vp_(hid|clipboard|apps)_load\(\).*?\}\s*\);",
            self.source,
            re.S,
        )
        self.assertCountEqual(blocks, ["hid", "clipboard", "apps"])

        self.assertRegex(
            self.source,
            r"dispatch_queue_attr_make_with_qos_class\(\s*DISPATCH_QUEUE_CONCURRENT",
            "optional service blocks must execute concurrently",
        )

    def test_first_handshake_waits_only_for_a_bounded_startup_snapshot(self) -> None:
        wait = self.source.find("dispatch_group_wait(")
        socket_create = self.source.find("socket(AF_VSOCK")
        self.assertGreaterEqual(wait, 0, "startup needs a bounded service readiness wait")
        self.assertGreater(socket_create, wait, "socket accept must see the frozen readiness snapshot")
        self.assertRegex(
            self.source,
            r"dispatch_group_wait\([\s\S]{0,300}?VPOptionalServiceStartupTimeoutSeconds\s*\*\s*NSEC_PER_SEC",
            "service startup wait must use a named hard timeout",
        )
        self.assertRegex(
            self.source,
            r"VPOptionalServiceStartupTimeoutSeconds\s*=\s*5(?:\.0+)?",
            "optional service startup must be bounded to five seconds",
        )
        for flag in ("gHIDAvailable", "gTouchAvailable", "gClipboardAvailable", "gAppsAvailable"):
            self.assertRegex(
                self.source,
                rf"vp_service_expire\(&{flag}",
                f"pending {flag} state must be frozen before the first handshake",
            )

    def test_optional_service_capabilities_and_logs_follow_live_flags(self) -> None:
        for service in ("hid", "clipboard", "apps"):
            self.assertIn(f'NSLog(@"vphoned: optional service {service} start")', self.source)
            self.assertRegex(
                self.source,
                rf'NSLog\(@\"vphoned: optional service {service} (ready|unavailable|failed)',
            )

        self.assertIn("gHIDAvailable", self.source)
        self.assertIn("gTouchAvailable", self.source)
        self.assertRegex(self.source, r'if\s*\([^\n]*gHIDAvailable[^\n]*\)\s*\n\s*\[caps addObject:@\"hid\"\];')
        self.assertRegex(self.source, r'if\s*\([^\n]*gTouchAvailable[^\n]*\)\s*\n\s*\[caps addObject:@\"touch\"\];')
        self.assertRegex(
            self.source,
            r'if\s*\([^\n]*gClipboardAvailable[^\n]*\)\s*\n\s*\[caps addObject:@\"clipboard\"\];',
        )
        self.assertRegex(
            self.source,
            r'if\s*\([^\n]*gAppsAvailable[^\n]*\)\s*\n\s*\[caps addObject:@\"apps\"\];',
        )

    def test_requests_are_gated_by_the_frozen_service_snapshot(self) -> None:
        self.assertRegex(
            self.source,
            r'hasPrefix:@"clipboard_"\][\s\S]{0,300}?gClipboardAvailable[\s\S]{0,300}?vp_handle_clipboard_command',
        )
        self.assertRegex(
            self.source,
            r'hasPrefix:@"app_"\][\s\S]{0,300}?gAppsAvailable[\s\S]{0,300}?vp_handle_apps_command',
        )
        self.assertRegex(
            self.source,
            r'isEqualToString:@"touch"\][\s\S]{0,300}?gTouchAvailable',
        )

    def test_touch_capability_uses_digitizer_readiness(self) -> None:
        hid_header = (VPHONED_SOURCE.parent / "vphoned_hid.h").read_text()
        hid_impl = (VPHONED_SOURCE.parent / "vphoned_hid.m").read_text()
        self.assertIn("vp_hid_touch_available", hid_header)
        self.assertRegex(
            hid_impl,
            r"BOOL\s+vp_hid_touch_available\(void\)[\s\S]{0,250}?pDigitizer[\s\S]{0,250}?pFinger",
        )

    def test_foreground_app_uses_springboard_frontmost_identifier(self) -> None:
        apps_source = APPS_SOURCE.read_text()
        self.assertIn("SBSCopyFrontmostApplicationDisplayIdentifier", apps_source)
        self.assertRegex(
            apps_source,
            r'dlsym\([^;]+"SBSCopyFrontmostApplicationDisplayIdentifier"\)',
        )
        self.assertRegex(
            apps_source,
            r'isEqualToString:@"app_foreground"[\s\S]{0,1800}?@"bundle_id"[\s\S]{0,500}?@"name"[\s\S]{0,500}?@"pid"',
            "app_foreground must return the MCP contract fields",
        )


if __name__ == "__main__":
    unittest.main()
