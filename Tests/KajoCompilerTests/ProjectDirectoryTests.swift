// The project directory decided by the host (docs/modules/project-directory.md,
// the second review's primitives.F7): the image never names the directory
// the client transport writes a connection's files into. `connect` takes
// three arguments and a fourth is refused; the host holds each target's
// directory (`setProject`, keyed by the address `connect` resolves to) and
// answers it to the tools (`project`); the developer chooses one in the
// host's own panel (`chooseProject`, a fake here: no test opens a real
// panel); the Kajo app remembers the choices per target name in a file
// (`ProjectMemory`, in a temporary directory here). Every file a test
// writes is in a temporary directory.

import Darwin
import Foundation
import Synchronization
import Testing
@testable import KajoDev
@testable import KajoVM

/// A reply whose result carries one file to write.
func projectFileReply(_ name: String, _ text: String) -> String {
    #"{"v":1,"kind":"reply","id":"x","ok":true,"result":{"files":[{"path":"\#(name)","text":"\#(text)"}]}}"#
}

/// The names in a directory (nothing when it is gone).
func projectListing(_ dir: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
}

/// A client transport whose events are kept.
final class RecordingHost: @unchecked Sendable {
    let host = ClientHost()
    let events = Mutex<[ShellEvent]>([])
    init() {
        host.setSink { [weak self] ev in self?.events.withLock { $0.append(ev) } }
    }

    func call(_ op: String, _ args: [ShellValue], handle: Int = 0) -> ShellValue? {
        host.callback(ViewCall(op: op, handle: handle, arguments: args))
    }

    /// Connect and wait (60 s at most) for the connection's end: the fake
    /// target closes after its lines, and the files are written before the
    /// lines are posted, which is before the end. nil when refused.
    func connectAndWait(_ args: [ShellValue]) -> Int? {
        guard let conn = call("connect", args)?.int else { return nil }
        let end = ShellVM.now() + 60_000_000_000
        while ShellVM.now() < end && !events.withLock({ $0.contains { $0.kind == .lost && $0.target == Int(conn) } }) { usleep(2000) }
        return Int(conn)
    }

    var targetsEvents: [ShellEvent] { events.withLock { $0.filter { $0.kind == .targets } } }
}

@Suite struct ProjectDirectoryTests {
    /// Part 1, item 2: a fourth argument (a directory the image names) is
    /// refused and nothing is written: against a fake target whose reply
    /// carries `files`, the temporary directory the image named stays
    /// empty. On 64db65e the connection opened and the file appeared there.
    @Test func aConnectThatNamesADirectoryIsRefusedAndNothingIsWritten() throws {
        let path = socketNames.next()
        let named = try temporaryDirectory("project-named")
        defer { try? FileManager.default.removeItem(at: named) }
        let h = RecordingHost()
        h.host.addTarget(ClientHost.Target(name: "t", path: path, token: "t"))
        let listener = try FakeTarget(path: path, lines: [projectFileReply("Planted.class.st", "planted")])
        defer { listener.stop() }
        let conn = h.connectAndWait([.string("t"), .string("developer"), .nil, .string(named.path)])
        #expect(conn == nil, "a connect naming a directory was accepted")
        #expect(projectListing(named.path).isEmpty, "the image named a directory and the host wrote into it: \(projectListing(named.path))")
        h.host.closeAll()
    }

