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
                // The review fixes (item 18, primitives.F7's second half): a
                // remove takes one regular file or link (never followed) and
                // never a directory, never recursively: a directory in a
                // source file's place is a refusal.
                if let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType {
                    guard type == .typeRegular || type == .typeSymbolicLink else {
                        throw ProtocolError("the project's \(name) is not a file: not removed")
                    }
                    try FileManager.default.removeItem(atPath: path)
                }
                // An emptied tag directory goes (a Finder .DS_Store aside),
                // only when nothing else is in it.
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

/// Why a directory is not a target's project directory (the project
/// directory, 2026-11-11: `ClientHost.setProject`), as a host shows it.
public struct ProjectRefusal: Error, Sendable, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// The Kajo app's remembered project directories (the project directory,
/// part 3, docs/modules/project-directory.md): one line per target name,
/// `name<TAB>directory`, in `<support>/project-directories` (Application
/// Support's Kajo folder, `KAJO_SUPPORT_DIR` in tests); `#` starts a
/// comment line. A line that is not a target name (1 to 64 bytes, no
/// control character) and an absolute path with no control character is
/// ignored, and no such line is ever written, so neither part can hold a
/// tab or a line break. Read when the host starts (`ClientHost
/// .useProjectMemory`), written when the developer chooses. The scripted
/// modes have none.
public struct ProjectMemory: Sendable, Equatable {
    public let path: String

    public init(path: String) { self.path = path }

    /// The file in a support directory.
    public init(supportDirectory: String) { path = supportDirectory + "/project-directories" }

    public struct Entry: Sendable, Equatable {
        public let name: String
        public let directory: String
    }

    /// One entry's line (without its line break), or nil when it cannot be
    /// one: a name `ClientHost.isTargetName` refuses, or a directory that is
    /// not absolute or holds a control character.
    public static func line(_ name: String, _ directory: String) -> String? {
        guard ClientHost.isTargetName(name), directory.hasPrefix("/"), directory.utf8.count <= 1024,
              !directory.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        return name + "\t" + directory
    }

    /// The entries of a file's text: malformed lines ignored, the last of
    /// a name's lines standing.
    public static func parse(_ text: String) -> [Entry] {
        var out: [Entry] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if raw.hasPrefix("#") { continue }
            let f = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 2, line(f[0], f[1]) != nil else { continue }
            out.removeAll { $0.name == f[0] }
            out.append(Entry(name: f[0], directory: f[1]))
        }
        return out
    }

    /// What the file holds (nothing when there is none, it is not UTF-8 or
    /// it is past 1 MiB).
    public func load() -> [Entry] {
        guard let d = FileManager.default.contents(atPath: path), d.count < 1 << 20,
              let text = String(data: d, encoding: .utf8) else { return [] }
        return ProjectMemory.parse(text)
    }

    /// `name`'s directory from now on. False when it cannot be a line or
    /// the file cannot be written.
    @discardableResult
    public func remember(_ name: String, _ directory: String) -> Bool {
        guard ProjectMemory.line(name, directory) != nil else { return false }
        var entries = load().filter { $0.name != name }
        entries.append(Entry(name: name, directory: directory))
        return write(entries)
    }

    /// The names' entries gone.
    @discardableResult
    public func forget(_ names: [String]) -> Bool {
        write(load().filter { !names.contains($0.name) })
    }

    func write(_ entries: [Entry]) -> Bool {
        var text = "# Kajo: each target's project directory (name, a tab, the directory)\n"
        for e in entries {
            guard let l = ProjectMemory.line(e.name, e.directory) else { continue }
            text += l + "\n"
        }
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
