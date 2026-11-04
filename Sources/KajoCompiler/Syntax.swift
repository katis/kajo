import KajoVM

// Smalltalk method syntax: the scanner and the parser of the bootstrap
// compiler (module 8b). Smalltalk-80's grammar with Pharo's pragmas and
// dynamic arrays; no ScaledDecimal, no `_` assignment. The kernel's own
// Scanner and Parser (kernel/Scanner.class.st, Parser.class.st) read the
// same grammar and are checked against this one.
//
// Untrusted input: every malformed text is a `CompileError`, never a trap
// (the `fuzz-syntax` target holds the parser to that).

/// Why a method or a class file was refused. `line` is 1-based in the file.
public struct CompileError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public let file: String
    public let line: Int

    public init(_ message: String, file: String = "", line: Int = 0) {
        self.message = message
        self.file = file
        self.line = line
    }

    public var description: String { "\(file):\(line): \(message)" }
}

// MARK: - tokens

enum TokenKind: Equatable {
    case identifier(String)
    /// `foo:`
    case keyword(String)
    case binary(String)
    case integer(negative: Bool, magnitude: [UInt8])  // little-endian base 256
    case float(Double)
    case string([UInt8])
    case character(UInt32)
    /// `#foo`, `#foo:bar:`, `#+`, `#'any text'`
    case symbol(String)
    /// `#(`
    case literalArrayStart
    /// `#[`
    case byteArrayStart
    case assign
    case caret
    case period
    case semicolon
    case colon
    case leftParen, rightParen, leftBracket, rightBracket, leftBrace, rightBrace
    case bar
    case end
}

struct Token: Equatable {
    let kind: TokenKind
    let line: Int
    /// Byte offsets of the token in the source.
    let start: Int
    let end: Int
}

/// The binary selector characters (Smalltalk-80 plus Pharo's).
let binaryCharacterSet: Set<UInt8> = Set("+-*/\\<>=~&|@%,?!".utf8)

/// Bytes to tokens. Positions are byte offsets; identifiers are any Unicode
/// letters, digits and `_` (as kasm's).
struct Scanner {
    let bytes: [UInt8]
    let file: String
    var pos = 0
    var line: Int

    init(_ bytes: [UInt8], file: String, line: Int = 1) {
        self.bytes = bytes
        self.file = file
        self.line = line
    }

    func fail(_ m: String) -> CompileError { CompileError(m, file: file, line: line) }

    mutating func skipSpace() throws(CompileError) {
        while pos < bytes.count {
            let b = bytes[pos]
            if b == 10 { line += 1; pos += 1 }
            else if b == 32 || b == 9 || b == 13 || b == 12 { pos += 1 }
            else if b == 34 {  // a comment
                let startLine = line
                pos += 1
                while pos < bytes.count && bytes[pos] != 34 {
                    if bytes[pos] == 10 { line += 1 }
                    pos += 1
                }
                if pos >= bytes.count { throw CompileError("unterminated comment", file: file, line: startLine) }
                pos += 1
            } else { break }
        }
    }

    /// The scalar starting at `i` and its length; nil if the bytes are not UTF-8.
    func scalar(at i: Int) -> (UInt32, Int)? {
        guard i < bytes.count else { return nil }
        let b0 = bytes[i]
        if b0 < 0x80 { return (UInt32(b0), 1) }
        var n = 0
        var v: UInt32 = 0
        var minimum: UInt32 = 0
        switch b0 {
        case 0xC2...0xDF: n = 2; v = UInt32(b0 & 0x1F); minimum = 0x80
        case 0xE0...0xEF: n = 3; v = UInt32(b0 & 0x0F); minimum = 0x800
        case 0xF0...0xF4: n = 4; v = UInt32(b0 & 0x07); minimum = 0x10000
        default: return nil
        }
        guard i + n <= bytes.count else { return nil }
        for k in 1..<n {
            let b = bytes[i + k]
            guard b & 0xC0 == 0x80 else { return nil }
            v = v << 6 | UInt32(b & 0x3F)
        }
        guard v >= minimum, v <= 0x10FFFF, !(0xD800...0xDFFF).contains(v) else { return nil }
        return (v, n)
    }

