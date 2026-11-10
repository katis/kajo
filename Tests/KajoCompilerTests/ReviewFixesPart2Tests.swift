import Foundation
import Testing
@testable import KajoCompiler
@testable import KajoDev
@testable import KajoVM

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
