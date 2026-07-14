import Darwin
import Foundation

enum VPhoneHostRequestReadResult {
    case line(String)
    case tooLarge
    case invalidUTF8
    case disconnected
    case timedOut
    case readError(Int32)
}

enum VPhoneHostResponseWriteResult {
    case success
    case timedOut
    case writeError(Int32)
}

private enum VPhoneHostSocketDeadline {
    enum WaitResult {
        case ready
        case timedOut
        case error(Int32)
    }

    static func make(timeoutNanoseconds: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let (deadline, overflow) = now.addingReportingOverflow(timeoutNanoseconds)
        return overflow ? UInt64.max : deadline
    }

    static func wait(fd: Int32, events: Int16, deadline: UInt64) -> WaitResult {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return .timedOut }
            let remainingNanoseconds = deadline - now
            let roundedMilliseconds = (remainingNanoseconds + 999_999) / 1_000_000
            let timeoutMilliseconds = Int32(min(roundedMilliseconds, UInt64(Int32.max)))
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
            if result == 0 { return .timedOut }
            if result < 0 {
                if errno == EINTR { continue }
                return .error(errno)
            }

            let fatalEvents = Int16(POLLERR | POLLNVAL)
            if descriptor.revents & fatalEvents != 0 {
                return .error(EIO)
            }
            if descriptor.revents & events != 0 { return .ready }
            if descriptor.revents & Int16(POLLHUP) != 0 {
                return .ready
            }
        }
    }
}

enum VPhoneHostRequestReader {
    static let MaxRequestBytes = 16 * 1024 * 1024
    static let RequestTimeoutNanoseconds = 10 * NSEC_PER_SEC

    static func readLine(
        from fd: Int32,
        maxBytes: Int = MaxRequestBytes,
        timeoutNanoseconds: UInt64 = RequestTimeoutNanoseconds
    ) -> VPhoneHostRequestReadResult {
        precondition(maxBytes >= 0)
        var buffer = [UInt8](repeating: 0, count: 4096)
        var accumulated = Data()
        let deadline = VPhoneHostSocketDeadline.make(
            timeoutNanoseconds: timeoutNanoseconds
        )

        while true {
            let bytesUntilOversize = maxBytes - accumulated.count + 1
            let requestedBytes = min(buffer.count, bytesUntilOversize)
            guard requestedBytes > 0 else { return .tooLarge }

            switch VPhoneHostSocketDeadline.wait(
                fd: fd,
                events: Int16(POLLIN),
                deadline: deadline
            ) {
            case .ready:
                break
            case .timedOut:
                return .timedOut
            case .error(let code):
                return .readError(code)
            }

            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fd, rawBuffer.baseAddress, requestedBytes)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                return .readError(errno)
            }

            let bytes = buffer[..<count]
            if let newline = bytes.firstIndex(of: 0x0A) {
                guard accumulated.count + newline <= maxBytes else {
                    return .tooLarge
                }
                accumulated.append(contentsOf: bytes[..<newline])
                return decode(accumulated)
            }

            guard accumulated.count + count <= maxBytes else {
                return .tooLarge
            }
            accumulated.append(contentsOf: bytes)
        }

        guard !accumulated.isEmpty else { return .disconnected }
        return decode(accumulated)
    }

    private static func decode(_ data: Data) -> VPhoneHostRequestReadResult {
        guard let line = String(data: data, encoding: .utf8) else {
            return .invalidUTF8
        }
        return .line(line)
    }
}

enum VPhoneHostResponseWriter {
    static let ResponseTimeoutNanoseconds = 10 * NSEC_PER_SEC

    static func writeAll(
        _ data: Data,
        to fd: Int32,
        timeoutNanoseconds: UInt64 = ResponseTimeoutNanoseconds
    ) -> VPhoneHostResponseWriteResult {
        let deadline = VPhoneHostSocketDeadline.make(
            timeoutNanoseconds: timeoutNanoseconds
        )

        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return .success }
            var offset = 0
            while offset < rawBuffer.count {
                switch VPhoneHostSocketDeadline.wait(
                    fd: fd,
                    events: Int16(POLLOUT),
                    deadline: deadline
                ) {
                case .ready:
                    break
                case .timedOut:
                    return .timedOut
                case .error(let code):
                    return .writeError(code)
                }

                let written = Darwin.write(
                    fd,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0,
                   errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK
                {
                    continue
                }
                return .writeError(written == 0 ? EIO : errno)
            }
            return .success
        }
    }
}