    func isLetter(_ v: UInt32) -> Bool {
        if v < 0x80 { return (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v == 95 }
        return Unicode.Scalar(v)?.properties.isAlphabetic ?? false
    }

    func isDigit(_ v: UInt32) -> Bool { v >= 48 && v <= 57 }

    /// Letters, digits and `_` from `pos`.
    mutating func identifierRun() -> String {
        let s = pos
        while let (v, n) = scalar(at: pos), isLetter(v) || isDigit(v) || (v >= 0x80 && Unicode.Scalar(v)?.properties.numericType != nil) {
            pos += n
        }
        return String(decoding: bytes[s..<pos], as: UTF8.self)
    }

    mutating func next() throws(CompileError) -> Token {
        try skipSpace()
        let start = pos, ln = line
        func tok(_ k: TokenKind) -> Token { Token(kind: k, line: ln, start: start, end: pos) }
        guard pos < bytes.count else { return tok(.end) }
        let b = bytes[pos]
        guard let (v, n) = scalar(at: pos) else { throw fail("invalid UTF-8") }
        if isLetter(v) {
            let name = identifierRun()
            // a keyword: `name:` but not `name:=`
            if pos < bytes.count && bytes[pos] == 58 && !(pos + 1 < bytes.count && bytes[pos + 1] == 61) {
                pos += 1
                return tok(.keyword(name + ":"))
            }
            return tok(.identifier(name))
        }
        if isDigit(v) { return tok(try number()) }
        switch b {
        case 39:  // a string
            pos += 1
            return tok(.string(try quoted()))
        case 36:  // $c
            pos += 1
            guard let (c, cn) = scalar(at: pos) else { throw fail("a character literal needs a character") }
            pos += cn
            if c == 10 { line += 1 }
            return tok(.character(c))
        case 35:  // #
            pos += 1
            guard pos < bytes.count else { throw fail("a lone #") }
            let c = bytes[pos]
            if c == 40 { pos += 1; return tok(.literalArrayStart) }
            if c == 91 { pos += 1; return tok(.byteArrayStart) }
            if c == 39 {
                pos += 1
                let q = try quoted()
                guard let s = String(validating: q, as: UTF8.self) else { throw fail("invalid UTF-8") }
                return tok(.symbol(s))
            }
            if binaryCharacterSet.contains(c) {
                let s = pos
                while pos < bytes.count && binaryCharacterSet.contains(bytes[pos]) { pos += 1 }
                return tok(.symbol(String(decoding: bytes[s..<pos], as: UTF8.self)))
            }
            if let (sv, _) = scalar(at: pos), isLetter(sv) {
                var name = identifierRun()
                // keywords and colons: #at:put:, #a:b
                while pos < bytes.count && bytes[pos] == 58 {
                    pos += 1
                    name += ":"
                    if let (nv, _) = scalar(at: pos), isLetter(nv) { name += identifierRun() } else { break }
                }
                return tok(.symbol(name))
            }
            throw fail("bad symbol literal")
        case 58:  // : or :=
            pos += 1
            if pos < bytes.count && bytes[pos] == 61 { pos += 1; return tok(.assign) }
            return tok(.colon)
        case 94: pos += 1; return tok(.caret)
        case 46: pos += 1; return tok(.period)
        case 59: pos += 1; return tok(.semicolon)
        case 40: pos += 1; return tok(.leftParen)
        case 41: pos += 1; return tok(.rightParen)
        case 91: pos += 1; return tok(.leftBracket)
        case 93: pos += 1; return tok(.rightBracket)
        case 123: pos += 1; return tok(.leftBrace)
        case 125: pos += 1; return tok(.rightBrace)
        default:
            break
        }
        if binaryCharacterSet.contains(b) {
            let s = pos
            while pos < bytes.count && binaryCharacterSet.contains(bytes[pos]) {
                // `x--1` is x - -1: a minus before a digit starts a literal
                if pos > s && bytes[pos] == 45 && pos + 1 < bytes.count && bytes[pos + 1] >= 48 && bytes[pos + 1] <= 57 { break }
                pos += 1
            }
            let sel = String(decoding: bytes[s..<pos], as: UTF8.self)
            if sel == "|" { return tok(.bar) }
            return tok(.binary(sel))
        }
        _ = n
        throw fail("unexpected character U+\(String(v, radix: 16, uppercase: true))")
    }

    /// The body of a quoted string after the opening quote ('' is a quote).
    mutating func quoted() throws(CompileError) -> [UInt8] {
        var out: [UInt8] = []
        let startLine = line
        while true {
            guard pos < bytes.count else { throw CompileError("unterminated string", file: file, line: startLine) }
            let c = bytes[pos]
            if c == 39 {
                if pos + 1 < bytes.count && bytes[pos + 1] == 39 { out.append(39); pos += 2; continue }
                pos += 1
                break
            }
            if c == 10 { line += 1 }
            out.append(c)
            pos += 1
        }
        guard String(validating: out, as: UTF8.self) != nil else { throw fail("invalid UTF-8 in a string") }
        return out
    }

    /// Digits: `123`, `16r1F`, `1.5`, `1.5e10`, `2e3` (an Integer), `1e-3`
    /// (a Float).
    mutating func number() throws(CompileError) -> TokenKind {
        func digits(_ radix: Int) -> [Int] {
            var out: [Int] = []
            while pos < bytes.count {
                let c = Int(bytes[pos])
                let d: Int
                if c >= 48 && c <= 57 { d = c - 48 }
                else if c >= 65 && c <= 90 { d = c - 55 }
                else { break }
                if d >= radix { break }
                out.append(d)
                pos += 1
            }
            return out
        }
        var radix = 10
        var ds = digits(10)
        if pos < bytes.count && bytes[pos] == 114 {  // r
            let r = ds.reduce(0) { min($0 * 10 + $1, 1000) }
            guard r >= 2 && r <= 36 else { throw fail("radix \(r) not in 2...36") }
            pos += 1
            radix = r
            ds = digits(r)
            guard !ds.isEmpty else { throw fail("no digits after the radix") }
        }
        if ds.count > 4000 { throw fail("a number literal longer than 4000 digits") }
        var fraction: [Int] = []
        if radix == 10, pos + 1 < bytes.count, bytes[pos] == 46, bytes[pos + 1] >= 48, bytes[pos + 1] <= 57 {
            pos += 1
            fraction = digits(10)
        }
        var exponent: Int? = nil
        if radix == 10, pos < bytes.count, bytes[pos] == 101 {  // e
            var p = pos + 1
            var neg = false
            if p < bytes.count && bytes[p] == 45 { neg = true; p += 1 }
            if p < bytes.count && bytes[p] >= 48 && bytes[p] <= 57 {
                pos = p
                let e = digits(10).reduce(0) { min($0 * 10 + $1, 100_000) }
                exponent = neg ? -e : e
            }
        }
        if fraction.isEmpty && (exponent ?? 0) >= 0 {
            var mag: [UInt8] = []
            func mulAdd(_ m: Int, _ a: Int) {
                var carry = a
                for i in mag.indices {
                    let x = Int(mag[i]) * m + carry
                    mag[i] = UInt8(x & 0xFF)
                    carry = x >> 8
                }
                while carry > 0 { mag.append(UInt8(carry & 0xFF)); carry >>= 8 }
            }
            for d in ds { mulAdd(radix, d) }
            if let e = exponent {
                if e > 4000 { throw fail("an exponent larger than 4000") }
                for _ in 0..<e { mulAdd(10, 0) }
            }
            while mag.last == 0 { mag.removeLast() }
            return .integer(negative: false, magnitude: mag)
        }
        var text = ds.map { String($0) }.joined()
        if !fraction.isEmpty { text += "." + fraction.map { String($0) }.joined() }
        if let e = exponent { text += "e\(e)" }
        guard let d = Double(text), d.isFinite else { throw fail("float literal out of range") }
        return .float(d)
    }
}

// MARK: - the tree

/// A node of a method's tree. Classes, so the analysis can annotate them.
class Node {
    let line: Int
    init(line: Int) { self.line = line }
}

final class LiteralNode: Node {
    let value: Literal
    init(_ value: Literal, line: Int) {
        self.value = value
        super.init(line: line)
    }
}

final class VariableNode: Node {
    let name: String
    /// Set by the analysis.
    var binding: Binding = .unresolved
    init(_ name: String, line: Int) {
        self.name = name
        super.init(line: line)
    }
}

final class AssignNode: Node {
    let variable: VariableNode
    let value: Node
    init(_ variable: VariableNode, _ value: Node, line: Int) {
        self.variable = variable
        self.value = value
        super.init(line: line)
    }
}

final class SendNode: Node {
    let receiver: Node
    let selector: String
    let arguments: [Node]
    /// Set by the analysis: compiled as jumps (ifTrue:, whileTrue:, to:do:, ...).
    var inlined = false
    /// The hidden temps an inlined loop uses (the limit, a counter).
    var hidden: [Variable] = []
    init(_ receiver: Node, _ selector: String, _ arguments: [Node], line: Int) {
        self.receiver = receiver
        self.selector = selector
        self.arguments = arguments
        super.init(line: line)
    }
    var isSuper: Bool { (receiver as? VariableNode)?.name == "super" }
}

final class CascadeNode: Node {
    let receiver: Node
    let messages: [(selector: String, arguments: [Node], line: Int)]
    init(_ receiver: Node, _ messages: [(selector: String, arguments: [Node], line: Int)], line: Int) {
        self.receiver = receiver
        self.messages = messages
        super.init(line: line)
    }
}

final class ArrayNode: Node {
    let elements: [Node]
    init(_ elements: [Node], line: Int) {
        self.elements = elements
        super.init(line: line)
    }
}

final class BlockNode: Node {
    let arguments: [(name: String, line: Int)]
    let temporaries: [(name: String, line: Int)]
    let statements: [Statement]
    /// Set by the analysis.
    var scope: Scope!
    init(arguments: [(name: String, line: Int)], temporaries: [(name: String, line: Int)], statements: [Statement], line: Int) {
        self.arguments = arguments
        self.temporaries = temporaries
        self.statements = statements
        super.init(line: line)
    }
}

enum Statement {
    case expression(Node)
    case ret(Node, line: Int)
}

struct PragmaNode {
    let selector: String
    let arguments: [Literal]
    let line: Int
}

final class MethodNode {
    let selector: String
    let arguments: [(name: String, line: Int)]
    let temporaries: [(name: String, line: Int)]
    let pragmas: [PragmaNode]
    let statements: [Statement]
    let line: Int
    var scope: Scope!
    init(selector: String, arguments: [(name: String, line: Int)], temporaries: [(name: String, line: Int)],
         pragmas: [PragmaNode], statements: [Statement], line: Int) {
        self.selector = selector
        self.arguments = arguments
        self.temporaries = temporaries
        self.pragmas = pragmas
        self.statements = statements
        self.line = line
    }
}

// MARK: - the parser

/// Recursive descent over the scanner's tokens; one token of lookahead plus
/// a peek at the one after for keyword pragmas and block arguments.
struct Parser {
    var scanner: Scanner
    var token: Token
    /// Nesting of blocks, parentheses and literal arrays; refused past
    /// `maxDepth` so a hostile input cannot overflow the Swift stack.
    var depth = 0
    static let maxDepth = 256

