// Module 9b: a request of the development protocol, checked before anything
// in the target sees it (the trust boundary of docs/modules/development-protocol.md
// and ADR 0011). A line is a request or a refusal the transport answers
// with an error reply; nothing a client sends can trap the target.

/// One request: `{"v":1,"id":...,"kind":"...","args":{...}}`.
public struct DevRequest: Sendable {
    /// A string (at most 256 bytes) or an integer: echoed in the reply.
    public let id: JSONValue
    /// Dotted lower-camel words (`protocol.describe`, `process.retrySend`).
    public let kind: String
    /// Names (lower-camel identifiers) and values, in the order sent.
    public let arguments: [(String, JSONValue)]

    public init(id: JSONValue, kind: String, arguments: [(String, JSONValue)]) {
        self.id = id
        self.kind = kind
        self.arguments = arguments
    }

    public subscript(name: String) -> JSONValue? { arguments.first(where: { $0.0 == name })?.1 }

    /// What the kernel reads (`DevProtocol dispatch:`): the canonical text.
    public var canonical: [UInt8] {
        writeJSON(.object([("id", id), ("kind", .string(kind)), ("args", .object(arguments))]))
    }

    /// The request line a client sends.
    public var line: [UInt8] {
        writeJSON(.object([("v", .int(1)), ("id", id), ("kind", .string(kind)), ("args", .object(arguments))]))
    }
}

/// Why a line is not a request; `id` when one could be read.
public struct RequestRefusal: Error, Sendable, CustomStringConvertible {
    public let id: JSONValue
    public let message: String
    public var description: String { message }
}

public enum RequestLimits {
    /// Module 10: a request line up to what one String of the image holds
    /// (16 MiB, the header's count field); 9b's was 1 MiB.
    public static let lineBytes = 1 << 24
    public static let kindBytes = 64
    public static let idBytes = 256
    public static let arguments = 32
    public static let nameBytes = 64
    /// What the image can take as one request: its canonical text is one
    /// String. Module 9c: one heap block (32 704 bytes); module 10: a
    /// String is a large object up to the header's count field, 16 MiB - 1.
    public static let imageBytes = (1 << 24) - 1
}

/// A lower-camel identifier: a lowercase ASCII letter, then letters and digits.
func isLowerCamel(_ s: Substring) -> Bool {
    guard let f = s.utf8.first, (97...122).contains(f) else { return false }
    return s.utf8.allSatisfy { (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0) }
}

public func isRequestKind(_ s: String) -> Bool {
    s.utf8.count <= RequestLimits.kindBytes && !s.isEmpty
        && s.split(separator: ".", omittingEmptySubsequences: false).allSatisfy(isLowerCamel)
}

/// Parse and check one request line.
public func parseRequest(_ line: [UInt8]) -> Result<DevRequest, RequestRefusal> {
    func refuse(_ m: String, _ id: JSONValue = .null) -> Result<DevRequest, RequestRefusal> {
        .failure(RequestRefusal(id: id, message: "malformed request: " + m))
    }
    guard line.count <= RequestLimits.lineBytes else { return refuse("longer than \(RequestLimits.lineBytes) bytes") }
    let value: JSONValue
    var limits = JSONLimits()
    limits.bytes = RequestLimits.lineBytes
    limits.stringBytes = RequestLimits.lineBytes
    switch parseJSON(line, limits: limits) {
    case .success(let v): value = v
    case .failure(let e): return refuse("\(e)")
    }
    guard case .object(let fields) = value else { return refuse("not a JSON object") }
    var id = JSONValue.null
    if let i = value["id"] {
        switch i {
        case .string(let s) where s.utf8.count <= RequestLimits.idBytes: id = i
        case .int: id = i
        default: return refuse("the id must be a string of at most \(RequestLimits.idBytes) bytes or an integer")
        }
    } else {
        return refuse("no id")
    }
    for (k, _) in fields where !["v", "id", "kind", "args"].contains(k) { return refuse("an unknown member \(k)", id) }
    guard value["v"] == .int(1) else { return refuse("\"v\" must be 1", id) }
    guard let kind = value["kind"]?.string, isRequestKind(kind) else {
        return refuse("the kind must be dotted lower-camel words of at most \(RequestLimits.kindBytes) bytes", id)
    }
    var args: [(String, JSONValue)] = []
    if let a = value["args"] {
        guard case .object(let o) = a else { return refuse("args must be an object", id) }
        guard o.count <= RequestLimits.arguments else { return refuse("more than \(RequestLimits.arguments) arguments", id) }
        for (name, v) in o {
            guard name.utf8.count <= RequestLimits.nameBytes, isLowerCamel(Substring(name)) else {
                return refuse("an argument name must be a lower-camel identifier", id)
            }
            args.append((name, v))
        }
    }
    return .success(DevRequest(id: id, kind: kind, arguments: args))
}

/// The reply a transport makes itself (a refusal, a session error).
public func errorReply(id: JSONValue, _ message: String) -> [UInt8] {
    writeJSON(.object([("v", .int(1)), ("kind", .string("reply")), ("id", id), ("ok", .bool(false)),
                       ("error", .string(message))]))
}

/// A client's name: `developer`, or `agent:` and a name of letters, digits,
/// `.`, `_` and `-` (at most 64 bytes). Recorded as the author of every
/// change the session makes.
public func isClientName(_ s: String) -> Bool {
    if s == "developer" { return true }
    guard s.hasPrefix("agent:") else { return false }
    let name = s.dropFirst(6)
    return !name.isEmpty && name.utf8.count <= 64
        && name.utf8.allSatisfy { (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 95 || $0 == 45 }
}

/// A package name: a letter, then letters, digits and `-` (at most 64 bytes).
public func isPackageName(_ s: String) -> Bool {
    guard let f = s.utf8.first, (97...122).contains(f) || (65...90).contains(f), s.utf8.count <= 64 else { return false }
    return s.utf8.allSatisfy { (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0) || $0 == 45 }
}
