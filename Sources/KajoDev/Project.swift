import Foundation

// Module 9b: sources to the project directory (docs/modules/development-protocol.md
// section 3). A change the target accepted answers the files it touched in
// the session's package (`{path, text}` to write, `{path, remove}` to
// delete), and the client writes them into the project directory on the
// developer's machine, so `git diff` shows what the session changed. A path
// is one file name of the project directory (`Foo.class.st`,
// `Foo.extension.st`) or, since tags as subdirectories
// (docs/modules/tags-as-subdirectories.md), a class file one directory
// down in its tag's subdirectory (`Tag/Foo.class.st`), never a path out of
// it: no `..`, no second `/`, no hidden component, and no link followed
// (a link in the tag's place refuses the write; the tag's directory is
// created when missing, and removed when its last file goes).

public struct ProjectWriter: Sendable {
    public let directory: String

    public init(directory: String) { self.directory = directory }

    /// Whether `name` is a file name the target may ask for: a class or
    /// extension file at the project's root, or a class file in a tag's
    /// subdirectory.
    public static func isSourceFileName(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1: return isFileName(parts[0])
        case 2: return isTagName(parts[0]) && parts[1].hasSuffix(".class.st") && isFileName(parts[1])
        default: return false
        }
    }

    static func isFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".class.st") || name.hasSuffix(".extension.st"), !name.contains("/"), !name.contains("\0"),
              !name.hasPrefix(".") else { return false }
        let stem = name.hasSuffix(".class.st") ? name.dropLast(9) : name.dropLast(13)
        return !stem.isEmpty && stem.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// A tag's directory name: one component, not empty, not hidden (so
    /// never `.` or `..`), no NUL or backslash.
    static func isTagName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\0") && !name.contains("\\")
    }

    /// Whether `path` exists as a symbolic link (not followed).
    static func isLink(_ path: String) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType) == .typeSymbolicLink
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
            let parent = (path as NSString).deletingLastPathComponent
            let inTag = name.contains("/")
            if inTag && ProjectWriter.isLink(parent) {
                throw ProtocolError("the project's \((name as NSString).deletingLastPathComponent) is a link: not followed")
            }
            if ProjectWriter.isLink(path) && f["remove"] != .bool(true) {
                // replaced, never followed: the link itself goes first
                try FileManager.default.removeItem(atPath: path)
            }
            if f["remove"] == .bool(true) {
                if FileManager.default.fileExists(atPath: path) || ProjectWriter.isLink(path) {
                    try FileManager.default.removeItem(atPath: path)
                }
                if inTag, let rest = try? FileManager.default.contentsOfDirectory(atPath: parent),
                   rest.allSatisfy({ $0 == ".DS_Store" }) {
                    try? FileManager.default.removeItem(atPath: parent)
                }
                done.append("-" + name)
            } else if let text = f["text"]?.string {
                if inTag && !FileManager.default.fileExists(atPath: parent) {
                    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: false)
                }
                try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
                done.append(name)
            }
        }
        return done
    }
}
