import AppKit
import AVFoundation
import CoreImage
import CoreVideo
import IOSurface
import ImageIO
import ObjectiveC.runtime
import Virtualization

private final class ScreenshotCallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let completion: (CGImage?) -> Void

    init(completion: @escaping (CGImage?) -> Void) {
        self.completion = completion
    }

    @discardableResult
    func resumeOnce(_ image: CGImage?) -> Bool {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return false
        }
        didResume = true
        lock.unlock()

        completion(image)
        return true
    }
}

private final class ScreenshotObjectConverter: @unchecked Sendable {
    private static let cfBackedClassNamePrefixes = [
        "CGImage",
        "CVPixelBuffer",
        "IOSurface",
        "_IOSurface",
        "__CVBuffer",
        "__NSCF",
    ]

    private let lock = NSLock()
    private var loggedCallbackObjects = Set<String>()
    private var loggedAcceptedDimensions = Set<String>()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func convert(_ imageObject: AnyObject?) -> CGImage? {
        guard let imageObject else {
            print("[record] screenshot callback object nil")
            return nil
        }

        let className = dynamicClassName(for: imageObject)
        let cfTypeID = safeCFTypeID(imageObject, className: className)
        logCallbackObject(className: className, cfTypeID: cfTypeID)

        if let error = imageObject as? NSError {
            print(
                "[record] screenshot callback error: domain=\(error.domain) code=\(error.code) "
                    + "description=\(error.localizedDescription)"
            )
            return nil
        }

        if let nsImage = imageObject as? NSImage,
           let cgImage = cgImage(from: nsImage)
        {
            return accept(cgImage, source: "NSImage")
        }

        if let ciImage = imageObject as? CIImage {
            return renderCIImage(ciImage, source: "CIImage")
        }

        guard let cfTypeID else {
            print("[record] screenshot callback unsupported: class=\(className) CF type ID=unavailable")
            return nil
        }

        if cfTypeID == CGImage.typeID {
            let cgImage = unsafeDowncast(imageObject, to: CGImage.self)
            return accept(cgImage, source: "CGImage")
        }

        if cfTypeID == CVPixelBufferGetTypeID() {
            let pixelBuffer = unsafeDowncast(imageObject, to: CVPixelBuffer.self)
            return renderCIImage(CIImage(cvPixelBuffer: pixelBuffer), source: "CVPixelBuffer")
        }

        if cfTypeID == IOSurfaceGetTypeID() {
            let surface = unsafeDowncast(imageObject, to: IOSurface.self)
            let ciImage = CIImage(ioSurface: surface)
            return renderCIImage(ciImage, source: "IOSurface")
        }

        print("[record] screenshot callback unsupported: class=\(className) CF type ID=\(cfTypeID)")
        return nil
    }

    private func cgImage(from nsImage: NSImage) -> CGImage? {
        if Thread.isMainThread {
            return nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        var image: CGImage?
        DispatchQueue.main.sync {
            image = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return image
    }

    private func renderCIImage(_ ciImage: CIImage, source: String) -> CGImage? {
        let extent = ciImage.extent.integral
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0
        else {
            print("[record] screenshot \(source) conversion failed: empty extent \(ciImage.extent)")
            return nil
        }

        guard let cgImage = ciContext.createCGImage(ciImage, from: extent) else {
            print("[record] screenshot \(source) conversion failed: CoreImage render returned nil")
            return nil
        }

        return accept(cgImage, source: source)
    }

    private func accept(_ cgImage: CGImage, source: String) -> CGImage {
        let key = "\(source):\(cgImage.width)x\(cgImage.height)"
        if shouldLogOnce(&loggedAcceptedDimensions, key: key) {
            print(
                "[record] accepted image dimensions source=\(source) "
                    + "width=\(cgImage.width) height=\(cgImage.height)"
            )
        }
        return cgImage
    }

    private func logCallbackObject(className: String, cfTypeID: CFTypeID?) {
        let cfDescription = cfTypeID.map(String.init) ?? "unavailable"
        let key = "\(className):\(cfDescription)"
        if shouldLogOnce(&loggedCallbackObjects, key: key) {
            print(
                "[record] screenshot callback object dynamic class=\(className) "
                    + "CF type ID=\(cfDescription)"
            )
        }
    }

    private func shouldLogOnce(_ set: inout Set<String>, key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return set.insert(key).inserted
    }

    private func dynamicClassName(for object: AnyObject) -> String {
        String(cString: object_getClassName(object))
    }

    private func safeCFTypeID(_ object: AnyObject, className: String) -> CFTypeID? {
        guard Self.cfBackedClassNamePrefixes.contains(where: { className.hasPrefix($0) }) else {
            return nil
        }
        return CFGetTypeID(object as CFTypeRef)
    }
}

// MARK: - Screen Recorder

@MainActor
class VPhoneScreenRecorder {
    private enum CaptureError: LocalizedError {
        case captureFailed
        case clipboardWriteFailed
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .captureFailed:
                "Failed to capture a frame from the virtual machine."
            case .clipboardWriteFailed:
                "Failed to copy the screenshot to the pasteboard."
            case .encodingFailed:
                "Failed to encode the screenshot as PNG."
            }
        }
    }

