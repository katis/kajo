import Foundation
import KajoVM

// Module 9b: the agent interface (docs/modules/development-protocol.md
// section 4): `kajo mcp --target <socket>` is an MCP server on stdin and
// stdout (JSON-RPC 2.0, one message per line) whose tools are the target's
// requests as `protocol.describe` lists them, so a new <devProtocol> method
// is a new tool with no change here. A tool call is one request; the
// events the target emitted meanwhile (transcript, tests, process.stopped)
// come back with its result, and the files a change touched are written
// into `--project`. The session is `agent:<name>` (`--client`), so every
// change it makes carries that author. What an agent may not do is the
// target's to refuse, not this server's.

public final class MCPServer {
    let options: ClientOptions
    private var client: ProtocolClient?
    private var kinds: [String: String] = [:]  // tool name -> request kind

    public init(options: ClientOptions) { self.options = options }

    static func toolName(_ kind: String) -> String { kind.replacingOccurrences(of: ".", with: "_") }

    private func connected() throws -> ProtocolClient {
        if let c = client, !c.isClosed { return c }
        let c = try options.connect()
        client = c
        return c
    }

    private func tools() throws -> JSONValue {
        let c = try connected()
        let described = try c.request("protocol.describe", [], timeout: options.timeout)
        var out: [JSONValue] = []
        kinds = [:]
        for d in described.array ?? [] {
            guard let kind = d["kind"]?.string else { continue }
            let name = MCPServer.toolName(kind)
            kinds[name] = kind
            var props: [(String, JSONValue)] = []
            for a in d["arguments"]?.array ?? [] {
                if let n = a.string { props.append((n, .object([("description", .string("\(n) (any JSON value; null or absent: none)"))]))) }
            }
            let comment = d["comment"]?.string ?? ""
            out.append(.object([
                ("name", .string(name)),
                ("description", .string("\(comment) [Kajo request \(kind)\(d["debuggable"] == .bool(true) ? "; an error stops the Process for the debugger" : "")]")),
                ("inputSchema", .object([("type", .string("object")), ("properties", .object(props)), ("additionalProperties", .bool(false))])),
            ]))
        }
        return .object([("tools", .array(out))])
    }

    private func call(_ params: JSONValue) throws -> JSONValue {
        guard let name = params["name"]?.string else { throw ProtocolError("tools/call needs a name") }
        if kinds[name] == nil { _ = try tools() }
        guard let kind = kinds[name] else { throw ProtocolError("no tool \(name)") }
        let c = try connected()
        let args = params["arguments"]?.object ?? []
        let mark = c.eventMark
        let reply = try c.send(kind, args, timeout: options.timeout)
        let ok = reply["ok"] == .bool(true)
        var content: [JSONValue] = []
        var extra: [String] = []
        if ok, let dir = options.project, let result = reply["result"] {
            let done = try ProjectWriter(directory: dir).apply(result)
            if !done.isEmpty { extra.append("sources written in \(dir): \(done.joined(separator: " "))") }
        }
        content.append(.object([("type", .string("text")),
                                ("text", .string(String(decoding: writeJSON(ok ? (reply["result"] ?? .null) : (reply["error"] ?? .null)), as: UTF8.self)))]))
        // A step answers at once and the stop follows; a stopped evaluate
        // answers with the stop and the event follows.
        if ok && kind == "process.step" {
            _ = c.waitForEvent(since: mark, timeout: options.timeout) { $0["kind"]?.string == "process.stopped" }
        } else if !ok, reply["error"]?.string?.hasPrefix("stopped") == true {
            _ = c.waitForEvent(since: mark, timeout: 5) { $0["kind"]?.string == "process.stopped" }
        }
        let events = c.events(since: mark)
        if !events.isEmpty {
            let text = events.map { String(decoding: writeJSON($0), as: UTF8.self) }.joined(separator: "\n")
            extra.append("events from the target:\n" + text)
        }
        for e in extra { content.append(.object([("type", .string("text")), ("text", .string(e))])) }
        return .object([("content", .array(content)), ("isError", .bool(!ok))])
    }

    private func respond(_ id: JSONValue, result: JSONValue) {
        write(.object([("jsonrpc", .string("2.0")), ("id", id), ("result", result)]))
    }

    private func respond(_ id: JSONValue, code: Int64, _ message: String) {
        write(.object([("jsonrpc", .string("2.0")), ("id", id),
                       ("error", .object([("code", .int(code)), ("message", .string(message))]))]))
    }

    private func write(_ v: JSONValue) {
        FileHandle.standardOutput.write(Data(writeJSON(v) + [10]))
    }

    /// Serve until stdin ends.
    public func run() throws -> Int32 {
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            var limits = JSONLimits()
            limits.bytes = 16 << 20
            limits.stringBytes = 16 << 20
            guard case .success(let msg) = parseJSON(Array(line.utf8), limits: limits) else {
                respond(.null, code: -32700, "parse error")
                continue
            }
            guard let method = msg["method"]?.string else { continue }
            guard let id = msg["id"], id != .null else { continue }  // a notification
            do {
                switch method {
                case "initialize":
                    let version = msg["params"]?["protocolVersion"]?.string ?? "2025-06-18"
                    respond(id, result: .object([
                        ("protocolVersion", .string(version)),
                        ("capabilities", .object([("tools", .object([("listChanged", .bool(false))]))])),
                        ("serverInfo", .object([("name", .string("kajo")), ("version", .string(KajoVM.version))])),
                        ("instructions", .string("Tools are the requests of a running Kajo image (Smalltalk). protocol_describe lists them. Changes you make are marked with your client name and written to the project directory.")),
                    ]))
                case "ping": respond(id, result: .object([]))
                case "tools/list": respond(id, result: try tools())
                case "tools/call": respond(id, result: try call(msg["params"] ?? .null))
                default: respond(id, code: -32601, "method not found: \(method)")
                }
            } catch {
                respond(id, code: -32000, "\(error)")
            }
        }
        client?.close()
        return 0
    }
}
