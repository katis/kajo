import Foundation

/// Every result line to stdout (streamed by `devicectl ... --console` and by
/// the macOS script) and appended to a file, so a killed run still leaves
/// data: Documents on iOS, `outdir=` (default the temporary directory) on
/// macOS. Lines are also handed to `onLine` (the status view).
public final class Output: @unchecked Sendable {
    public static let shared = Output()
    private let lock = NSLock()
    private var path = ""
    private var onLine: (@Sendable (String) -> Void)?

    public func setDirectory(_ dir: String, file: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        path = (dir as NSString).appendingPathComponent(file)
    }

    public var filePath: String {
        lock.lock()
        defer { lock.unlock() }
        return path
    }

    public func setOnLine(_ f: @escaping @Sendable (String) -> Void) {
        lock.lock()
        onLine = f
        lock.unlock()
    }

    /// One line (no newline inside), to stdout and the file.
    public func emit(_ line: String) {
        lock.lock()
        let data = Data((line + "\n").utf8)
        FileHandle.standardOutput.write(data)
        if !path.isEmpty {
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
        let f = onLine
        lock.unlock()
        f?(line)
    }

    /// Raw bytes of one NDJSON event plus a newline, to stdout and the file.
    public func emitEvent(_ bytes: [UInt8]) {
        emit(String(decoding: bytes, as: UTF8.self))
    }

    /// The default directory for result files.
    public static var defaultDirectory: String {
        #if os(iOS)
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        #else
        (NSTemporaryDirectory() as NSString).appendingPathComponent("kajo-shell")
        #endif
    }
}
