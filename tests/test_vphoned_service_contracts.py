import re
import unittest
from pathlib import Path


VPHONED_SOURCE = (
    Path(__file__).resolve().parents[1] / "scripts" / "vphoned" / "vphoned.m"
)


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

    def test_optional_service_capabilities_and_logs_follow_live_flags(self) -> None:
        for service in ("hid", "clipboard", "apps"):
            self.assertIn(f'NSLog(@"vphoned: optional service {service} start")', self.source)
            self.assertRegex(
                self.source,
                rf'NSLog\(@\"vphoned: optional service {service} (ready|unavailable|failed)',
            )

        self.assertIn("gHIDAvailable", self.source)
        self.assertRegex(self.source, r'if\s*\([^\n]*gHIDAvailable[^\n]*\)\s*\n\s*\[caps addObject:@\"hid\"\];')
        self.assertRegex(self.source, r'if\s*\([^\n]*gHIDAvailable[^\n]*\)\s*\n\s*\[caps addObject:@\"touch\"\];')
        self.assertRegex(
            self.source,
            r'if\s*\([^\n]*gClipboardAvailable[^\n]*\)\s*\n\s*\[caps addObject:@\"clipboard\"\];',
        )
        self.assertRegex(
            self.source,
            r'if\s*\([^\n]*gAppsAvailable[^\n]*\)\s*\n\s*\[caps addObject:@\"apps\"\];',
        )


if __name__ == "__main__":
    unittest.main()
