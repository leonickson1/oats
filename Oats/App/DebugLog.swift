import Foundation

// Lightweight append-only log at /tmp/oats-debug.log. Cheap, always on,
// so a single real recording can be diagnosed without a rebuild.
enum DebugLog {
    private static let url = URL(fileURLWithPath: "/tmp/oats-debug.log")
    private static let queue = DispatchQueue(label: "oats.debuglog")

    static func log(_ message: String) {
        queue.async {
            let line = "[\(Date().timeIntervalSince1970)] \(message)\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    static func reset() {
        queue.async { try? "".write(to: url, atomically: true, encoding: .utf8) }
    }
}