    init(_ text: [UInt8], file: String, line: Int = 1) throws(CompileError) {
        scanner = Scanner(text, file: file, line: line)
        token = try scanner.next()
    }

    func fail(_ m: String) -> CompileError { CompileError(m, file: scanner.file, line: token.line) }

    mutating func advance() throws(CompileError) { token = try scanner.next() }

    mutating func expect(_ k: TokenKind, _ what: String) throws(CompileError) {
        guard token.kind == k else { throw fail("expected \(what)") }
        try advance()
    }

    mutating func enter() throws(CompileError) {
        depth += 1
        if depth > Parser.maxDepth { throw fail("nested deeper than \(Parser.maxDepth)") }
    }

    // method := pattern pragmas? temporaries? pragmas? statements
    mutating func parseMethod() throws(CompileError) -> MethodNode {
        let line = token.line
        var selector = ""
        var args: [(String, Int)] = []
        switch token.kind {
        case .identifier(let name):
            selector = name
            try advance()
        case .binary(let op):
            selector = op
            try advance()
            guard case .identifier(let a) = token.kind else { throw fail("expected an argument name") }
            args.append((a, token.line))
            try advance()
        case .bar:
            selector = "|"
            try advance()
            guard case .identifier(let a) = token.kind else { throw fail("expected an argument name") }
            args.append((a, token.line))
            try advance()
        case .keyword:
            while case .keyword(let k) = token.kind {
                selector += k
                try advance()
                guard case .identifier(let a) = token.kind else { throw fail("expected an argument name") }
                args.append((a, token.line))
                try advance()
            }
        default:
            throw fail("expected a message pattern")
        }
        var pragmas = try parsePragmas()
        let temps = try parseTemporaries()
        pragmas += try parsePragmas()
        let statements = try parseStatements(inBlock: false)
        guard token.kind == .end else { throw fail("unexpected text after the method's statements") }
        return MethodNode(selector: selector, arguments: args, temporaries: temps, pragmas: pragmas, statements: statements, line: line)
    }

