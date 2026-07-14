import Foundation

enum VPhoneLog {
    static func redirectStandardStreams(to configURL: URL) {
        let logURL = configURL
            .deletingLastPathComponent()
            .appendingPathComponent("vphone.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard freopen(logURL.path, "a", stdout) != nil else { return }
        _ = freopen(logURL.path, "a", stderr)
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        print("")
        print("=== vphone-cli log \(Date()) ===")
        print("[vphone] logging to \(logURL.path)")
    }
}
