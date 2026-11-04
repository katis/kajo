// Module 9b: the development protocol's JSON (docs/modules/development-protocol.md).
// A small strict reader with bounds, so that whatever a connection sends is
// a value or a refusal, never a trap or an unbounded cost (the request
// fuzzer, `just fuzz protocol`, holds it to that), and a writer whose
// output is canonical: the target's transport hands the kernel only what
// this writer wrote from a value this reader accepted.

/// A JSON value. Objects keep their keys' order.
public indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.int(let x), .int(let y)): return x == y
        case (.double(let x), .double(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.array(let x), .array(let y)): return x == y
        case (.object(let x), .object(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields.first(where: { $0.0 == key })?.1 }
        return nil
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var int: Int64? { if case .int(let i) = self { i } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var object: [(String, JSONValue)]? { if case .object(let o) = self { o } else { nil } }
}

/// What the reader refuses past.
public struct JSONLimits: Sendable {
    public var bytes = 1 << 20
    public var depth = 16
    public var elements = 4096
    public var stringBytes = 1 << 20
    public init() {}
}

public struct JSONError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public let offset: Int
    public var description: String { "\(message) at byte \(offset)" }
}

/// Read one JSON value that is the whole of `bytes` (blanks around it
/// allowed). Integers are SmallInteger-sized (|n| < 2^62) or refused;
/// other numbers must be finite doubles; strings must be valid UTF-8 with
/// valid escapes (no lone surrogate, no NUL).
public func parseJSON(_ bytes: [UInt8], limits: JSONLimits = JSONLimits()) -> Result<JSONValue, JSONError> {
    if bytes.count > limits.bytes { return .failure(JSONError(message: "longer than \(limits.bytes) bytes", offset: 0)) }
    var r = JSONReader(bytes: bytes, limits: limits)
    do {
        r.skip()
        let v = try r.value(depth: 0)
        r.skip()
        guard r.i == bytes.count else { throw r.fail("text after the value") }
        return .success(v)
    } catch let e as JSONError {
        return .failure(e)
    } catch {
        return .failure(JSONError(message: "\(error)", offset: r.i))
    }
}

struct JSONReader {
    let bytes: [UInt8]
    let limits: JSONLimits
    var i = 0

    func fail(_ m: String) -> JSONError { JSONError(message: m, offset: i) }

    mutating func skip() {
        while i < bytes.count, bytes[i] == 32 || bytes[i] == 9 || bytes[i] == 10 || bytes[i] == 13 { i += 1 }
    }

    mutating func literal(_ word: String, _ v: JSONValue) throws -> JSONValue {
        let w = Array(word.utf8)
        guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { throw fail("expected \(word)") }
        i += w.count
        return v
    }

    mutating func value(depth: Int) throws -> JSONValue {
        guard depth <= limits.depth else { throw fail("nested deeper than \(limits.depth)") }
        guard i < bytes.count else { throw fail("expected a value") }
        switch bytes[i] {
        case 123: return try object(depth: depth)
        case 91: return try array(depth: depth)
        case 34: return .string(try string())
        case 116: return try literal("true", .bool(true))
        case 102: return try literal("false", .bool(false))
        case 110: return try literal("null", .null)
        case 45, 48...57: return try number()
        default: throw fail("expected a value")
        }
    }

    mutating func object(depth: Int) throws -> JSONValue {
        i += 1
        var fields: [(String, JSONValue)] = []
        skip()
        if i < bytes.count && bytes[i] == 125 {
            i += 1
            return .object(fields)
        }
        while true {
            skip()
            guard i < bytes.count, bytes[i] == 34 else { throw fail("expected a key") }
            let k = try string()
            if fields.contains(where: { $0.0 == k }) { throw fail("the key \(k) twice") }
            skip()
            guard i < bytes.count, bytes[i] == 58 else { throw fail("expected :") }
            i += 1
            skip()
            fields.append((k, try value(depth: depth + 1)))
            if fields.count > limits.elements { throw fail("more than \(limits.elements) members") }
            skip()
            guard i < bytes.count else { throw fail("unterminated object") }
            if bytes[i] == 44 { i += 1; continue }
            if bytes[i] == 125 { i += 1; return .object(fields) }
            throw fail("expected , or }")
        }
    }

    mutating func array(depth: Int) throws -> JSONValue {
        i += 1
        var out: [JSONValue] = []
        skip()
        if i < bytes.count && bytes[i] == 93 {
            i += 1
            return .array(out)
        }
        while true {
            skip()
            out.append(try value(depth: depth + 1))
            if out.count > limits.elements { throw fail("more than \(limits.elements) elements") }
            skip()
            guard i < bytes.count else { throw fail("unterminated array") }
            if bytes[i] == 44 { i += 1; continue }
            if bytes[i] == 93 { i += 1; return .array(out) }
            throw fail("expected , or ]")
        }
    }

    mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count else { throw fail("a short \\u escape") }
        var v: UInt32 = 0
        for k in 0..<4 {
            let b = bytes[i + k]
            let d: UInt32
            switch b {
            case 48...57: d = UInt32(b - 48)
            case 65...70: d = UInt32(b - 55)
            case 97...102: d = UInt32(b - 87)
            default: throw fail("a bad \\u escape")
            }
            v = v << 4 | d
        }
        i += 4
        return v
    }

    mutating func string() throws -> String {
        i += 1
        var out: [UInt8] = []
        while true {
            guard i < bytes.count else { throw fail("unterminated string") }
            let b = bytes[i]
            if b == 34 { i += 1; break }
            if b < 32 { throw fail("a control character in a string") }
            if b == 92 {
                i += 1
                guard i < bytes.count else { throw fail("unterminated escape") }
                let e = bytes[i]
                i += 1
                switch e {
                case 34: out.append(34)
                case 92: out.append(92)
                case 47: out.append(47)
                case 98: out.append(8)
                case 102: out.append(12)
                case 110: out.append(10)
                case 114: out.append(13)
                case 116: out.append(9)
                case 117:
                    var u = try hex4()
                    if (0xD800...0xDBFF).contains(u) {
                        guard i + 2 <= bytes.count, bytes[i] == 92, bytes[i + 1] == 117 else { throw fail("a lone surrogate") }
                        i += 2
                        let lo = try hex4()
                        guard (0xDC00...0xDFFF).contains(lo) else { throw fail("a lone surrogate") }
                        u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(u) {
                        throw fail("a lone surrogate")
                    }
                    guard u != 0, let scalar = Unicode.Scalar(u) else { throw fail("a NUL or bad character") }
                    out += Array(String(Character(scalar)).utf8)
                default: throw fail("a bad escape")
                }
            } else {
                out.append(b)
                i += 1
            }
            if out.count > limits.stringBytes { throw fail("a string longer than \(limits.stringBytes) bytes") }
        }
        guard let s = String(validating: out, as: UTF8.self) else { throw fail("a string not UTF-8") }
        return s
    }

    mutating func number() throws -> JSONValue {
        let start = i
        if bytes[i] == 45 { i += 1 }
        guard i < bytes.count, (48...57).contains(bytes[i]) else { throw fail("a bad number") }
        if bytes[i] == 48 {
            i += 1
        } else {
            while i < bytes.count, (48...57).contains(bytes[i]) { i += 1 }
        }
        var isInt = true
        if i < bytes.count, bytes[i] == 46 {
            isInt = false
            i += 1
            guard i < bytes.count, (48...57).contains(bytes[i]) else { throw fail("a bad number") }
            while i < bytes.count, (48...57).contains(bytes[i]) { i += 1 }
        }
        if i < bytes.count, bytes[i] == 101 || bytes[i] == 69 {
            isInt = false
            i += 1
            if i < bytes.count, bytes[i] == 43 || bytes[i] == 45 { i += 1 }
            guard i < bytes.count, (48...57).contains(bytes[i]) else { throw fail("a bad number") }
            while i < bytes.count, (48...57).contains(bytes[i]) { i += 1 }
        }
        guard i - start <= 64 else { throw fail("a number longer than 64 bytes") }
        let text = String(decoding: bytes[start..<i], as: UTF8.self)
        if isInt {
            guard let n = Int64(text), n > -(1 << 62), n < (1 << 62) else { throw fail("an integer out of range") }
            return .int(n)
        }
        guard let d = Double(text), d.isFinite else { throw fail("a number out of range") }
        return .double(d)
    }
}

/// The canonical text of a value: no blanks, keys in their order, strings
/// escaped as the kernel's writer does (`"` `\` and control characters).
public func writeJSON(_ v: JSONValue) -> [UInt8] {
    var out: [UInt8] = []
    appendJSON(&out, v)
    return out
}

public func appendJSONString(_ out: inout [UInt8], _ s: String) {
    out.append(34)
    for b in s.utf8 {
        switch b {
        case 34: out += [92, 34]
        case 92: out += [92, 92]
        case 10: out += [92, 110]
        case 13: out += [92, 114]
        case 9: out += [92, 116]
        case 0..<32:
            let hex = Array("0123456789abcdef".utf8)
            out += [92, 117, 48, 48, hex[Int(b >> 4)], hex[Int(b & 15)]]
        default: out.append(b)
        }
    }
    out.append(34)
}

func appendJSON(_ out: inout [UInt8], _ v: JSONValue) {
    switch v {
    case .null: out += Array("null".utf8)
    case .bool(let b): out += Array((b ? "true" : "false").utf8)
    case .int(let n): out += Array("\(n)".utf8)
    case .double(let d): out += Array("\(d)".utf8)
    case .string(let s): appendJSONString(&out, s)
    case .array(let a):
        out.append(91)
        for (k, x) in a.enumerated() {
            if k > 0 { out.append(44) }
            appendJSON(&out, x)
        }
        out.append(93)
    case .object(let fields):
        out.append(123)
        for (k, (name, x)) in fields.enumerated() {
            if k > 0 { out.append(44) }
            appendJSONString(&out, name)
            out.append(58)
            appendJSON(&out, x)
        }
        out.append(125)
    }
}
