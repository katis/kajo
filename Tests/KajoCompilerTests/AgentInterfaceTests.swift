// Module 9b: the agent interface and sources to the project directory.
// An MCP session drives a target the way an agent would; the project
// directory a session wrote builds an image equal to the one it edited.

import Foundation
import Testing
@testable import KajoCompiler
@testable import KajoDev
@testable import KajoVM

/// Copy the fixture project into a fresh directory.
func projectCopy(_ name: String) throws -> URL {
    let dir = try temporaryDirectory(name)
    for f in try FileManager.default.contentsOfDirectory(atPath: projectFixtureDirectory) {
        try FileManager.default.copyItem(atPath: (projectFixtureDirectory as NSString).appendingPathComponent(f),
                                          toPath: dir.appendingPathComponent(f).path)
    }
    return dir
}

@Suite(.serialized) struct AgentInterfaceTests {
    @Test func theProjectWrittenOutIsTheProjectByteForByte() throws {
        let image = try Image.load(image: projectImage)
        defer { image.destroy() }
        let files = try FileManager.default.contentsOfDirectory(atPath: projectFixtureDirectory).filter { $0.hasSuffix(".st") && $0 != "package.st" }.sorted()
        let classes = files.map { $0.components(separatedBy: ".").first! }
        let texts = try smalltalkStrings(image, "evaluateStrings:", classes.map { "TonelWriter sourceOf: \($0) package: 'Sample'" })
        for (f, t) in zip(files, texts) {
            let original = try String(contentsOfFile: (projectFixtureDirectory as NSString).appendingPathComponent(f), encoding: .utf8)
            #expect(t == original, "\(f)")
        }
    }