    /// Part 1, item 2: a target with a host-set directory receives its
    /// files, one without receives none, and two targets with two
    /// directories never cross.
    @Test func eachTargetWritesOnlyIntoItsOwnDirectory() throws {
        let pa = socketNames.next(), pb = socketNames.next(), pc = socketNames.next()
        let da = try temporaryDirectory("project-a"), db = try temporaryDirectory("project-b")
        defer {
            try? FileManager.default.removeItem(at: da)
            try? FileManager.default.removeItem(at: db)
        }
        let h = RecordingHost()
        h.host.addTarget(ClientHost.Target(name: "a", path: pa, token: "t"))
        h.host.addTarget(ClientHost.Target(name: "b", path: pb, token: "t"))
        h.host.addTarget(ClientHost.Target(name: "c", path: pc, token: "t"))
        #expect(try h.host.setProject(da.path, for: "a").get() == da.path)
        #expect(try h.host.setProject(db.path, for: pb).get() == db.path)
        let la = try FakeTarget(path: pa, lines: [projectFileReply("A.class.st", "a")])
        let lb = try FakeTarget(path: pb, lines: [projectFileReply("Tag/B.class.st", "b")])
        let lc = try FakeTarget(path: pc, lines: [projectFileReply("C.class.st", "c")])
        defer {
            la.stop()
            lb.stop()
            lc.stop()
        }
        #expect(h.connectAndWait([.string("a"), .string("developer"), .nil]) != nil)
        #expect(h.connectAndWait([.string(pb), .string("developer"), .string("Tools")]) != nil)
        #expect(h.connectAndWait([.string("c"), .string("developer"), .nil]) != nil)
        #expect(projectListing(da.path) == ["A.class.st"])
        #expect(projectListing(db.path) == ["Tag"])
        #expect(projectListing(db.path + "/Tag") == ["B.class.st"])
        #expect((try? String(contentsOfFile: da.path + "/A.class.st", encoding: .utf8)) == "a")
        // c has no directory: its reply wrote nothing, anywhere the test knows.
        #expect(!FileManager.default.fileExists(atPath: da.path + "/C.class.st"))
        #expect(!FileManager.default.fileExists(atPath: db.path + "/C.class.st"))
        #expect(h.events.withLock { $0.contains { $0.kind == .line && $0.value.string?.contains("\"C.class.st\"") == true } })
        h.host.closeAll()
    }

    /// Part 1, item 1: the setter takes only an absolute path of an
    /// existing directory (a link to one is followed); a name and its
    /// address name one entry.
    @Test func theSetterTakesOnlyAnExistingDirectoryAndANameIsItsAddress() throws {
        let base = try temporaryDirectory("project-setter")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let dir = base.path + "/dir"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        fm.createFile(atPath: base.path + "/file", contents: Data("x".utf8))
        try fm.createSymbolicLink(atPath: base.path + "/link-to-file", withDestinationPath: base.path + "/file")
        try fm.createSymbolicLink(atPath: base.path + "/link-to-dir", withDestinationPath: dir)
        try fm.createSymbolicLink(atPath: base.path + "/dangling", withDestinationPath: base.path + "/nothing")
        let path = socketNames.next()
        let h = RecordingHost()
        h.host.addTarget(ClientHost.Target(name: "phone", path: path, token: nil))
        let refused = ["relative/dir", "dir", "", base.path + "/missing", base.path + "/file", base.path + "/link-to-file",
                       base.path + "/dangling", dir + "/../dir", dir + "/./x", dir + "\tx", dir + "\nx"]
        for r in refused {
            guard case .failure(let why) = h.host.setProject(r, for: "phone") else {
                Issue.record("accepted \(r)")
                continue
            }
            #expect(!why.description.isEmpty)
        }
        #expect(h.host.project(for: "phone") == nil)
        // An unknown target is refused too.
        if case .success = h.host.setProject(dir, for: "nobody") { Issue.record("a target that does not resolve was given a directory") }
        // A link to a directory is a directory; a trailing slash goes.
        #expect(try h.host.setProject(base.path + "/link-to-dir/", for: "phone").get() == base.path + "/link-to-dir")
        // The name and its address are one entry, set by either.
        #expect(h.host.project(for: path) == base.path + "/link-to-dir")
        #expect(try h.host.setProject(dir, for: path).get() == dir)
        #expect(h.host.project(for: "phone") == dir)
        #expect(h.call("project", [.string("phone")]) == .string(dir))
        #expect(h.call("project", [.string(path)]) == .string(dir))
    }

