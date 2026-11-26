// Types 2 (docs/modules/types-2.md): the type checker as a package of its
// own (types/), in the image whose code it checks. Its SUnit tests pass in
// the development image; the development protocol's diagnostics request
// answers its three scopes and refuses what is malformed, the
// diagnostics.changed event follows a change, a target without the package
// refuses the request as an unknown one, the MCP server offers it, and a
// release image holds no class of the checker and no signature's text.

import Foundation
import Testing
@testable import KajoCompiler
@testable import KajoDev
@testable import KajoVM

/// The kernel, the Types package and the fixture project (package Sample).
let typesProjectImage: [UInt8] = {
    try! KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, typesDirectory, projectFixtureDirectory])).image
}()

/// A wait for the checker to have checked the whole image (the first
/// request does it): long everywhere, longer under the sanitizer.
let typesWait: Double = compilerTestsUnderThreadSanitizer ? 3600 : 600

@Suite(.serialized) struct TypeCheckerTests {
    /// Check time: under the sanitizer in the weekly run only (its 33
    /// SUnit tests on the development image took 1132 to 1532 s there with
    /// twelve loops and ended the compiler tests' shard); every tier's plain
    /// gate runs it, and the Smalltalk tier's tools-test runs the same tests.
    @Test(.weeklyUnderSanitizer("TypeCheckerTests.theTypesPackage"))
    func theTypesPackageBuildsAndItsTestsPass() throws {
        let r = try KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, toolsDirectory, typesDirectory]))
        #expect(r.warnings.isEmpty, "\(r.warnings)")
        var total = 0
        for name in ["TypeCheckerTest", "ProtocolTypeTest", "TypeServiceTest"] {
            let t0 = Date()
            let (result, lines) = runKernelTests(developmentImage, ["--filter", "\(name)>>*"])
            let report = TestReport(lines)
            #expect(try result.get() == 0, "\(name): \(report.failures.prefix(3))")
            #expect(report.total > 0 && report.passed == report.total, "\(name)")
            print("types-tests \(name) total=\(report.total) passed=\(report.passed) body_s=\(String(format: "%.1f", Date().timeIntervalSince(t0)))")
            total += report.total
        }
        #expect(total == 33)
    }

    /// Check time: under the sanitizer in the weekly run only (its
    /// whole-image check was 1047 s there); every tier's plain gate runs it.
    @Test(.weeklyUnderSanitizer("TypeCheckerTests.theDiagnosticsRequest"))
    func theDiagnosticsRequestAnswersItsScopesAndTheEventFollowsAChange() throws {
        let t = try RunningTarget(typesProjectImage)
        defer { t.close() }
        let c = try t.session("agent:types", package: nil)
        // the image: the first request starts the checker and waits for it
        let all = try c.request("diagnostics", [], timeout: typesWait, margin: #function)
        let diags = all["diagnostics"]?.array ?? []
        #expect(all["count"]?.int == Int64(diags.count) && diags.count > 0 && (all["checked"]?.int ?? 0) > 2000, "\(all["count"] ?? .null)")
        #expect(diags.contains { $0["class"]?.string == "TypeCheckerSample" && $0["selector"]?.string == "badReturn" })
        // a class: both sides, its own diagnostics only
        let cls = try c.request("diagnostics", [("className", .string("TypeCheckerSample"))], timeout: typesWait)
        let cd = cls["diagnostics"]?.array ?? []
        #expect(!cd.isEmpty && cd.allSatisfy { $0["class"]?.string == "TypeCheckerSample" })
        // a method: its one diagnostic with kind, side, line, range and text
        let m = try c.request("diagnostics", [("className", .string("TypeCheckerSample")), ("selector", .string("badReturn"))], timeout: typesWait)
        let md = m["diagnostics"]?.array ?? []
        #expect(md.count == 1, "\(md)")
        if let d = md.first {
            #expect(d["kind"]?.string == "returnType" && d["side"]?.string == "instance" && d["line"]?.int == 2)
            #expect(d["start"]?.int != nil && d["end"]?.int != nil && d["text"]?.string == "answers String | Nil where String is declared", "\(d)")
        }
        // a signature without a method, on the class side of nothing: a signature of Integer
        let s = try c.request("diagnostics", [("className", .string("Integer")), ("selector", .string("bitAnd:")), ("side", .string("instance"))], timeout: typesWait)
        #expect(s["count"]?.int == 0 && s["checked"]?.int == 1)
        // malformed requests are replies
        for args: [(String, JSONValue)] in [[("className", .string("TypeCheckerSample")), ("side", .string("sideways"))],
                                             [("selector", .string("badReturn"))],
                                             [("className", .string("NoSuchClassAnywhere"))],
                                             [("className", .int(3))],
                                             [("nonsense", .bool(true))]] {
            let r = try c.send("diagnostics", args, timeout: typesWait)
            #expect(r["ok"] == .bool(false) && r["error"]?.string?.isEmpty == false, "\(args): \(r)")
        }
        // a change: the background recheck emits diagnostics.changed
        let mark = c.eventMark
        _ = try c.request("method.compile", [("className", .string("TypeCheckerSample")), ("source", .string("badReturn ^<String>\n\t^ 'fixed'")),
                                             ("category", .string("samples")), ("side", .null)], timeout: 60, margin: #function)
        let e = c.waitForEvent(since: mark, timeout: typesWait) { $0["kind"]?.string == "diagnostics.changed" }
        #expect(e != nil)
        if let e {
            #expect((e["methods"]?.array ?? []).contains(.string("TypeCheckerSample>>badReturn")), "\(e)")
            #expect(e["count"]?.int != nil && e["pass"]?.int != nil)
        }
        let after = try c.request("diagnostics", [("className", .string("TypeCheckerSample")), ("selector", .string("badReturn"))], timeout: typesWait)
        #expect(after["count"]?.int == 0)        // the MCP server offers the request (on the same target: one whole check)
        try mcpOffersTheRequest(t)
    }

    @Test func aTargetWithoutTheCheckerRefusesTheRequest() throws {
        let t = try RunningTarget(projectImage)
        defer { t.close() }
        let c = try t.session()
        let r = try c.send("diagnostics", [], timeout: 60)
        #expect(r["ok"] == .bool(false) && r["error"]?.string?.hasPrefix("unknown request diagnostics") == true, "\(r)")
        let kinds = (try c.request("protocol.describe", [], timeout: 60).array ?? []).compactMap { $0["kind"]?.string }
        #expect(!kinds.contains("diagnostics") && kinds.contains("method.compile"))
    }

    /// The MCP server lists the request as a tool and a call of it answers.
    func mcpOffersTheRequest(_ t: RunningTarget) throws {
        var o = try ClientOptions(["--target", t.path, "--token", t.target.server.token, "--client", "agent:types-mcp"])
        o.timeout = typesWait
        var out: [JSONValue] = []
        let server = MCPServer(options: o) { line in
            if case .success(let v) = parseJSON(Array(line.utf8), limits: { var l = JSONLimits(); l.bytes = 64 << 20; l.stringBytes = 64 << 20; return l }()) {
                out.append(v)
            }
        }
        let script = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"diagnostics","arguments":{"className":"TypeCheckerSample","selector":"badAssign"}}}"#,
        ]
        var k = 0
        _ = server.serve { k < script.count ? { k += 1; return script[k - 1] }() : nil }
        let tools = out.first { $0["id"] == .int(2) }?["result"]?["tools"]?.array ?? []
        let tool = tools.first { $0["name"]?.string == "diagnostics" }
        #expect(tool != nil)
        #expect(tool?["inputSchema"]?["properties"]?["className"] != nil)
        let call = out.first { $0["id"] == .int(3) }?["result"]
        #expect(call?["isError"] == .bool(false))
        let text = call?["content"]?.array?.first?["text"]?.string ?? ""
        #expect(text.contains("\"assignType\"") && text.contains("badAssign"), "\(text)")
    }

    /// A release image (the kernel alone, as a generated app's Release
    /// build makes it) holds no class of the checker and no signature's
    /// text; the development build of the kernel and the package holds both.
    @Test func aReleaseImageHoldsNoCheckerAndNoSignature() throws {
        var options = KernelBuild.Options()
        options.release = true
        let release = try KernelBuild.build(KernelBuild.sources(in: [kernelDirectory]), options: options).image
        let development = try KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, typesDirectory])).image
        let marks = ["TypeChecker", "MethodTypeCheck", "TypeService", "bitXor: anInteger <Integer> ^<Integer>"]
        for mark in marks {
            #expect(occurrences(mark, release) == 0, "\(mark) in the release image")
            #expect(occurrences(mark, development) > 0, "\(mark) not in the development image")
        }
    }
}