    /// `<keyword: literal ...>` or `<unary>`; any number.
    mutating func parsePragmas() throws(CompileError) -> [PragmaNode] {
        var out: [PragmaNode] = []
        while case .binary("<") = token.kind {
            let line = token.line
            try advance()
            var selector = ""
            var args: [Literal] = []
            switch token.kind {
            case .identifier(let name):
                selector = name
                try advance()
            case .keyword:
                while case .keyword(let k) = token.kind {
                    selector += k
                    try advance()
                    args.append(try parsePragmaLiteral())
                }
            default:
                throw fail("expected a pragma")
            }
            guard case .binary(">") = token.kind else { throw fail("expected > to end the pragma") }
            try advance()
            out.append(PragmaNode(selector: selector, arguments: args, line: line))
        }
        return out
    }

    mutating func parsePragmaLiteral() throws(CompileError) -> Literal {
        if case .identifier(let n) = token.kind {
            switch n {
            case "nil": try advance(); return .nilObject
            case "true": try advance(); return .trueObject
            case "false": try advance(); return .falseObject
            default: throw fail("a pragma argument must be a literal")
            }
        }
        guard let l = try parseLiteralToken(allowNegative: true) else { throw fail("a pragma argument must be a literal") }
        return l
    }

    mutating func parseTemporaries() throws(CompileError) -> [(name: String, line: Int)] {
        var temps: [(String, Int)] = []
        if case .binary("||") = token.kind {  // `||`: no temporaries
            try advance()
            return []
        }
        guard token.kind == .bar else { return [] }
        try advance()
        while case .identifier(let n) = token.kind {
            temps.append((n, token.line))
            try advance()
        }
        guard token.kind == .bar else { throw fail("expected | to end the temporaries") }
        try advance()
        return temps
    }

