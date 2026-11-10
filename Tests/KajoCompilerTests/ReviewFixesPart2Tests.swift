import Foundation
import Synchronization
import Testing
@testable import KajoCompiler
@testable import KajoDev
@testable import KajoVM
@testable import KajoShellCore
@testable import KajoAppDevelopment

/// The review fixes, part 2 (docs/modules/review-fixes.md "As built (part
/// 2)"): the protocol's net under every request (item 1).
@Suite(.serialized) struct ReviewFixesPart2ProtocolTests {
    /// Item 1 (kernel.F6): a request whose Process a VMError ends (a stack
    /// overflow, which ends a Process without unwinding) is answered with
    /// an error within a bound, and the target serves on. On 18e274f no
    /// reply came.
    @Test func aRequestEndedByAVMErrorIsAnswered() throws {
        let t = try RunningTarget()
        defer { t.close() }
        let s = try t.session()
        defer { s.close() }
        let r = try s.send("evaluate", [("source", .string("| b | b := nil. b := [:n | (b value: n + 1) + 1]. b value: 0"))],
                           timeout: compilerTestsUnderThreadSanitizer ? 600 : 120)
        #expect(r["ok"] == .bool(false))
        #expect(r["error"]?.string?.contains("ended without a reply") == true, "\(r)")
        #expect(try s.eval("3 + 4")["value"] == .string("7"))
    }

    /// Item 1: a request whose Process another Process terminates is
    /// answered (run:'s ensure: block). On 18e274f no reply came.
    @Test func aRequestWhoseProcessIsTerminatedIsAnswered() throws {
        let t = try RunningTarget()
        defer { t.close() }
        let s = try t.session()
        defer { s.close() }
        let source = "| me | me := ProcessorScheduler activeProcess. [(Delay forMilliseconds: 200) wait. me terminate] forkAt: 1. (Delay forSeconds: 600) wait. 1"
        let r = try s.send("evaluate", [("source", .string(source))], timeout: compilerTestsUnderThreadSanitizer ? 600 : 120)
        #expect(r["ok"] == .bool(false))
        #expect(r["error"]?.string?.contains("ended without a reply") == true, "\(r)")
        #expect(try s.eval("3 + 4")["value"] == .string("7"))
    }

    /// Item 1: a chain of 20 000 unary sends over the protocol is a reply
    /// (compiled, or refused), never a stack overflow or a lost request.
    @Test func aLongChainOverTheProtocolIsAReply() throws {
        let t = try RunningTarget()
        defer { t.close() }
        let s = try t.session()
        defer { s.close() }
        let source = "foo ^ 1" + String(repeating: " abs", count: 20_000)
        let r = try s.send("method.compile", [("className", .string("SampleCounter")), ("source", .string(source))],
                           timeout: compilerTestsUnderThreadSanitizer ? 1200 : 300)
        #expect(r["ok"] != nil, "\(r)")
        #expect(try s.eval("3 + 4")["value"] == .string("7"))
    }
}

/// The compilers' comparison over sources (items 2, 5, 6): one probe per
/// test over the project's kernel image.
func agreement(_ sources: [String]) throws -> [(String, String)] {
    let probe = try KernelCompilerProbe(image: projectImage, className: CompilerAgreement.className)
    let ctx = CompilerAgreement.context(classNames: probe.classNames)
    var out: [(String, String)] = []
    for s in sources {
        if let d = CompilerAgreement.compare(Array(s.utf8), probe: probe, context: ctx) { out.append((s, d)) }
    }
    return out
}

/// Item 2 (kernel.F7): one identifier rule. U+00D7, U+00B7, U+2192,
/// U+1F600, U+00A0, a combining mark (U+0301) and a non-ASCII digit
/// (U+0663), each at the start and inside an identifier, and two letters
/// for contrast (U+00E9, U+03BB): both compilers accept and refuse alike.
/// On 18e274f the kernel's scanner took every non-separator scalar above
/// 127 as a letter and accepted what the bootstrap refuses.
@Test func bothCompilersFollowOneIdentifierRule() throws {
    var sources: [String] = []
    for s in ["\u{D7}", "\u{B7}", "\u{2192}", "\u{1F600}", "\u{A0}", "\u{301}", "\u{663}", "\u{E9}", "\u{3BB}"] {
        for id in ["\(s)x", "x\(s)y", "x\(s)"] {
            sources.append("f | \(id) | \(id) := 3. ^ \(id)")
            sources.append("\(id) ^ 1")
            sources.append("f ^ #\(id)")
        }
    }
    let d = try agreement(sources)
    #expect(d.isEmpty, "\(d.count) disagree, the first: \(d.first.map { "\($0.0): \($0.1)" } ?? "")")
    // The rule itself, as primitive 171 answers it.
    #expect(IdentifierRule.classify(0xE9) == 1 && IdentifierRule.classify(0x663) == 2 && IdentifierRule.classify(0xD7) == 0)
    #expect(IdentifierRule.classify(0x5F) == 1 && IdentifierRule.classify(0x30) == 2 && IdentifierRule.classify(0xD800) == 0)
}

