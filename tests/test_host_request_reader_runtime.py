import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
READER_SOURCE = ROOT / "sources" / "vphone-cli" / "VPhoneHostRequestReader.swift"


class HostRequestReaderRuntimeTests(unittest.TestCase):
    def test_boundaries_and_fragmentation(self) -> None:
        harness = textwrap.dedent(
            r"""
            import Darwin
            import Foundation

            func read(_ bytes: [UInt8], chunks: [Int], maxBytes: Int) -> VPhoneHostRequestReadResult {
                var descriptors: [Int32] = [0, 0]
                precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
                let reader = descriptors[0]
                let writer = descriptors[1]

                DispatchQueue.global().async {
                    var offset = 0
                    for requestedSize in chunks where offset < bytes.count {
                        let size = min(requestedSize, bytes.count - offset)
                        bytes.withUnsafeBytes { raw in
                            _ = Darwin.write(writer, raw.baseAddress!.advanced(by: offset), size)
                        }
                        offset += size
                    }
                    if offset < bytes.count {
                        bytes.withUnsafeBytes { raw in
                            _ = Darwin.write(
                                writer,
                                raw.baseAddress!.advanced(by: offset),
                                bytes.count - offset
                            )
                        }
                    }
                    Darwin.close(writer)
                }

                let result = VPhoneHostRequestReader.readLine(from: reader, maxBytes: maxBytes)
                Darwin.close(reader)
                return result
            }

            func assertSlowReadTimesOut() {
                var descriptors: [Int32] = [0, 0]
                precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
                let reader = descriptors[0]
                let writer = descriptors[1]
                let closed = DispatchSemaphore(value: 0)

                DispatchQueue.global().async {
                    usleep(50_000)
                    var byte = UInt8(ascii: "x")
                    _ = Darwin.write(writer, &byte, 1)
                    usleep(150_000)
                    Darwin.close(writer)
                    closed.signal()
                }

                let started = DispatchTime.now().uptimeNanoseconds
                let result = VPhoneHostRequestReader.readLine(
                    from: reader,
                    maxBytes: 8,
                    timeoutNanoseconds: 100_000_000
                )
                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                Darwin.close(reader)
                closed.wait()
                guard case .timedOut = result, elapsed < 180_000_000 else {
                    fatalError("expected bounded read timeout, got \(result) in \(elapsed)ns")
                }
            }

            func assertBlockedWriteTimesOut() {
                var descriptors: [Int32] = [0, 0]
                precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
                var sendBufferBytes: Int32 = 4096
                precondition(setsockopt(
                    descriptors[0], SOL_SOCKET, SO_SNDBUF,
                    &sendBufferBytes, socklen_t(MemoryLayout.size(ofValue: sendBufferBytes))
                ) == 0)
                let flags = fcntl(descriptors[0], F_GETFL)
                precondition(flags >= 0)
                precondition(fcntl(descriptors[0], F_SETFL, flags | O_NONBLOCK) == 0)

                let payload = Data(repeating: 0x61, count: 1024 * 1024)
                let started = DispatchTime.now().uptimeNanoseconds
                let result = VPhoneHostResponseWriter.writeAll(
                    payload,
                    to: descriptors[0],
                    timeoutNanoseconds: 100_000_000
                )
                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                Darwin.close(descriptors[0])
                Darwin.close(descriptors[1])
                guard case .timedOut = result, elapsed < 180_000_000 else {
                    fatalError("expected bounded write timeout, got \(result) in \(elapsed)ns")
                }
            }

            func assertLine(
                _ payload: String,
                chunks: [Int],
                maxBytes: Int,
                file: StaticString = #filePath,
                line: UInt = #line
            ) {
                let result = read(Array((payload + "\n").utf8), chunks: chunks, maxBytes: maxBytes)
                guard case .line(let actual) = result, actual == payload else {
                    fatalError("expected line \(payload), got \(result)", file: file, line: line)
                }
            }

            assertLine("1234567", chunks: [1, 2, 1, 3, 1], maxBytes: 8)
            assertLine("12345678", chunks: [9], maxBytes: 8)
            assertLine("12345678", chunks: [8, 1], maxBytes: 8)

            let tooLarge = read(Array("123456789\n".utf8), chunks: [4, 4, 2], maxBytes: 8)
            guard case .tooLarge = tooLarge else {
                fatalError("expected tooLarge, got \(tooLarge)")
            }

            let invalidUTF8 = read([0xff, 0x0a], chunks: [1, 1], maxBytes: 8)
            guard case .invalidUTF8 = invalidUTF8 else {
                fatalError("expected invalidUTF8, got \(invalidUTF8)")
            }

            assertSlowReadTimesOut()
            assertBlockedWriteTimesOut()

            print("host-request-reader-runtime: ok")
            """
        )

        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            main_path = temporary_path / "main.swift"
            binary_path = temporary_path / "reader-test"
            main_path.write_text(harness)
            compile_result = subprocess.run(
                [
                    "xcrun",
                    "swiftc",
                    str(READER_SOURCE),
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
            self.assertIn("host-request-reader-runtime: ok", run_result.stdout)


if __name__ == "__main__":
    unittest.main()