    mutating func parseStatements(inBlock: Bool) throws(CompileError) -> [Statement] {
        var out: [Statement] = []
        while true {
            if token.kind == .end || (inBlock && token.kind == .rightBracket) { return out }
            if token.kind == .period { try advance(); continue }
            if token.kind == .caret {
                let line = token.line
                try advance()
                out.append(.ret(try parseExpression(), line: line))
                while token.kind == .period { try advance() }
                if token.kind == .end || (inBlock && token.kind == .rightBracket) { return out }
                throw fail("statements after a return")
            }
            out.append(.expression(try parseExpression()))
            if token.kind == .period { try advance(); continue }
            if token.kind == .end || (inBlock && token.kind == .rightBracket) { return out }
            throw fail("expected a period or the end of the statements")
        }
    }

    mutating func parseExpression() throws(CompileError) -> Node {
        if case .identifier(let name) = token.kind {
            // an assignment needs the token after the identifier
            let save = (scanner, token)
            let line = token.line
            try advance()
            if token.kind == .assign {
                try advance()
                try enter()
                defer { depth -= 1 }
                return AssignNode(VariableNode(name, line: line), try parseExpression(), line: line)
            }
            (scanner, token) = save
        }
        let receiver = try parsePrimary()
        return try parseCascade(receiver)
    }

    mutating func parseCascade(_ receiver: Node) throws(CompileError) -> Node {
        let first = try parseMessages(receiver)
        guard token.kind == .semicolon else { return first }
        guard let send = first as? SendNode else { throw fail("a cascade needs a message before ;") }
        var messages: [(selector: String, arguments: [Node], line: Int)] = [(send.selector, send.arguments, send.line)]
        while token.kind == .semicolon {
            try advance()
            let line = token.line
            // one message to the cascade's receiver: unary* binary* keyword?
            let placeholder = VariableNode("", line: line)
            guard let m = try parseMessages(placeholder) as? SendNode else { throw fail("expected a message after ;") }
            // flatten: the first message of the chain goes to the cascade's
            // receiver; further ones are not allowed without parentheses.
            guard m.receiver === placeholder else { throw fail("a cascade part is one message") }
            messages.append((m.selector, m.arguments, line))
        }
        return CascadeNode(send.receiver, messages, line: receiver.line)
    }

