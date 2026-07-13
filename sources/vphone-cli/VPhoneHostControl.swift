import AppKit
import Foundation
import ImageIO

// MARK: - Host Control Socket

/// Lightweight Unix domain socket server that accepts automation commands from
/// local processes (e.g. Claude Code via `nc -U`).  One JSON line in, one JSON
/// line out, then the connection closes.
///
/// Every response includes an `"image"` field with a compact base64-encoded
/// grayscale JPEG of the current screen (unless `"screen":false` is sent).
///
/// Supported commands:
///   {"t":"screenshot"}                          → full-res save to Desktop (or explicit path)
///   {"t":"screenshot","path":"/tmp/shot.png"}   → save to explicit path (PNG/JPEG by extension)
///   {"t":"tap","x":645,"y":1398}                → tap at pixel coordinates
///   {"t":"swipe","x1":645,"y1":2600,"x2":645,"y2":1400,"ms":300}  → swipe
///   {"t":"key","name":"home"}                   → hardware key (home/power/volup/voldown)
///   {"t":"type","text":"Hello"}                 → set guest clipboard
///
/// All commands except "screenshot" wait briefly then capture a compact screen
/// image returned as `"image":"<base64>"` in the response.  Pass `"screen":false`
/// to skip the capture.
@MainActor
class VPhoneHostControl {
    private let socketPath: String
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "vphone.hostcontrol.accept")
    private let clientQueue = DispatchQueue(label: "vphone.hostcontrol.client", attributes: .concurrent)

    private weak var captureView: VPhoneVirtualMachineView?
    private var screenRecorder: VPhoneScreenRecorder?
    private weak var control: VPhoneControl?

    /// Thread-safe box for passing results between main actor and accept queue.
    private final class ResultBox: @unchecked Sendable {
        var path: String?
        var error: String?
        var ok = false
        var imageBase64: String?
        var payload: [String: Any] = [:]
    }

    /// Screen pixel dimensions for coordinate mapping.
    private var screenWidth: Int = 1290
    private var screenHeight: Int = 2796

    /// Compact screenshot scale factor (1/3 = 430x932).
    private static let compactScale = 3

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start(
        captureView: VPhoneVirtualMachineView,
        screenRecorder: VPhoneScreenRecorder,
        control: VPhoneControl,
        screenWidth: Int,
        screenHeight: Int
    ) {
        self.captureView = captureView
        self.screenRecorder = screenRecorder
        self.control = control
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight

        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("[hostctl] failed to create socket: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            print("[hostctl] socket path too long")
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                for (i, byte) in pathBytes.enumerated() {
                    dst[i] = byte
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            print("[hostctl] bind failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        guard listen(fd, 4) == 0 else {
            print("[hostctl] listen failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        listenFD = fd
        print("[hostctl] listening on \(socketPath)")

        let capturedFD = fd
        let clientQueue = clientQueue
        acceptQueue.async { [weak self] in
            Self.acceptLoop(listenFD: capturedFD, controller: self, clientQueue: clientQueue)
        }
    }

    func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }

    // MARK: - Compact Screenshot

    /// Capture current screen as a small grayscale JPEG, returned as base64.
    private func captureCompactScreenshot() async -> String? {
        guard let recorder = screenRecorder, let view = captureView, view.window != nil else {
            print("[hostctl] compact screenshot unavailable: missing recorder/view/window")
            return nil
        }

        // Reuse the existing private-API capture
        guard let cgImage = await captureStillImage(recorder: recorder, view: view) else {
            print("[hostctl] compact screenshot unavailable: graphics capture returned nil")
            return nil
        }

        let dstW = cgImage.width / Self.compactScale
        let dstH = cgImage.height / Self.compactScale

        // Draw into grayscale context
        let gray = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: dstW, height: dstH,
            bitsPerComponent: 8, bytesPerRow: dstW,
            space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // High contrast: bump brightness
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))

        guard let grayImage = ctx.makeImage() else { return nil }

        // Encode as low-quality JPEG
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.35]
        CGImageDestinationAddImage(dest, grayImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        return (data as Data).base64EncodedString()
    }

    /// Access the recorder's private capture method via the existing async wrapper.
    private func captureStillImage(recorder: VPhoneScreenRecorder, view: NSView) async -> CGImage? {
        try? await recorder.captureStillImage(from: view)
    }

    // MARK: - Accept Loop

    private nonisolated static func acceptLoop(
        listenFD: Int32, controller: VPhoneHostControl?, clientQueue: DispatchQueue
    ) {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { break }
            var noSigPipe: Int32 = 1
            guard setsockopt(
                clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                socklen_t(MemoryLayout.size(ofValue: noSigPipe))
            ) == 0 else {
                print("[hostctl] SO_NOSIGPIPE failed: \(String(cString: strerror(errno)))")
                close(clientFD)
                continue
            }
            clientQueue.async { handleClient(clientFD, controller: controller) }
        }
    }

    private nonisolated static func handleClient(_ fd: Int32, controller: VPhoneHostControl?) {
        defer { close(fd) }

        guard let line = readLine(from: fd) else { return }

        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["t"] as? String
        else {
            writeResponse(fd, ok: false, error: "invalid JSON")
            return
        }

        // Whether to include a compact screenshot in the response (default: true)
        let wantScreen = json["screen"] as? Bool ?? true
        // Delay before screenshot (ms) — lets animations settle
        let screenDelay = json["delay"] as? Int ?? 500

        switch type {
        case "screenshot":
            let outputPath = json["path"] as? String
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller,
                      let recorder = controller.screenRecorder,
                      let view = controller.captureView,
                      view.window != nil
                else {
                    print("[hostctl] screenshot failed: no active VM view")
                    result.error = "no active VM view"
                    return
                }
                do {
                    if let outputPath {
                        print("[hostctl] screenshot request path=\(outputPath)")
                        let url = try await recorder.saveScreenshot(view: view, to: URL(fileURLWithPath: outputPath))
                        result.path = url.path
                    }
                    // Always include compact image for screenshot command
                    result.imageBase64 = await controller.captureCompactScreenshot()
                    result.ok = true
                    print("[hostctl] screenshot ok path=\(result.path ?? "nil") image=\(result.imageBase64 != nil)")
                } catch {
                    print("[hostctl] screenshot failed: \(error)")
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            if result.ok {
                writeResponse(fd, ok: true, path: result.path, image: result.imageBase64)
            } else {
                writeResponse(fd, ok: false, error: result.error ?? "unknown error")
            }

        case "tap":
            guard let x = json["x"] as? Double, let y = json["y"] as? Double else {
                writeResponse(fd, ok: false, error: "tap requires x and y (pixel coordinates)")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let view = controller.captureView, view.window != nil else {
                    result.error = "no active VM view"
                    return
                }
                view.injectTap(
                    pixelX: x, pixelY: y,
                    screenWidth: controller.screenWidth, screenHeight: controller.screenHeight
                )
                result.ok = true
                if wantScreen {
                    try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                    result.imageBase64 = await controller.captureCompactScreenshot()
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, image: result.imageBase64)

        case "swipe":
            guard let x1 = json["x1"] as? Double, let y1 = json["y1"] as? Double,
                  let x2 = json["x2"] as? Double, let y2 = json["y2"] as? Double
            else {
                writeResponse(fd, ok: false, error: "swipe requires x1, y1, x2, y2")
                return
            }
            let durationMs = json["ms"] as? Int ?? 300
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let view = controller.captureView, view.window != nil else {
                    result.error = "no active VM view"
                    return
                }
                view.injectSwipe(
                    fromX: x1, fromY: y1, toX: x2, toY: y2,
                    screenWidth: controller.screenWidth, screenHeight: controller.screenHeight,
                    durationMs: durationMs
                )
                result.ok = true
                if wantScreen {
                    // Wait for swipe to finish + settle
                    let totalDelay = durationMs + screenDelay
                    try? await Task.sleep(nanoseconds: UInt64(totalDelay) * 1_000_000)
                    result.imageBase64 = await controller.captureCompactScreenshot()
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, image: result.imageBase64)

        case "key":
            guard let name = json["name"] as? String else {
                writeResponse(fd, ok: false, error: "key requires name (home/power/volup/voldown)")
                return
            }
            let hidKey: (page: UInt32, usage: UInt32)? = switch name {
            case "home": (0x0C, 0x40)
            case "power": (0x0C, 0x30)
            case "volup": (0x0C, 0xE9)
            case "voldown": (0x0C, 0xEA)
            default: nil
            }
            guard let key = hidKey else {
                writeResponse(fd, ok: false, error: "unknown key: \(name)")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                ctl.sendHIDPress(page: key.page, usage: key.usage)
                result.ok = true
                if wantScreen {
                    try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                    result.imageBase64 = await controller.captureCompactScreenshot()
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, image: result.imageBase64)

        case "type":
            guard let text = json["text"] as? String else {
                writeResponse(fd, ok: false, error: "type requires text")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    try await ctl.clipboardSet(text: text)
                    result.ok = true
                    if wantScreen {
                        try? await Task.sleep(nanoseconds: UInt64(screenDelay) * 1_000_000)
                        result.imageBase64 = await controller.captureCompactScreenshot()
                    }
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, image: result.imageBase64)

        case "settings_get":
            guard let domain = json["domain"] as? String else {
                writeResponse(fd, ok: false, error: "settings_get requires domain")
                return
            }
            let key = json["key"] as? String
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    result.payload["value"] = try await ctl.settingsGet(domain: domain, key: key) ?? NSNull()
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, extra: result.payload)

        case "settings_set":
            guard let domain = json["domain"] as? String,
                  let key = json["key"] as? String,
                  let value = json["value"]
            else {
                writeResponse(fd, ok: false, error: "settings_set requires domain, key, value")
                return
            }
            let valueType = json["type"] as? String
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    try await ctl.settingsSet(domain: domain, key: key, value: value, type: valueType)
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error)

        case "app_list":
            let filter = json["filter"] as? String ?? "all"
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    result.payload["apps"] = try await ctl.appList(filter: filter).map { app in
                        [
                            "bundle_id": app.bundleId,
                            "name": app.name,
                            "version": app.version,
                            "type": app.type,
                            "state": app.state,
                            "pid": app.pid,
                            "path": app.path,
                            "data_container": app.dataContainer,
                        ] as [String: Any]
                    }
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, extra: result.payload)

        case "app_foreground":
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    let app = try await ctl.appForeground()
                    result.payload = ["bundle_id": app.bundleId, "name": app.name, "pid": app.pid]
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, extra: result.payload)

        case "app_launch":
            guard let bundleId = json["bundle_id"] as? String else {
                writeResponse(fd, ok: false, error: "app_launch requires bundle_id")
                return
            }
            let url = json["url"] as? String
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    result.payload["pid"] = try await ctl.appLaunch(bundleId: bundleId, url: url)
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, extra: result.payload)

        case "app_terminate":
            guard let bundleId = json["bundle_id"] as? String else {
                writeResponse(fd, ok: false, error: "app_terminate requires bundle_id")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    try await ctl.appTerminate(bundleId: bundleId)
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error)

        case "open_url":
            guard let url = json["url"] as? String else {
                writeResponse(fd, ok: false, error: "open_url requires url")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    try await ctl.openURL(url)
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error)

        case "file_list":
            guard let path = json["path"] as? String else {
                writeResponse(fd, ok: false, error: "file_list requires path")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    result.payload["entries"] = try await ctl.listFiles(path: path)
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, extra: result.payload)

        case "file_get":
            guard let path = json["path"] as? String else {
                writeResponse(fd, ok: false, error: "file_get requires path")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    let data = try await ctl.downloadFile(path: path)
                    result.payload["size"] = data.count
                    result.payload["data"] = data.base64EncodedString()
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, extra: result.payload)

        case "file_put":
            guard let path = json["path"] as? String else {
                writeResponse(fd, ok: false, error: "file_put requires path")
                return
            }
            let permissions = json["perm"] as? String ?? "644"
            let data: Data?
            if let b64 = json["data"] as? String {
                data = Data(base64Encoded: b64)
            } else if let text = json["text"] as? String {
                data = text.data(using: .utf8)
            } else {
                data = nil
            }
            guard let data else {
                writeResponse(fd, ok: false, error: "file_put requires data (base64) or text")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    try await ctl.uploadFile(path: path, data: data, permissions: permissions)
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error)

        case "guest":
            guard let request = json["request"] as? [String: Any],
                  request["t"] is String
            else {
                writeResponse(fd, ok: false, error: "guest requires request object with t")
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let result = ResultBox()

            Task { @MainActor in
                defer { semaphore.signal() }
                guard let controller, let ctl = controller.control, ctl.isConnected else {
                    result.error = "guest not connected"
                    return
                }
                do {
                    let (resp, data) = try await ctl.sendRequest(request)
                    result.payload["response"] = resp
                    if let data {
                        result.payload["data"] = data.base64EncodedString()
                        result.payload["size"] = data.count
                    }
                    result.ok = true
                } catch {
                    result.error = "\(error)"
                }
            }

            semaphore.wait()
            writeResponse(fd, ok: result.ok, error: result.error, extra: result.payload)

        default:
            writeResponse(fd, ok: false, error: "unknown command: \(type)")
        }
    }

    // MARK: - Socket I/O

    private nonisolated static func readLine(from fd: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var accumulated = Data()

        while accumulated.count < 4096 {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            accumulated.append(contentsOf: buffer[..<n])
            if accumulated.contains(0x0A) { break }
        }

        if let nlRange = accumulated.firstIndex(of: 0x0A) {
            return String(data: accumulated[..<nlRange], encoding: .utf8)
        }
        return accumulated.isEmpty ? nil : String(data: accumulated, encoding: .utf8)
    }

    private nonisolated static func writeResponse(
        _ fd: Int32, ok: Bool, path: String? = nil, error: String? = nil, image: String? = nil,
        extra: [String: Any]? = nil
    ) {
        var dict: [String: Any] = ["ok": ok]
        if let path { dict["path"] = path }
        if let error { dict["error"] = error }
        if let image { dict["image"] = image }
        if let extra {
            for (key, value) in extra {
                dict[key] = value
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              var json = String(data: data, encoding: .utf8)
        else { return }

        json += "\n"
        json.withCString { ptr in
            var remaining = strlen(ptr)
            var offset = 0
            while remaining > 0 {
                let written = write(fd, ptr.advanced(by: offset), remaining)
                if written <= 0 { break }
                offset += written
                remaining -= written
            }
        }
    }
}
