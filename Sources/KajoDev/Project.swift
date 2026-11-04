import Foundation

// Module 9b: sources to the project directory (docs/modules/development-protocol.md
// section 3). A change the target accepted answers the files it touched in
// the session's package (`{path, text}` to write, `{path, remove}` to
// delete), and the client writes them into the project directory on the
// developer's machine, so `git diff` shows what the session changed. A path
// is one file name of the project directory (`Foo.class.st`,
// `Foo.extension.st`), never a path out of it.

public struct ProjectWriter: Sendable {
    public let directory: String

    public init(directory: String) { self.directory = directory }

    /// Whether `name` is a file name the target may ask for.
    public static func isSourceFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".class.st") || name.hasSuffix(".extension.st"), !name.contains("/"), !name.contains("\\0"),
              !name.hasPrefix(".") else { return false }
        let stem = name.hasSuffix(".class.st") ? name.dropLast(9) : name.dropLast(13)
        return !stem.isEmpty && stem.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Apply a reply's `files` (anywhere in `result`). Answers what was
    /// written and removed, file names.
    @discardableResult
    public func apply(_ result: JSONValue) throws -> [String] {
        var done: [String] = []
        for f in result["files"]?.array ?? [] {
            guard let name = f["path"]?.string, ProjectWriter.isSourceFileName(name) else {
                throw ProtocolError("the target named a file outside the project: \(f["path"]?.string ?? "?")")
            }
            let path = (directory as NSString).appendingPathComponent(name)
            if f["remove"] == .bool(true) {
                if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
                done.append("-" + name)
            } else if let text = f["text"]?.string {
                try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
                done.append(name)
            }
        }
        return done
    }
}
