import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TIMING_SOURCE = ROOT / "sources" / "vphone-cli" / "VPhoneHostRequestTiming.swift"


class HostRequestTimingRuntimeTests(unittest.TestCase):
    def test_millisecond_parameters_are_bounded(self) -> None:
        harness = textwrap.dedent(
            r"""
            import Foundation

            func requireEqual(_ actual: Int?, _ expected: Int?) {
                guard actual == expected else {
                    fatalError("expected \(String(describing: expected)), got \(String(describing: actual))")
                }
            }

            func parseJSONFragment(_ raw: String) -> Any {
                try! JSONSerialization.jsonObject(
                    with: Data(raw.utf8),
                    options: .fragmentsAllowed
                )
            }

            requireEqual(
                VPhoneHostRequestTiming.screenDelayMilliseconds(from: nil),
                500
            )
            requireEqual(
                VPhoneHostRequestTiming.screenDelayMilliseconds(from: 0),
                0
            )
            requireEqual(
                VPhoneHostRequestTiming.screenDelayMilliseconds(from: 2_000),
                2_000
            )
            requireEqual(
                VPhoneHostRequestTiming.screenDelayMilliseconds(from: -1),
                nil
            )
            requireEqual(
                VPhoneHostRequestTiming.screenDelayMilliseconds(from: 2_001),
                nil
            )
            requireEqual(
                VPhoneHostRequestTiming.screenDelayMilliseconds(from: Int.max),
                nil
            )
            requireEqual(
                VPhoneHostRequestTiming.screenDelayMilliseconds(from: 1.5),
                nil
            )
            requireEqual(
                VPhoneHostRequestTiming.screenDelayMilliseconds(
                    from: parseJSONFragment("0")
                ),
                0
            )
            requireEqual(
                VPhoneHostRequestTiming.screenDelayMilliseconds(
                    from: parseJSONFragment("1")
                ),
                1
            )
            requireEqual(
                VPhoneHostRequestTiming.screenDelayMilliseconds(
                    from: parseJSONFragment("true")
                ),
                nil
            )
            requireEqual(
                VPhoneHostRequestTiming.screenDelayMilliseconds(
                    from: parseJSONFragment("false")
                ),
                nil
            )
            requireEqual(
                VPhoneHostRequestTiming.screenDelayMilliseconds(
                    from: parseJSONFragment("2.0")
                ),
                nil
            )
            requireEqual(
                VPhoneHostRequestTiming.screenDelayMilliseconds(
                    from: parseJSONFragment("2e0")
                ),
                nil
            )

            requireEqual(
                VPhoneHostRequestTiming.swipeDurationMilliseconds(from: nil),
                300
            )
            requireEqual(
                VPhoneHostRequestTiming.swipeDurationMilliseconds(from: 2_000),
                2_000
            )
            requireEqual(
                VPhoneHostRequestTiming.swipeDurationMilliseconds(from: -1),
                nil
            )
            requireEqual(
                VPhoneHostRequestTiming.swipeDurationMilliseconds(from: 2_001),
                nil
            )

            let total = VPhoneHostRequestTiming.nanoseconds(milliseconds: 4_000)
            guard total == 4_000_000_000 else {
                fatalError("unexpected nanosecond conversion: \(total)")
            }

            print("host-request-timing-runtime: ok")
            """
        )

        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            main_path = temporary_path / "main.swift"
            binary_path = temporary_path / "timing-test"
            main_path.write_text(harness)
            compile_result = subprocess.run(
                [
                    "xcrun",
                    "swiftc",
                    str(TIMING_SOURCE),
                    str(main_path),
                    "-o",
                    str(binary_path),
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)

            run_result = subprocess.run(
                [str(binary_path)],
                capture_output=True,
                text=True,
                timeout=5,
            )
            self.assertEqual(run_result.returncode, 0, run_result.stderr)
            self.assertIn("host-request-timing-runtime: ok", run_result.stdout)


if __name__ == "__main__":
    unittest.main()
