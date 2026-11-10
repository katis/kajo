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
