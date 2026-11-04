import Foundation

// Module 9b: the `kajo` commands that speak the development protocol to a
// target (`--target <socket>`, the token from `--token` or KAJO_TOKEN):
// eval, compile, browse, debug, test (with --target), request, and mcp
// (MCP.swift). Each opens one session (`--client`, developer by default;
// `--package`, the package its changes go to), sends its requests, writes
// the changed sources into `--project <dir>` when given, and prints the
// result as JSON on stdout. Exit status 0 on success, 1 on an error reply,
// 2 on a usage or connection error.

public let clientUsage = """
       kajo eval    --target <socket> [--token T] [--receiver handle] '<statements>'
       kajo compile --target <socket> <Class> [--side class] [--category c] (--source '<method>' | --file <path>)
       kajo browse  --target <socket> [<Class> [<selector>]] [--side class]
       kajo debug   --target <socket> list | frames P | proceed P | restart P F | retry P | step P into|over|out [F]
                                      | terminate P | suspend P | eval P F '<statements>'
       kajo test    --target <socket> [--filter pattern] [--tag tag]
       kajo request --target <socket> <kind> ['{"argument": value, ...}']
       kajo mcp     --target <socket> [--token T] [--client agent:<name>] [--project dir] [--package P]
         (every one: [--token T] [--client developer|agent:<name>] [--package P] [--project dir] [--timeout s])
"""

public struct ClientOptions {
    public var target: String? = nil
    public var token: String? = ProcessInfo.processInfo.environment["KAJO_TOKEN"]
    public var client = "developer"
    public var package: String? = nil
    public var project: String? = nil
    public var timeout = 60.0
    public var rest: [String] = []
    public var flags: [String: String] = [:]

    /// Split the arguments: the common options, flags with values, the rest.
    public init(_ args: [String], flagsWithValues: Set<String> = []) throws {
        var i = 0
        func value() throws -> String {
            i += 1
            guard i < args.count else { throw ProtocolError("\(args[i - 1]) needs a value") }
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--target": target = try value()
            case "--token": token = try value()
            case "--client": client = try value()
            case "--package": package = try value()
            case "--project": project = try value()
            case "--timeout": timeout = Double(try value()) ?? 60
            default:
                if flagsWithValues.contains(a) { flags[a] = try value() } else { rest.append(a) }
            }
            i += 1
        }
    }

    public func connect() throws -> ProtocolClient {
        guard let target else { throw ProtocolError("--target <socket> is needed") }
        guard let token else { throw ProtocolError("the token is needed: --token or KAJO_TOKEN") }
        let c = try ProtocolClient(path: target)
        try c.open(token: token, client: client, package: package, timeout: timeout)
        return c
    }
}

public func printJSON(_ v: JSONValue) {
    FileHandle.standardOutput.write(Data(writeJSON(v) + [10]))
}