    /// Part 1, item 3 and part 3: `project` answers the host's directory or
    /// nil; `chooseProject` asks the host's panel (a fake), sets what the
    /// setter takes, posts a `targets` event, refuses what the setter
    /// refuses, and answers nil without a panel or for an unknown target.
    @Test func theProjectOpsAnswerTheHostAndTheDeveloperChoosesInItsPanel() throws {
        let base = try temporaryDirectory("project-ops")
        defer { try? FileManager.default.removeItem(at: base) }
        let first = base.path + "/first", chosen = base.path + "/chosen"
        try FileManager.default.createDirectory(atPath: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: chosen, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: base.path + "/a-file", contents: Data())
        let path = socketNames.next()
        let h = RecordingHost()
        h.host.addTarget(ClientHost.Target(name: "app", path: path, token: nil))
        #expect(h.call("project", [.string("app")]) == nil)
        #expect(h.call("project", [.string("nobody")]) == nil)
        // No panel: nil.
        #expect(h.call("chooseProject", [.string("app")]) == nil)
        let answer = Mutex<String?>(nil)
        let asked = Mutex<[(String, String?)]>([])
        let notes = Mutex<[String?]>([])
        h.host.setDirectoryPrompt { prompt, current, done in
            asked.withLock { $0.append((prompt, current)) }
            let n = done(answer.withLock { $0 })
            notes.withLock { $0.append(n) }
        }
        // Cancelled: nothing held, no event.
        #expect(h.call("chooseProject", [.string("app")]) == .bool(false))
        #expect(h.host.project(for: "app") == nil && h.targetsEvents.isEmpty)
        // Chosen: held, the targets event posted, the answer says so.
        answer.withLock { $0 = first }
        #expect(h.call("chooseProject", [.string("app")]) == .bool(true))
        #expect(h.call("project", [.string("app")]) == .string(first))
        #expect(h.targetsEvents.count == 1 && h.targetsEvents.first?.value == .string("app"))
        // The panel is shown the directory held now.
        answer.withLock { $0 = base.path + "/a-file" }
        #expect(h.call("chooseProject", [.string("app")]) == .bool(true))
        #expect(asked.withLock { $0.last?.1 } == first)
        // A file is refused with why (the panel shows it); nothing changes.
        #expect(notes.withLock { $0.last ?? nil }?.contains("not a directory") == true)
        #expect(h.host.project(for: "app") == first && h.targetsEvents.count == 1)
        answer.withLock { $0 = "relative" }
        #expect(h.call("chooseProject", [.string(path)]) == .bool(true))
        #expect(h.host.project(for: "app") == first)
        answer.withLock { $0 = chosen }
        #expect(h.call("chooseProject", [.string(path)]) == .bool(true))
        #expect(h.call("project", [.string("app")]) == .string(chosen))
        #expect(h.targetsEvents.count == 2)
        // An unknown target never reaches the panel.
        let before = asked.withLock { $0.count }
        #expect(h.call("chooseProject", [.string("nobody")]) == nil)
        #expect(asked.withLock { $0.count } == before)
    }