    /// unary* binary* keyword? applied to `receiver`.
    mutating func parseMessages(_ receiver: Node) throws(CompileError) -> Node {
        var r = try parseUnaryMessages(receiver)
        r = try parseBinaryMessages(r)
        if case .keyword = token.kind {
            let line = token.line
            var selector = ""
            var args: [Node] = []
            while case .keyword(let k) = token.kind {
                selector += k
                try advance()
                let a = try parsePrimary()
                args.append(try parseBinaryMessages(try parseUnaryMessages(a)))
            }
            r = SendNode(r, selector, args, line: line)
        }
        return r
    }

    /// Module 8d (the syntax fuzzer's make-and-run run): a chain of unary
    /// and binary sends is a left-deep tree, so a chain of thousands
    /// overflowed the Swift stack in code generation. A chain is held to
    /// the nesting limit like brackets are.
    func chainLength(_ n: Node) -> Int {
        var k = 0
        var x: Node = n
        while let s = x as? SendNode, k <= Parser.maxDepth {
            k += 1
            x = s.receiver
        }
        return k
    }

    mutating func parseUnaryMessages(_ receiver: Node) throws(CompileError) -> Node {
        var r = receiver
        var k = chainLength(r)
        while case .identifier(let name) = token.kind {
            r = SendNode(r, name, [], line: token.line)
            k += 1
            if k > Parser.maxDepth { throw fail("a message chain longer than \(Parser.maxDepth)") }
            try advance()
        }
        return r
    }

    mutating func parseBinaryMessages(_ receiver: Node) throws(CompileError) -> Node {
        var r = receiver
        var k = chainLength(r)
        while true {
            let op: String
            switch token.kind {
            case .binary(let b): op = b
            case .bar: op = "|"
            default: return r
            }
            let line = token.line
            try advance()
            let a = try parseUnaryMessages(try parsePrimary())
            r = SendNode(r, op, [a], line: line)
            k += 1
            if k > Parser.maxDepth { throw fail("a message chain longer than \(Parser.maxDepth)") }
        }
    }

    mutating func parsePrimary() throws(CompileError) -> Node {
        let line = token.line
        switch token.kind {
        case .identifier(let name):
            try advance()
            switch name {
            case "nil": return LiteralNode(.nilObject, line: line)
            case "true": return LiteralNode(.trueObject, line: line)
            case "false": return LiteralNode(.falseObject, line: line)
            default: return VariableNode(name, line: line)
            }
        case .leftParen:
            try advance()
            try enter()
            defer { depth -= 1 }
            let e = try parseExpression()
            try expect(.rightParen, ")")
            return e
        case .leftBracket:
            return try parseBlock()
        case .leftBrace:
            try advance()
            try enter()
            defer { depth -= 1 }
            var elements: [Node] = []
            while token.kind != .rightBrace {
                if token.kind == .period { try advance(); continue }
                elements.append(try parseExpression())
                if token.kind == .period { try advance(); continue }
                guard token.kind == .rightBrace else { throw fail("expected . or } in a brace array") }
            }
            try advance()
            return ArrayNode(elements, line: line)
        default:
            guard let l = try parseLiteralToken(allowNegative: true) else { throw fail("expected an expression") }
            return LiteralNode(l, line: line)
        }
    }

    mutating func parseBlock() throws(CompileError) -> BlockNode {
        let line = token.line
        try advance()
        try enter()
        defer { depth -= 1 }
        var args: [(String, Int)] = []
        while token.kind == .colon {
            try advance()
            guard case .identifier(let n) = token.kind else { throw fail("expected a block argument name") }
            args.append((n, token.line))
            try advance()
        }
        if !args.isEmpty {
            if case .binary("||") = token.kind {
                // `[:x || t | ...]`: the argument bar and the temporaries' bar
                token = Token(kind: .bar, line: token.line, start: token.start + 1, end: token.end)
            } else if token.kind == .bar {
                try advance()
            } else if token.kind != .rightBracket {
                throw fail("expected | after the block arguments")
            }
        }
        let temps = try parseTemporaries()
        let statements = try parseStatements(inBlock: true)
        try expect(.rightBracket, "]")
        return BlockNode(arguments: args, temporaries: temps, statements: statements, line: line)
    }