/// Run one client command; the exit status.
public func runClientCommand(_ command: String, _ args: [String]) -> Int32 {
    do {
        switch command {
        case "mcp":
            let o = try ClientOptions(args)
            var opts = o
            if !args.contains("--client") { opts.client = "agent:mcp" }
            return try MCPServer(options: opts).run()
        case "eval":
            let o = try ClientOptions(args, flagsWithValues: ["--receiver"])
            guard let source = o.rest.first else { throw ProtocolError("eval needs the statements") }
            let c = try o.connect()
            defer { c.close() }
            var a: [(String, JSONValue)] = [("source", .string(source))]
            if let h = o.flags["--receiver"], let n = Int64(h) { a.append(("receiver", .int(n))) }
            return finish(try c.send("evaluate", a, timeout: o.timeout), o)
        case "compile":
            let o = try ClientOptions(args, flagsWithValues: ["--side", "--category", "--source", "--file"])
            guard let cls = o.rest.first else { throw ProtocolError("compile needs a class") }
            var source = o.flags["--source"]
            if let f = o.flags["--file"] {
                guard let d = FileManager.default.contents(atPath: f), let s = String(data: d, encoding: .utf8) else {
                    throw ProtocolError("cannot read \(f)")
                }
                source = s
            }
            guard let source else { throw ProtocolError("compile needs --source or --file") }
            let c = try o.connect()
            defer { c.close() }
            var a: [(String, JSONValue)] = [("className", .string(cls)), ("source", .string(source))]
            if let s = o.flags["--side"] { a.append(("side", .string(s))) }
            if let s = o.flags["--category"] { a.append(("category", .string(s))) }
            return finish(try c.send("method.compile", a, timeout: o.timeout), o)
        case "browse":
            let o = try ClientOptions(args, flagsWithValues: ["--side"])
            let c = try o.connect()
            defer { c.close() }
            let side: JSONValue = o.flags["--side"].map { .string($0) } ?? .null
            switch o.rest.count {
            case 0: return finish(try c.send("class.list", [], timeout: o.timeout), o)
            case 1:
                let def = try c.send("class.definition", [("className", .string(o.rest[0]))], timeout: o.timeout)
                guard def["ok"] == .bool(true) else { return finish(def, o) }
                let sels = try c.request("class.selectors", [("className", .string(o.rest[0])), ("side", side)], timeout: o.timeout)
                printJSON(.object([("definition", def["result"] ?? .null), ("selectors", sels)]))
                return 0
            default:
                return finish(try c.send("method.source", [("className", .string(o.rest[0])), ("selector", .string(o.rest[1])),
                                                          ("side", side)], timeout: o.timeout), o)
            }
        case "test":
            let o = try ClientOptions(args, flagsWithValues: ["--filter", "--tag"])
            let c = try o.connect()
            defer { c.close() }
            c.onEvent = { e in
                if let k = e["kind"]?.string, k.hasPrefix("test.") || k.hasPrefix("run.") { printJSON(e) }
            }
            let r = try c.send("test.run", [("filter", o.flags["--filter"].map { .string($0) } ?? .null),
                                            ("tag", o.flags["--tag"].map { .string($0) } ?? .null)], timeout: max(o.timeout, 600))
            let status = finish(r, o)
            if status == 0, let n = r["result"]?["failuresAndErrors"]?.int, n > 0 { return 1 }
            return status
        case "request":
            let o = try ClientOptions(args)
            guard let kind = o.rest.first else { throw ProtocolError("request needs a kind") }
            var a: [(String, JSONValue)] = []
            if o.rest.count > 1 {
                guard case .success(.object(let fields)) = parseJSON(Array(o.rest[1].utf8)) else {
                    throw ProtocolError("the arguments are one JSON object")
                }
                a = fields
            }
            let c = try o.connect()
            defer { c.close() }
            return finish(try c.send(kind, a, timeout: o.timeout), o)
        case "debug":
            let o = try ClientOptions(args)
            guard let sub = o.rest.first else { throw ProtocolError("debug needs a command") }
            let c = try o.connect()
            defer { c.close() }
            let r = o.rest
            func pid(_ k: Int) throws -> JSONValue {
                guard r.count > k, let n = Int64(r[k]) else { throw ProtocolError("debug \(sub) needs a Process id") }
                return .int(n)
            }
            func frame(_ k: Int) -> JSONValue { r.count > k ? (Int64(r[k]).map { .int($0) } ?? .null) : .null }
            switch sub {
            case "list": return finish(try c.send("process.list", [], timeout: o.timeout), o)
            case "frames": return finish(try c.send("process.frames", [("process", try pid(1))], timeout: o.timeout), o)
            case "proceed": return finish(try c.send("process.proceed", [("process", try pid(1))], timeout: o.timeout), o)
            case "restart": return finish(try c.send("process.restart", [("process", try pid(1)), ("frame", frame(2))], timeout: o.timeout), o)
            case "retry": return finish(try c.send("process.retrySend", [("process", try pid(1))], timeout: o.timeout), o)
            case "terminate": return finish(try c.send("process.terminate", [("process", try pid(1))], timeout: o.timeout), o)
            case "suspend": return finish(try c.send("process.suspend", [("process", try pid(1))], timeout: o.timeout), o)
            case "eval":
                guard r.count > 3 else { throw ProtocolError("debug eval P F '<statements>'") }
                return finish(try c.send("process.evaluate", [("process", try pid(1)), ("frame", frame(2)), ("source", .string(r[3]))],
                                         timeout: o.timeout), o)
            case "step":
                guard r.count > 2 else { throw ProtocolError("debug step P into|over|out [F]") }
                let p = try pid(1)
                let mark = c.eventMark
                let reply = try c.send("process.step", [("process", p), ("mode", .string(r[2])), ("frame", frame(3))], timeout: o.timeout)
                guard reply["ok"] == .bool(true) else { return finish(reply, o) }
                if let e = c.waitForEvent(since: mark, timeout: o.timeout, { $0["kind"]?.string == "process.stopped" && $0["process"] == p }) {
                    printJSON(e)
                    return 0
                }
                throw ProtocolError("the Process did not stop again within \(o.timeout) s")
            default: throw ProtocolError("unknown debug command \(sub)")
            }
        default:
            throw ProtocolError("unknown command \(command)")
        }
    } catch {
        FileHandle.standardError.write(Data("kajo \(command): \(error)\n".utf8))
        return 2
    }
}

/// Print a reply's result (writing its files into the project), or its error.
func finish(_ reply: JSONValue, _ o: ClientOptions) -> Int32 {
    guard reply["ok"] == .bool(true) else {
        FileHandle.standardError.write(Data("error: \(reply["error"]?.string ?? "?")\n".utf8))
        return 1
    }
    let result = reply["result"] ?? .null
    if let dir = o.project {
        do {
            let done = try ProjectWriter(directory: dir).apply(result)
            if !done.isEmpty { FileHandle.standardError.write(Data("wrote \(done.joined(separator: " ")) in \(dir)\n".utf8)) }
        } catch {
            FileHandle.standardError.write(Data("cannot write the sources: \(error)\n".utf8))
            return 1
        }
    }
    printJSON(result)
    return 0
}