/// Item 3 (kernel.F8): the bootstrap's Tonel reader finds the body's `[`
/// outside a comment in the pattern, as the kernel's does
/// (TonelTest>>testACommentInAPatternKeepsItsBrackets): the method reads
/// back as it was written. On 18e274f the comment's `[` was taken for the
/// body and the file was refused.
@Test func aCommentInAPatternKeepsItsBrackets() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("KajoVMTests/Fixtures/fuzz/syntax/pattern-comment.class.st")
    let text = try [UInt8](Data(contentsOf: url))
    let c = try readTonel(text, file: "pattern-comment.class.st")
    #expect(c.methods.count == 2)
    #expect(String(decoding: c.methods[0].source, as: UTF8.self) == "at: i \"index in [1, size]\" put: v\n\t^ v\n")
    #expect(String(decoding: c.methods[1].source, as: UTF8.self) == "foo\n\t^ 1\n")
    #expect(FuzzSyntax.run(text))
}

/// Item 5 (kernel.F14): every count a bytecode encodes, at its limit and
/// one past it, refused alike by both compilers (the make primitive's
/// verifier and bound behind the kernel's): a keyword send of 255 and 256
/// arguments, a block copying 255 and 256 values, 32 760 and 32 763 bytes
/// of bytecode, 4095 and 4096 literals (the source map counts). On
/// 18e274f the kernel's generator wrapped or raised a generic Error.
@Test func bothCompilersRefuseAtEveryEncodingLimit() throws {
    func keywordSend(_ n: Int) -> String { "f ^ self " + (1...n).map { "k\($0): 1" }.joined(separator: " ") }
    func copying(_ n: Int) -> String {
        // temps a block reads and nothing assigns: copied, not in a vector
        "f | " + (1...n).map { "t\($0)" }.joined(separator: " ") + " | ^ [" + (1...n).map { "t\($0)" }.joined(separator: ". ") + "]"
    }
    func chain(_ k: Int) -> String { "f ^ 1" + String(repeating: " abs", count: k) }
    func selectors(_ n: Int) -> String { "f " + (1...n).map { "self s\($0)" }.joined(separator: ". ") }
    // The big pairs (a method of 32 760 bytes, 4094 selectors) take minutes
    // in the Smalltalk compiler under ThreadSanitizer: the small ones there.
    let all = [keywordSend(255), keywordSend(256), copying(255), copying(256), chain(10_919), chain(10_920),
               selectors(4094), selectors(4095)]
    let cases = compilerTestsUnderThreadSanitizer ? Array(all.prefix(4)) : all
    let ctx0 = CompilerAgreement.context(classNames: Set(["Object"]))
    let accepted = cases.map { (try? compileMethod(Array($0.utf8), file: "limits", in: ctx0)) != nil }
    #expect(accepted == Array([true, false, true, false, true, false, true, false].prefix(cases.count)), "\(accepted)")
    let d = try agreement(cases)
    #expect(d.isEmpty, "\(d.count) disagree: \(d.map { "\($0.0.prefix(40))…: \($0.1.prefix(200))" })")
}

/// Item 6 (kernel.F15): the compilers' corpus, methods that exercise each
/// construct at and past its limits beyond the kernel's own methods
/// (literals at the SmallInteger boundary, every inlining decision with
/// SmallInteger and LargeInteger operands, the primitive pragma's rules,
/// names and scoping, nesting 31 to 33, 254 to 257 temps, block arities,
/// malformed sources), compiled by both compilers and compared bytecode
/// for bytecode in the plain form and refusal for refusal. On 18e274f the
/// kernel's compiler inlined a LargeInteger step, missed a LargeInteger
/// limit's hidden temp and accepted `<primitive: 0>` and two primitives.
@Test func bothCompilersAgreeOnTheCorpus() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/compiler-corpus/corpus.txt")
    var text = try String(contentsOf: url, encoding: .utf8)
    if text.hasSuffix("\n") { text.removeLast() }
    let sources = text.components(separatedBy: "\n\u{1E}\n")
    #expect(sources.count >= 150)
    let d = try agreement(sources)
    #expect(d.isEmpty, "\(d.count) of \(sources.count) disagree: \(d.map { "\($0.0.prefix(60)) => \($0.1.prefix(160))" }.joined(separator: " | "))")
}