    private struct CaptureSource {
        let graphicsDisplay: VZGraphicsDisplay
        let description: String
    }

    private typealias ScreenshotCompletionBlock =
        @convention(block) (AnyObject?, AnyObject?) -> Void
    private typealias ScreenshotIMP = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    private static let ScreenshotTimeoutSeconds = 2.0

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var timer: Timer?
    private var frameCount: Int64 = 0
    private var outputURL: URL?
    private var graphicsDisplay: VZGraphicsDisplay?
    private var captureModeDescription = "private VZGraphicsDisplay screenshots"
    private var screenshotInFlight = false
    private var didLogCaptureFailure = false
    private var didLogScreenshotSelectorEncoding = false
    private let screenshotObjectConverter = ScreenshotObjectConverter()

    var isRecording: Bool {
        writer?.status == .writing
    }

    func startRecording(view: NSView) throws {
        guard !isRecording else { return }

        let source = try resolveCaptureSource(for: view)
        let captureSize = source.graphicsDisplay.sizeInPixels
        let width = max(Int(captureSize.width), 1)
        let height = max(Int(captureSize.height), 1)

        let url = recordingOutputURL()
        outputURL = url

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: bufferAttrs
        )

        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        videoInput = input
        self.adaptor = adaptor
        graphicsDisplay = source.graphicsDisplay
        captureModeDescription = source.description
        frameCount = 0
        screenshotInFlight = false
        didLogCaptureFailure = false
        didLogScreenshotSelectorEncoding = false

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.captureFrame()
            }
        }

        print(
            "[record] started - \(url.lastPathComponent) (\(width)x\(height), source: \(captureModeDescription))"
        )
    }

    func stopRecording() async -> URL? {
        guard let writer, writer.status == .writing else { return nil }

        timer?.invalidate()
        timer = nil

        videoInput?.markAsFinished()
        await writer.finishWriting()

        let url = outputURL
        self.writer = nil
        videoInput = nil
        adaptor = nil
        outputURL = nil
        graphicsDisplay = nil
        screenshotInFlight = false
        didLogCaptureFailure = false
        didLogScreenshotSelectorEncoding = false

        if let url {
            print("[record] saved - \(url.path)")
        }
        return url
    }

    func copyScreenshotToPasteboard(view: NSView) async throws {
        let cgImage = try await captureStillImage(from: view)

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw CaptureError.clipboardWriteFailed
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CaptureError.clipboardWriteFailed
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data as Data, forType: .init("public.jpeg"))

        print("[record] screenshot copied to clipboard")
    }

    func saveScreenshot(view: NSView) async throws -> URL {
        try await saveScreenshot(view: view, to: screenshotOutputURL())
    }

    func saveScreenshot(view: NSView, to url: URL) async throws -> URL {
        let cgImage = try await captureStillImage(from: view)
        let utType = url.pathExtension.lowercased() == "png" ? "public.png" : "public.jpeg"

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, utType as CFString, 1, nil
        ) else {
            throw CaptureError.encodingFailed
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CaptureError.encodingFailed
        }

        print("[record] screenshot saved - \(url.path)")
        return url
    }

    // MARK: - Frame Capture

    private func captureFrame() {
        guard let adaptor, let input = videoInput,
              input.isReadyForMoreMediaData,
              let graphicsDisplay
        else { return }

        captureGraphicsDisplayFrame(graphicsDisplay, adaptor: adaptor)
    }

    private func captureGraphicsDisplayFrame(
        _ graphicsDisplay: VZGraphicsDisplay,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) {
        guard !screenshotInFlight else { return }

        screenshotInFlight = true
        takeGraphicsScreenshot(from: graphicsDisplay) { [weak self] cgImage in
            Task { @MainActor in
                guard let self else { return }

                self.screenshotInFlight = false

                guard let input = self.videoInput, input.isReadyForMoreMediaData else { return }

                guard let cgImage else {
                    if !self.didLogCaptureFailure {
                        print("[record] graphics screenshot returned no image")
                        self.didLogCaptureFailure = true
                    }
                    return
                }

                self.didLogCaptureFailure = false
                self.appendFrame(from: adaptor, cgImage: cgImage)
            }
        }
    }

    func captureStillImage(from view: NSView) async throws -> CGImage {
        let source = try resolveCaptureSource(for: view)
        if let cgImage = await takeGraphicsScreenshot(from: source.graphicsDisplay) {
            return cgImage
        }
        throw CaptureError.captureFailed
    }

    private nonisolated static func validateNativeFrame(
        _ cgImage: CGImage,
        expectedWidth: Int,
        expectedHeight: Int,
        source: String
    ) -> CGImage? {
        guard cgImage.width == expectedWidth, cgImage.height == expectedHeight else {
            print(
                "[record] rejected \(source) dimensions width=\(cgImage.width) "
                    + "height=\(cgImage.height) expected=\(expectedWidth)x\(expectedHeight)"
            )
            return nil
        }
        return cgImage
    }

    private func appendFrame(from adaptor: AVAssetWriterInputPixelBufferAdaptor, cgImage: CGImage) {
        guard let input = videoInput, input.isReadyForMoreMediaData else { return }
        guard let pool = adaptor.pixelBufferPool else { return }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pb = pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(pb, [])
        let pbWidth = CVPixelBufferGetWidth(pb)
        let pbHeight = CVPixelBufferGetHeight(pb)
        if let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: pbWidth,
            height: pbHeight,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: pbWidth, height: pbHeight))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        let time = CMTime(value: frameCount, timescale: 30)
        adaptor.append(pb, withPresentationTime: time)
        frameCount += 1
    }

    private func resolveCaptureSource(for view: NSView) throws -> CaptureSource {
        guard let vmView = view as? VPhoneVirtualMachineView,
              let graphicsDisplay = vmView.recordingGraphicsDisplay
        else {
            throw CaptureError.captureFailed
        }

        return CaptureSource(
            graphicsDisplay: graphicsDisplay,
            description: "private VZGraphicsDisplay screenshots"
        )
    }

    private func takeGraphicsScreenshot(
        from graphicsDisplay: VZGraphicsDisplay,
        completion: @escaping (CGImage?) -> Void
    ) {
        let selector = NSSelectorFromString("_takeScreenshotWithCompletionHandler:")
        let callbackBox = ScreenshotCallbackBox(completion: completion)
        guard graphicsDisplay.responds(to: selector),
              let cls = object_getClass(graphicsDisplay),
              let method = class_getInstanceMethod(cls, selector)
        else {
            callbackBox.resumeOnce(nil)
            return
        }

        if !didLogScreenshotSelectorEncoding {
            let encoding = method_getTypeEncoding(method).map { String(cString: $0) } ?? "unavailable"
            print("[record] screenshot selector method encoding: \(encoding)")
            didLogScreenshotSelectorEncoding = true
        }

        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: ScreenshotIMP.self)
        let converter = screenshotObjectConverter
        let expectedSize = graphicsDisplay.sizeInPixels
        let expectedWidth = Int(expectedSize.width.rounded())
        let expectedHeight = Int(expectedSize.height.rounded())
        let screenshotTimeoutSeconds = Self.ScreenshotTimeoutSeconds

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + screenshotTimeoutSeconds
        ) {
            if callbackBox.resumeOnce(nil) {
                print(
                    "[record] screenshot callback timed out after "
                        + "\(screenshotTimeoutSeconds)s"
                )
            }
        }

        let block: ScreenshotCompletionBlock = { imageObject, errorObject in
            if let error = errorObject as? NSError {
                print(
                    "[record] screenshot callback error: domain=\(error.domain) "
                        + "code=\(error.code) description=\(error.localizedDescription)"
                )
            }

            guard let cgImage = converter.convert(imageObject) else {
                callbackBox.resumeOnce(nil)
                return
            }
            guard let nativeFrame = Self.validateNativeFrame(
                cgImage,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight,
                source: "screenshot"
            ) else {
                callbackBox.resumeOnce(nil)
                return
            }
            callbackBox.resumeOnce(nativeFrame)
        }
        let blockObject = unsafeBitCast(block, to: AnyObject.self)
        function(graphicsDisplay, selector, blockObject)
    }

    private func takeGraphicsScreenshot(from graphicsDisplay: VZGraphicsDisplay) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let callbackBox = ScreenshotCallbackBox { cgImage in
                continuation.resume(returning: cgImage)
            }
            takeGraphicsScreenshot(from: graphicsDisplay) { cgImage in
                callbackBox.resumeOnce(cgImage)
            }
        }
    }

    private func recordingOutputURL() -> URL {
        desktopDirectory().appendingPathComponent("vphone-recording-\(timestampString()).mov")
    }

    private func screenshotOutputURL() -> URL {
        desktopDirectory().appendingPathComponent("vphone-screenshot-\(timestampString()).jpg")
    }

    private func timestampString() -> String {
        ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }

    private func desktopDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }
}