    /// Every op with arguments of the wrong count or kind answers nil and
    /// never traps: one seeded run over every op of primitive 164. On
    /// 64db65e `targets` and `close` took any arguments and `connect`
    /// four.
    @Test func everyOpWithArgumentsOfTheWrongCountOrKindAnswersNil() throws {
        let h = RecordingHost()
        let path = socketNames.next()
        h.host.addTarget(ClientHost.Target(name: "t", path: path, token: "t"))
        let prompted = Mutex(0)
        h.host.setSecretPrompt { _, done in
            prompted.withLock { $0 += 1 }
            done(nil)
        }
        h.host.setDirectoryPrompt { _, _, done in
            prompted.withLock { $0 += 1 }
            _ = done(nil)
        }
        enum Kind { case string, int, any }
        // The shapes each op takes (count and kinds); nil is a package.
        let shapes: [String: [[Kind]]] = [
            "targets": [[]], "connect": [[.string, .string, .any]], "pairing": [[.string]], "project": [[.string]],
            "chooseProject": [[.string]], "send": [[.string]], "close": [[]], "timer": [[.int, .int]],
        ]
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return seed
        }
        let strings = ["t", path, "", "local", "tcp://127.0.0.1:1", "bonjour:x", "/tmp", "a\nb", String(repeating: "x", count: 400)]
        func value() -> ShellValue {
            switch next() % 6 {
            case 0: .nil
            case 1: .bool(next() % 2 == 0)
            case 2: .int(Int64(bitPattern: next()) >> Int64(next() % 63))
            case 3: .double([0.5, -1, 1e300, .nan, .infinity][Int(next() % 5)])
            default: .string(strings[Int(next() % UInt64(strings.count))])
            }
        }
        func fits(_ v: ShellValue, _ k: Kind) -> Bool {
            switch k {
            case .string: v.string != nil
            case .int: v.int != nil
            case .any: v == .nil || v.string != nil
            }
        }
        var tried = 0
        for op in shapes.keys.sorted() {
            for _ in 0..<300 {
                let args = (0..<Int(next() % 6)).map { _ in value() }
                if shapes[op]!.contains(where: { s in s.count == args.count && zip(s, args).allSatisfy { fits($1, $0) } }) { continue }
                tried += 1
                let r = h.call(op, args, handle: Int(next() % 3))
                #expect(r == nil, "\(op) \(args) answered \(String(describing: r))")
            }
        }
        #expect(tried > 1000)
        #expect(prompted.withLock { $0 } == 0)
        #expect(h.host.openConnections == 0)
    }

    /// Part 3: the remembered directories: written when chosen, read when
    /// the host starts, a vanished directory dropped (not created), a
    /// malformed line ignored, and never a path with a tab or a line break.
    @Test func theRememberedDirectoriesFile() throws {
        let base = try temporaryDirectory("project-memory")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let support = base.path + "/support"
        let keep = base.path + "/keep", gone = base.path + "/gone", phone = base.path + "/phone"
        for d in [keep, gone, phone] { try fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
        let memory = ProjectMemory(supportDirectory: support)
        #expect(memory.path == support + "/project-directories")
        #expect(memory.load().isEmpty)
        // Never a line with a tab or a line break in either part.
        #expect(ProjectMemory.line("a\tb", keep) == nil)
        #expect(ProjectMemory.line("ab", keep + "\tx") == nil)
        #expect(ProjectMemory.line("ab", keep + "\nx") == nil)
        #expect(ProjectMemory.line("a\nb", keep) == nil)
        #expect(ProjectMemory.line("ab", "relative") == nil)
        #expect(!memory.remember("ab", keep + "\nx"))
        // Written when chosen, through the host's panel.
        let path = socketNames.next()
        let h = RecordingHost()
        h.host.addTarget(ClientHost.Target(name: "app", path: path, token: nil))
        h.host.addTarget(ClientHost.Target(name: "old", path: socketNames.next(), token: nil))
        #expect(h.host.useProjectMemory(memory).isEmpty)
        h.host.setDirectoryPrompt { _, _, done in _ = done(keep) }
        #expect(h.call("chooseProject", [.string("app")]) == .bool(true))
        #expect(memory.load() == [ProjectMemory.Entry(name: "app", directory: keep)])
        h.host.setDirectoryPrompt { _, _, done in _ = done(gone) }
        #expect(h.call("chooseProject", [.string("old")]) == .bool(true))
        #expect(memory.load().count == 2)
        // A phone's Bonjour name the host has not seen yet, and lines that
        // are not entries, written by hand.
        var text = try String(contentsOfFile: memory.path, encoding: .utf8)
        text += "Joni’s iPhone\t\(phone)\n" + "no tab here\n" + "x\trelative\n" + "a\tb\tc\n" + "\t\(keep)\n" + "# a comment\n"
        try text.write(toFile: memory.path, atomically: true, encoding: .utf8)
        try fm.removeItem(atPath: gone)
        // Read when the next host starts: the vanished one dropped from the
        // file and not created, the malformed lines ignored.
        let h2 = RecordingHost()
        h2.host.addTarget(ClientHost.Target(name: "app", path: path, token: nil))
        h2.host.addTarget(ClientHost.Target(name: "old", path: socketNames.next(), token: nil))
        let notes = h2.host.useProjectMemory(memory)
        #expect(notes.count == 3, "\(notes)")
        #expect(h2.host.project(for: "app") == keep)
        #expect(h2.host.project(for: "old") == nil)
        #expect(!fm.fileExists(atPath: gone))
        #expect(h2.host.project(for: "bonjour:Joni’s iPhone") == phone)
        #expect(memory.load().map(\.name) == ["app", "Joni’s iPhone"])
        let written = try String(contentsOfFile: memory.path, encoding: .utf8)
        #expect(written.split(separator: "\n").allSatisfy { $0.hasPrefix("#") || $0.split(separator: "\t", omittingEmptySubsequences: false).count == 2 })
        // A choice made after the start is remembered too.
        h2.host.setDirectoryPrompt { _, _, done in _ = done(phone) }
        #expect(h2.call("chooseProject", [.string("old")]) == .bool(true))
        #expect(memory.load().contains(ProjectMemory.Entry(name: "old", directory: phone)))
        // A file past 1 MiB, or not UTF-8, holds nothing.
        try Data([0xFF, 0xFE, 0x09, 0x41]).write(to: URL(fileURLWithPath: memory.path))
        #expect(memory.load().isEmpty)
    }
}