/// Item 12 (tools.F6): the `sudo` line Install Command Line Tool shows
/// quotes every path, so an app under a path with a space or an apostrophe
/// gives a line that pastes: run through `sh` with `sudo` replaced by a
/// printer, each path is one word, as it was. On 18e274f the directory and
/// the link were unquoted.
@Test func theSudoLineQuotesItsPaths() throws {
    let fm = FileManager.default
    let d = fm.temporaryDirectory.appendingPathComponent("kajo-sudo-\(getpid())/Joni's Apps").path
    defer { try? fm.removeItem(atPath: (d as NSString).deletingLastPathComponent) }
    let cli = d + "/Kajo.app/Contents/Helpers/kajo"
    try fm.createDirectory(atPath: (cli as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    fm.createFile(atPath: cli, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    let bin = d + "/no such bin"
    guard case .needsPermission(let command) = CommandLineTool.install(cli: cli, into: bin) else { Issue.record("no command"); return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "sudo() { printf '[%s]\\n' \"$@\"; }; " + command]
    let out = Pipe()
    p.standardOutput = out
    try p.run()
    p.waitUntilExit()
    let words = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
    #expect(words == ["[mkdir]", "[-p]", "[\(bin)]", "[ln]", "[-sf]", "[\(cli)]", "[\(bin)/kajo]"], "\(words)")
}

/// Item 12 (tools.F6): eight launches installing one version at once never
/// label a complete checkout incomplete: each answers copied or present,
/// one complete checkout is left and nothing is moved aside. On 18e274f a
/// launch that found the folder another had just completed moved it aside.
@Test func concurrentInstallsLeaveOneCompleteCheckout() throws {
    let fm = FileManager.default
    let d = fm.temporaryDirectory.appendingPathComponent("kajo-install-race-\(getpid())").path
    defer { try? fm.removeItem(atPath: d) }
    let from = d + "/bundle/Kajo-0.9"
    for k in 0..<40 {
        try fm.createDirectory(atPath: from + "/dir\(k)", withIntermediateDirectories: true)
        fm.createFile(atPath: from + "/dir\(k)/f", contents: Data(repeating: UInt8(k), count: 8192))
    }
    for round in 0..<10 {
        let to = d + "/support/\(round)"
        let results = Mutex<[CheckoutInstall]>([])
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let r = CheckoutInstaller.install(from: from, to: to)
            results.withLock { $0.append(r) }
        }
        let rs = results.withLock { $0 }
        #expect(rs.allSatisfy { if case .failed = $0 { return false }; return true }, "\(rs)")
        #expect(fm.fileExists(atPath: to + "/" + CheckoutInstaller.marker))
        let aside = try fm.contentsOfDirectory(atPath: d + "/support").filter { $0.hasPrefix("\(round).incomplete-") || $0.hasPrefix("\(round).partial-") }
        #expect(aside.isEmpty, "round \(round): \(aside)")
    }
}

/// A Unix socket that accepts one connection, writes `bytes` to it and
/// holds it open until `stop` (item 13's targets).
final class HoldingTarget: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var conn: Int32 = -1
    let path: String

    init(path: String, bytes: [UInt8]) throws {
        self.path = path
        unlink(path)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = ProtocolServer.address(path)
        let r = withUnsafePointer(to: &addr) {
            unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard r == 0, listen(s, 1) == 0 else { throw ProtocolError("holding target: bind") }
        fd = s
        let t = Thread { [self] in
            let c = accept(s, nil, nil)
            guard c >= 0 else { return }
            var one: Int32 = 1
            _ = unsafe setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            conn = c
            lock.unlock()
            var off = 0
            while off < bytes.count {
                let n = bytes.withUnsafeBytes { unsafe write(c, $0.baseAddress! + off, min(65536, bytes.count - off)) }
                if n <= 0 { break }
                off += n
            }
        }
        t.start()
    }

    func stop() {
        lock.lock()
        let c = conn
        lock.unlock()
        if c >= 0 { close(c) }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(path)
    }
}

/// Item 13 (primitives.F8): a line from the target past the client's limit
/// (64 MiB, as the image's client and the server bound theirs) is
/// discarded to its end and the request waiting is answered with an error
/// at once, not left to grow the buffer until its timeout. On 18e274f the
/// client buffered the whole line and waited out the timeout.
@Test func aLineThatPassesTheClientsLimitIsAnAnswer() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("kajo-long-\(getpid()).sock").path
    let t = try HoldingTarget(path: path, bytes: [UInt8](repeating: 120, count: (64 << 20) + 4096) + [10])
    defer { t.stop() }
    let c = try ProtocolClient(path: path)
    defer { c.close() }
    let t0 = Date()
    #expect(throws: ProtocolError.self) { _ = try c.send("evaluate", [("source", .string("1"))], timeout: 120) }
    #expect(Date().timeIntervalSince(t0) < 100, "the request waited for its timeout")
}

/// Item 13: the client's descriptor is closed once, by whichever of its
/// reader and `close` ends second: a `close` while the reader is inside an
/// event's callback returns without closing it under the reader, and the
/// reader closes it when it ends. On 18e274f `close` closed it after 1 s
/// whether or not the reader had ended (the counter is the fix's).
@Test func theClientsDescriptorIsClosedOnceByWhoeverEndsLast() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("kajo-close-\(getpid()).sock").path
    let t = try HoldingTarget(path: path, bytes: Array(#"{"v":1,"kind":"log","text":"x"}"#.utf8) + [10])
    defer { t.stop() }
    let c = try ProtocolClient(path: path)
    let inCallback = DispatchSemaphore(value: 0)
    let seenInCallback = Mutex<Int>(-1)
    c.onEvent = { [c] _ in
        inCallback.signal()
        Thread.sleep(forTimeInterval: 1.5)
        seenInCallback.withLock { $0 = c.descriptorCloses }
    }
    #expect(inCallback.wait(timeout: .now() + 60) == .success)
    let t0 = Date()
    c.close()
    #expect(Date().timeIntervalSince(t0) < 1.0, "close waited for the reader")
    let end = Date(timeIntervalSinceNow: 60)
    while c.descriptorCloses == 0 && Date() < end { usleep(10_000) }
    #expect(seenInCallback.withLock { $0 } == 0, "the descriptor was closed under the reader")
    #expect(c.descriptorCloses == 1)
    c.close()
    #expect(c.descriptorCloses == 1)
}

/// Item 14 (the primitives report's note): the token store answers a new
/// token only when it was written whole and renamed into place, otherwise
/// the old one stands and the error says why; a token file anyone else
/// could read, or a link in its place, is replaced by a new token. The
/// assertions compare tokens and read lengths and modes, and print no
/// token (each comparison is a Bool). On 18e274f renew answered a token it
/// had not written, and load kept a token from a file of mode 0644.
@Test func theTokenStoreKeepsOnlyWhatItWroteAndRefusesAWideMode() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("kajo-token-\(getpid())").path
    try? fm.removeItem(atPath: dir)
    defer { _ = chmod(dir, 0o700); try? fm.removeItem(atPath: dir) }
    let store = PairingTokenStore(directory: dir)
    let first = store.load()
    #expect(first.utf8.count == 20)
    #expect(Bool(store.load() == first))
    #expect((try fm.attributesOfItem(atPath: store.path)[.posixPermissions] as? Int) == 0o600)
    // A directory that refuses the new file: renew throws, the old stands.
    #expect(chmod(dir, 0o500) == 0)
    #expect(throws: PairingTokenStore.StoreError.self) { _ = try store.renew() }
    #expect(chmod(dir, 0o700) == 0)
    #expect(Bool(store.load() == first))
    // A mode wider than 0600: replaced by a new token, written 0600.
    #expect(chmod(store.path, 0o644) == 0)
    let second = store.load()
    #expect(Bool(second != first) && second.utf8.count == 20)
    #expect((try fm.attributesOfItem(atPath: store.path)[.posixPermissions] as? Int) == 0o600)
    #expect(Bool(store.load() == second))
    // A link in the file's place: replaced, the link's target untouched.
    let elsewhere = dir + "/elsewhere"
    try Data(second.utf8).write(to: URL(fileURLWithPath: elsewhere))
    #expect(chmod(elsewhere, 0o600) == 0)
    try fm.removeItem(atPath: store.path)
    try fm.createSymbolicLink(atPath: store.path, withDestinationPath: elsewhere)
    let third = store.load()
    #expect(Bool(third != second))
    #expect((try fm.attributesOfItem(atPath: store.path)[.type] as? FileAttributeType) == .typeRegular)
    #expect(Bool(String(decoding: try Data(contentsOf: URL(fileURLWithPath: elsewhere)), as: UTF8.self) == second))
}