    /// A literal token: numbers (a `-` immediately before one negates it),
    /// strings, characters, symbols, `#(...)` and `#[...]`. nil if the token
    /// starts none.
    mutating func parseLiteralToken(allowNegative: Bool) throws(CompileError) -> Literal? {
        switch token.kind {
        case .binary("-") where allowNegative:
            // `-` directly followed by a number
            let p = scanner.pos
            guard p < scanner.bytes.count, scanner.bytes[p] >= 48, scanner.bytes[p] <= 57, token.end == p else { return nil }
            try advance()
            switch token.kind {
            case .integer(_, let mag):
                try advance()
                return integerLiteral(negative: true, mag)
            case .float(let d):
                try advance()
                return .float((-d).bitPattern)
            default:
                throw fail("expected a number after -")
            }
        case .integer(let neg, let mag):
            try advance()
            return integerLiteral(negative: neg, mag)
        case .float(let d):
            try advance()
            return .float(d.bitPattern)
        case .string(let b):
            try advance()
            return .string(b)
        case .character(let c):
            try advance()
            return .character(c)
        case .symbol(let s):
            try advance()
            return .symbol(s)
        case .literalArrayStart:
            try advance()
            return try parseLiteralArrayBody()
        case .byteArrayStart:
            try advance()
            return try parseByteArrayBody()
        default:
            return nil
        }
    }

    /// Inside `#( ... )`: literals, bare identifiers and keywords as Symbols
    /// (nil, true and false as themselves), `( ... )` and `[ ... ]` nested.
    mutating func parseLiteralArrayBody() throws(CompileError) -> Literal {
        try enter()
        defer { depth -= 1 }
        var out: [Literal] = []
        while true {
            switch token.kind {
            case .rightParen:
                try advance()
                return .array(out)
            case .end:
                throw fail("unterminated literal array")
            case .leftParen, .literalArrayStart:
                try advance()
                out.append(try parseLiteralArrayBody())
            case .leftBracket, .byteArrayStart:
                try advance()
                out.append(try parseByteArrayBody())
            case .identifier(let n):
                try advance()
                switch n {
                case "nil": out.append(.nilObject)
                case "true": out.append(.trueObject)
                case "false": out.append(.falseObject)
                default:
                    // `#(foo:bar:)` scans as keywords; an identifier is a Symbol
                    out.append(.symbol(n))
                }
            case .keyword(let k):
                var s = k
                var lastEnd = token.end
                try advance()
                while case .keyword(let k2) = token.kind, token.start == lastEnd {
                    s += k2
                    lastEnd = token.end
                    try advance()
                }
                out.append(.symbol(s))
            case .binary(let b) where !(b == "-" && scanner.pos < scanner.bytes.count && token.end == scanner.pos
                                        && scanner.bytes[scanner.pos] >= 48 && scanner.bytes[scanner.pos] <= 57):
                try advance()
                out.append(.symbol(b))
            case .bar:
                try advance()
                out.append(.symbol("|"))
            default:
                guard let l = try parseLiteralToken(allowNegative: true) else { throw fail("unexpected token in a literal array") }
                out.append(l)
            }
        }
    }

    mutating func parseByteArrayBody() throws(CompileError) -> Literal {
        var out: [UInt8] = []
        while true {
            switch token.kind {
            case .rightBracket:
                try advance()
                return .byteArray(out)
            case .integer(false, let mag) where mag.count <= 1:
                out.append(mag.first ?? 0)
                try advance()
            default:
                throw fail("a byte array holds integers 0 to 255")
            }
        }
    }
}

/// A SmallInteger literal when it fits, else a LargeInteger.
func integerLiteral(negative: Bool, _ mag: [UInt8]) -> Literal {
    if mag.count <= 8 {
        var v: UInt64 = 0
        for (i, b) in mag.enumerated() { v |= UInt64(b) << (8 * UInt64(i)) }
        let limit: UInt64 = 1 << 62
        if !negative && v < limit { return .integer(Int64(v)) }
        if negative && v <= limit { return .integer(v == limit ? -Int64(limit) : -Int64(v)) }
    }
    if mag.isEmpty { return .integer(0) }
    return .largeInteger(negative: negative, magnitude: mag)
}

/// Parse a method's source (pattern, pragmas, temporaries, statements).
func parseMethod(_ source: [UInt8], file: String, line: Int = 1) throws(CompileError) -> MethodNode {
    var p = try Parser(source, file: file, line: line)
    return try p.parseMethod()
}
