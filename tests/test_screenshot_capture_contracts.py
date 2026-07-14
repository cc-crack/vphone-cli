import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read_source(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


class ScreenshotCaptureContracts(unittest.TestCase):
    def setUp(self):
        self.source = read_source("sources/vphone-cli/VPhoneScreenRecorder.swift")

    def test_automation_capture_rejects_appkit_snapshot_fallback(self):
        self.assertNotIn(
            "captureViewSnapshot",
            self.source,
            "automation capture must fail when no real graphics frame exists",
        )
        self.assertNotRegex(
            self.source,
            r"\b(?:bitmapImageRepForCachingDisplay|cacheDisplay)\b",
            "automation capture must not fall back to an AppKit cached Metal-view snapshot",
        )
        self.assertNotRegex(
            self.source,
            r"1290\s*[x,]\s*2796|2796\s*[x,]\s*1290",
            "capture code must not synthesize or resize images to the RC dimensions",
        )

    def test_callback_diagnostics_are_safe_and_do_not_log_image_bytes(self):
        self.assertRegex(
            self.source,
            r"method_getTypeEncoding\(",
            "screenshot selector method encoding must be logged for private ABI diagnosis",
        )
        self.assertRegex(
            self.source,
            r"\bobject_getClassName\(",
            "callback diagnostics must include the callback object's dynamic class",
        )
        self.assertRegex(
            self.source,
            r"\bsafeCFTypeID\s*\(",
            "CF type IDs must be obtained through a guard that rejects arbitrary ObjC objects",
        )
        self.assertRegex(
            self.source,
            r"CF type ID",
            "callback diagnostics must include safe CF type ID information when available",
        )
        self.assertRegex(
            self.source,
            r"accepted image dimensions",
            "successful conversions must log accepted image dimensions",
        )
        self.assertNotRegex(
            self.source,
            r"print\([^)]*(?:base64|pngData|jpegData|image bytes|pixel bytes)",
            "diagnostics must not print image bytes or encoded image payloads",
        )

    def test_converts_real_graphics_backed_callback_values(self):
        expectations = {
            "direct CGImage": r"CGImage\.typeID",
            "NSImage": r"\bas\?\s*NSImage\b",
            "CIImage": r"\bas\?\s*CIImage\b",
            "CVPixelBuffer": r"CVPixelBufferGetTypeID\(\)",
            "IOSurface": r"IOSurfaceGetTypeID\(\)",
            "CoreImage context": r"CIContext\(",
            "CVPixelBuffer render": r"CIImage\(cvPixelBuffer:",
            "IOSurface render": r"CIImage\(ioSurface:",
            "CGImage render": r"\.createCGImage\(",
        }
        for label, pattern in expectations.items():
            with self.subTest(label=label):
                self.assertRegex(self.source, pattern)

    def test_async_screenshot_continuation_resumes_once(self):
        self.assertRegex(
            self.source,
            r"\bScreenshotCallbackBox\b",
            "private screenshot callback must be wrapped in an exactly-once guard",
        )
        self.assertRegex(
            self.source,
            r"\bresumeOnce\s*\(",
            "async continuation/completion must be resumed at most once",
        )
        self.assertRegex(
            self.source,
            r"withCheckedContinuation[\s\S]{0,400}?resumeOnce",
            "the async capture wrapper must use the same exactly-once completion guard",
        )

    def test_private_callback_has_error_abi_and_a_hard_deadline(self):
        self.assertRegex(
            self.source,
            r"ScreenshotCompletionBlock\s*=\s*@convention\(block\)\s*\(AnyObject\?,\s*AnyObject\?\)",
            "Virtualization supplies both image and error callback arguments",
        )
        self.assertRegex(
            self.source,
            r"ScreenshotTimeoutSeconds\s*=\s*2(?:\.0+)?",
            "each private capture attempt must have a two-second deadline",
        )
        self.assertRegex(
            self.source,
            r"screenshotTimeoutSeconds\s*=\s*Self\.ScreenshotTimeoutSeconds"
            r"[\s\S]{0,300}?asyncAfter\([\s\S]{0,300}?resumeOnce\(nil\)",
            "the deadline must race the callback through the exactly-once box",
        )

    def test_still_capture_rejects_wrong_dimensions(self):
        self.assertRegex(
            self.source,
            r"graphicsDisplay\.sizeInPixels",
            "capture validation must derive dimensions from the active display",
        )
        self.assertRegex(
            self.source,
            r"cgImage\.width\s*==\s*expectedWidth[\s\S]{0,120}?cgImage\.height\s*==\s*expectedHeight",
            "only native display dimensions may be accepted",
        )

    def test_capture_does_not_read_private_framebuffer_memory(self):
        self.assertNotIn("_framebufferView", self.source)
        self.assertNotIn("_lastNonEmptyFrameUpdate", self.source)
        self.assertNotIn("sharedFrameUpdateStorage", self.source)
        self.assertNotIn("Unmanaged<AnyObject>.fromOpaque", self.source)


if __name__ == "__main__":
    unittest.main()