    @Test func aSessionsProjectRebuildsTheImageItEdited() throws {
        let dir = try projectCopy("roundtrip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = try RunningTarget()
        defer { t.close() }
        let s = try t.session("agent:roundtrip", package: "Sample")
        let project = ProjectWriter(directory: dir.path)
        func change(_ kind: String, _ args: [(String, JSONValue)]) throws {
            do { try project.apply(try s.request(kind, args)) } catch { throw ProtocolError("\(kind): \(error)") }
        }
        try change("method.compile", [("className", .string("SampleCounter")), ("source", .string("decrement\n\tcount := self count - 1")),
                                      ("category", .string("accessing"))])
        try change("method.remove", [("className", .string("SampleCounter")), ("selector", .string("increment"))])
        try change("method.compile", [("className", .string("String")), ("source", .string("sampleShout\n\t^ self asUppercase , '!'")),
                                      ("category", .string("*Sample"))])
        try change("class.define", [("name", .string("SampleNew")), ("superclass", .string("SampleCounter")),
                                    ("instanceVariables", .string("x")), ("category", .string("Sample-New"))])
        try change("method.compile", [("className", .string("SampleNew")), ("source", .string("x\n\t^ x ifNil: [[:y | y + 1] value: 41]")),
                                      ("category", .string("accessing"))])
        try change("method.compile", [("className", .string("SampleNew")), ("source", .string("make\n\t^ self new")), ("side", .string("class")),
                                      ("category", .string("instance creation"))])
        try change("class.comment", [("className", .string("SampleNew")), ("comment", .string("Made by a \"session\"."))])
        let names = ["SampleCounter", "SampleNew", "String", "Object", "SampleDebug"]
        // Compared by size and hash (a reply's printString stops at 4000 bytes).
        let listingExpr = "(Smalltalk methodListsOf: #(\(names.joined(separator: " ")))) printString"
        let sourcesExpr = "(#(\(names.joined(separator: " "))) collect: [:n | (Smalltalk at: n) selectors asArray sort collect: [:sel | Smalltalk sourceOf: (Smalltalk at: n) >> sel]]) printString"
        func digest(_ e: String) -> String { "[:t | t byteSize printString , ' ' , t hash printString] value: (\(e))" }
        let listing = try s.eval(digest(listingExpr))["value"]?.string ?? ""
        let sources = try s.eval(digest(sourcesExpr))["value"]?.string ?? ""
        let authors = try s.eval("SampleNew class selectors asArray collect: [:sel | Smalltalk authorOfSelector: sel in: SampleNew class]")["value"]?.string ?? ""
        #expect(authors.contains("agent:roundtrip"))
        // The project's files build an image with the same methods.
        let rebuilt = try KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, dir.path])).image
        let image = try Image.load(image: rebuilt)
        defer { image.destroy() }
        let again = try smalltalkStrings(image, "evaluateStrings:", [
            digest(listingExpr), digest(sourcesExpr),
            "(SampleNew class selectors asArray collect: [:sel | Smalltalk authorOfSelector: sel in: SampleNew class]) printString",
            "SampleNew comment",
        ]).map { $0 }
        #expect(again[0] == listing.replacingOccurrences(of: "'", with: ""))
        #expect(again[1] == sources.replacingOccurrences(of: "'", with: ""))
        #expect(again[2] == authors)
        #expect(again[3] == "Made by a \"session\".")
        // And writes the same files back.
        for f in try FileManager.default.contentsOfDirectory(atPath: dir.path) where f.hasSuffix(".st") && f != "package.st" {
            let cls = f.components(separatedBy: ".").first!
            let text = try smalltalkStrings(image, "evaluateStrings:", ["TonelWriter sourceOf: \(cls) package: 'Sample'"])[0]
            #expect(text == (try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)), "\(f)")
        }
    }

    @Test func anAgentWorksThroughMCP() throws {
        let dir = try projectCopy("mcp")
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = try RunningTarget()
        defer { t.close() }
        var o = try ClientOptions(["--target", t.path, "--token", t.target.server.token, "--client", "agent:mcp-test",
                                   "--package", "Sample", "--project", dir.path])
        o.timeout = 60
        var out: [JSONValue] = []
        let server = MCPServer(options: o) { line in
            if case .success(let v) = parseJSON(Array(line.utf8), limits: { var l = JSONLimits(); l.bytes = 64 << 20; l.stringBytes = 64 << 20; return l }()) {
                out.append(v)
            }
        }
        var n: Int64 = 0
        func msg(_ method: String, _ params: JSONValue) -> String {
            n += 1
            return String(decoding: writeJSON(.object([("jsonrpc", .string("2.0")), ("id", .int(n)), ("method", .string(method)), ("params", params)])), as: UTF8.self)
        }
        func call(_ tool: String, _ args: [(String, JSONValue)]) -> String { msg("tools/call", .object([("name", .string(tool)), ("arguments", .object(args))])) }
        let script = [
            msg("initialize", .object([("protocolVersion", .string("2025-06-18"))])),
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
            msg("tools/list", .object([])),
            call("class_define", [("name", .string("SampleShape")), ("superclass", .string("Object")), ("instanceVariables", .string("side")),
                                  ("category", .string("Sample-Shapes"))]),
            call("method_compile", [("className", .string("SampleShape")), ("source", .string("side: n\n\tside := n")), ("category", .string("accessing"))]),
            call("class_define", [("name", .string("SampleShapeTest")), ("superclass", .string("TestCase")), ("category", .string("Sample-Tests"))]),
            call("method_compile", [("className", .string("SampleShapeTest")),
                                    ("source", .string("testArea\n\tself assert: (SampleShape new side: 3; area) = 9")), ("category", .string("tests"))]),
            call("test_run", [("filter", .string("SampleShapeTest*"))]),
            call("evaluate", [("source", .string("SampleDebug result: (SampleShape new side: 4; area)"))]),
            call("method_compile", [("className", .string("SampleShape")), ("source", .string("area\n\t^ side * side")), ("category", .string("accessing"))]),
            call("process_list", []),
        ]
        var lines = script[...]
        _ = server.serve { lines.popFirst() }
        #expect(out.count == script.count - 1)
        let tools = out[1]["result"]?["tools"]?.array ?? []
        #expect(tools.contains { $0["name"] == .string("method_compile") } && tools.contains { $0["name"] == .string("process_retrySend") })
        func text(_ i: Int) -> String {
            (out[i]["result"]?["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
        }
        #expect(out[2]["result"]?["isError"] == .bool(false))
        #expect(text(2).contains("sources written in"))
        // The test fails before area exists: one error, the events with it.
        #expect(text(6).contains("\"failuresAndErrors\":1"))
        #expect(text(6).contains("test.errored") || text(6).contains("test.failed"))
        // The doit stops at doesNotUnderstand: #area; the event comes back.
        #expect(out[7]["result"]?["isError"] == .bool(true))
        #expect(text(7).contains("process.stopped"))
        let stoppedLine = text(7).split(separator: "\n").first { $0.contains("\"process.stopped\"") }.map(String.init) ?? ""
        guard case .success(let stopped) = parseJSON(Array(stoppedLine.utf8)), let p = stopped["process"] else {
            Issue.record("no process.stopped: \(text(7))"); return
        }
        // Fixed, the send retried, the test run again: it passes.
        var more = [
            call("process_retrySend", [("process", p)]),
            call("test_run", [("filter", .string("SampleShapeTest*"))]),
        ][...]
        out.removeAll()
        _ = server.serve { more.popFirst() }
        #expect(out.count == 2 && out[0]["result"]?["isError"] == .bool(false), "\(out)")
        #expect(text(1).contains("\"failuresAndErrors\":0"))
        let s = try t.session()
        try s.waitForResult("16")
        // Every change is in the project, marked with the agent.
        let shape = try String(contentsOf: dir.appendingPathComponent("SampleShape.class.st"), encoding: .utf8)
        #expect(shape.contains("SampleShape >> area [\n\t<author: #'agent:mcp-test'>\n") && !shape.contains("#author :"))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("SampleShapeTest.class.st").path))
    }
}
