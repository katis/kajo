import Foundation
import Synchronization
import Testing
@testable import KajoCompiler
@testable import KajoDev
@testable import KajoVM
@testable import KajoShellCore

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
