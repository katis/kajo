import KajoVM

// Tonel, one file per class (kernel.md question 1): a class definition in
// STON, then the methods, each with its protocol in a STON map:
//
//     "the class comment"
//     Class {
//         #name : #Point,
//         #superclass : #Object,
//         #instVars : [ 'x', 'y' ],
//         #classInstVars : [ 'origin' ],
//         #classVars : [ 'Default' ],
//         #type : #variable
//     }
//
//     { #category : #accessing }
//     Point >> x [
//         ^ x
//     ]
//
//     { #category : #'instance creation' }
//     Point class >> x: ax y: ay [
//         ^ self basicNew setX: ax y: ay
//     ]
//
// `Extension { #name : #UndefinedObject }` adds methods to a class defined
// elsewhere. `#type` is `#normal` (fixed, the default unless the
// superclass is variable or bytes), `#variable`, `#bytes`, `#words`
// (32-bit), `#words16`, `#words64`, `#weak` or `#ephemeron`. Class
// variables (`#classVars`, module 8d) are capitalized names the class, its
// metaclass and every subclass share; the image build checks them
// (`Plan`).
//
// Tags as subdirectories (docs/modules/tags-as-subdirectories.md): nothing
// about a class's placement lives in its file. Its package is the
// directory it is read from and its tag, when it has one, the
// subdirectory of that directory its file is in (`tonelTag(ofPath:)`,
// one level only). A definition's `#category` (a Kajo file written before
// the change) and Pharo's `#package` and `#tag` are read and ignored, as
// every key the reader does not know, so such a file loads and the next
// write leaves them out.

public struct TonelMethod: Sendable {
    public let className: String
    public let classSide: Bool
    public let category: String
    /// The method's source: the message pattern, then the body.
    public let source: [UInt8]
    public let line: Int
}

public struct TonelClass: Sendable {
    public let file: String
    public let line: Int
    public let isExtension: Bool
    public let name: String
    public let superclass: String?
    public let instanceVariables: [String]
    public let classInstanceVariables: [String]
    /// Module 8d: the class variables it declares.
    public let classVariables: [String]
    /// nil: inherited (`fixed` under Object).
    public let type: String?
    public let comment: String
    public var methods: [TonelMethod]
}

/// A STON value of the subset Tonel uses.
indirect enum Ston: Equatable {
    case symbol(String)
    case string(String)
    case number(Int)
    case array([Ston])
    case map([(String, Ston)])
    case identifier(String)

    static func == (a: Ston, b: Ston) -> Bool {
        switch (a, b) {
        case (.symbol(let x), .symbol(let y)), (.string(let x), .string(let y)), (.identifier(let x), .identifier(let y)): x == y
        case (.number(let x), .number(let y)): x == y
        case (.array(let x), .array(let y)): x == y
        case (.map(let x), .map(let y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    var text: String? {
        switch self {
        case .symbol(let s), .string(let s), .identifier(let s): s
        default: nil
        }
    }
}

struct TonelReader {
    let b: [UInt8]
    let file: String
    var i = 0
    var line = 1

    init(_ text: [UInt8], file: String) {
        b = text
        self.file = file
    }

    func fail(_ m: String) -> CompileError { CompileError(m, file: file, line: line) }

    /// Whitespace; a comment's text is kept (the class comment).
    mutating func space() throws(CompileError) -> String {
        var comment = ""
        while i < b.count {
            if b[i] == 10 { line += 1; i += 1 }
            else if b[i] == 32 || b[i] == 9 || b[i] == 13 { i += 1 }
            else if b[i] == 34 {
                // A doubled quote inside is one quote (module 8e: the
                // writer doubles them, as Pharo's Tonel does).
                var text: [UInt8] = []
                i += 1
                while true {
                    guard i < b.count else { throw fail("unterminated comment") }
                    if b[i] == 34 {
                        if i + 1 < b.count && b[i + 1] == 34 { text.append(34); i += 2; continue }
                        break
                    }
                    if b[i] == 10 { line += 1 }
                    text.append(b[i])
                    i += 1
                }
                comment = String(decoding: text, as: UTF8.self)
                i += 1
            } else { break }
        }
        return comment
    }

    mutating func identifier() -> String {
        let s = i
        while i < b.count, b[i] >= 0x80 || (b[i] >= 48 && b[i] <= 57) || (b[i] >= 65 && b[i] <= 90) || (b[i] >= 97 && b[i] <= 122)
                || b[i] == 95 { i += 1 }
        return String(decoding: b[s..<i], as: UTF8.self)
    }

    mutating func quoted() throws(CompileError) -> String {
        i += 1
        var out: [UInt8] = []
        while true {
            guard i < b.count else { throw fail("unterminated string") }
            if b[i] == 39 {
                if i + 1 < b.count && b[i + 1] == 39 { out.append(39); i += 2; continue }
                i += 1
                break
            }
            if b[i] == 10 { line += 1 }
            out.append(b[i])
            i += 1
        }
        guard let s = String(validating: out, as: UTF8.self) else { throw fail("invalid UTF-8") }
        return s
    }

    mutating func value(depth: Int = 0) throws(CompileError) -> Ston {
        if depth > 16 { throw fail("STON nested too deep") }
        _ = try space()
        guard i < b.count else { throw fail("expected a value") }
        switch b[i] {
        case 35:  // #
            i += 1
            if i < b.count && b[i] == 39 { return .symbol(try quoted()) }
            let s = i
            while i < b.count, b[i] > 32, b[i] != 44, b[i] != 125, b[i] != 93 { i += 1 }
            return .symbol(String(decoding: b[s..<i], as: UTF8.self))
        case 39: return .string(try quoted())
        case 91:  // [
            i += 1
            var out: [Ston] = []
            while true {
                _ = try space()
                guard i < b.count else { throw fail("unterminated array") }
                if b[i] == 93 { i += 1; return .array(out) }
                out.append(try value(depth: depth + 1))
                _ = try space()
                if i < b.count && b[i] == 44 { i += 1 }
            }
        case 123: return .map(try map(depth: depth + 1))
        case 48...57, 45:
            let s = i
            i += 1
            while i < b.count && b[i] >= 48 && b[i] <= 57 { i += 1 }
            guard let n = Int(String(decoding: b[s..<i], as: UTF8.self)) else { throw fail("bad number") }
            return .number(n)
        default:
            let id = identifier()
            if id.isEmpty { throw fail("unexpected character in STON") }
            return .identifier(id)
        }
    }

    /// `{ #key : value, ... }`
    mutating func map(depth: Int = 0) throws(CompileError) -> [(String, Ston)] {
        guard i < b.count, b[i] == 123 else { throw fail("expected {") }
        i += 1
        var out: [(String, Ston)] = []
        while true {
            _ = try space()
            guard i < b.count else { throw fail("unterminated map") }
            if b[i] == 125 { i += 1; return out }
            guard case .symbol(let key) = try value(depth: depth) else { throw fail("a map key is a symbol") }
            _ = try space()
            guard i < b.count, b[i] == 58 else { throw fail("expected : after #\(key)") }
            i += 1
            out.append((key, try value(depth: depth)))
            _ = try space()
            if i < b.count && b[i] == 44 { i += 1 }
        }
    }

    /// The offset of the `]` closing the `[` at `open`, skipping strings,
    /// comments and character literals.
    mutating func matchingBracket(_ open: Int) throws(CompileError) -> Int {
        var depth = 0
        var k = open
        let startLine = line
        while k < b.count {
            switch b[k] {
            case 10: line += 1
            case 39, 34:
                let q = b[k]
                k += 1
                while k < b.count && b[k] != q { if b[k] == 10 { line += 1 }; k += 1 }
            case 36:  // $x: skip the scalar
                k += 1
                if k < b.count && b[k] == 10 { line += 1 }
                if k < b.count && b[k] >= 0x80 { while k + 1 < b.count && b[k + 1] & 0xC0 == 0x80 { k += 1 } }
            case 91: depth += 1
            case 93:
                depth -= 1
                if depth == 0 { return k }
            default: break
            }
            k += 1
        }
        throw CompileError("a method body without its closing ]", file: file, line: startLine)
    }

    mutating func read() throws(CompileError) -> TonelClass {
        let comment = try space()
        let headLine = line
        let kind = identifier()
        guard kind == "Class" || kind == "Extension" else { throw fail("expected Class { ... } or Extension { ... }") }
        _ = try space()
        let def = try map()
        func entry(_ k: String) -> Ston? { def.first { $0.0 == k }?.1 }
        guard let name = entry("name")?.text, isIdentifier(name) else { throw fail("the class needs a #name") }
        func names(_ k: String) throws(CompileError) -> [String] {
            guard let v = entry(k) else { return [] }
            guard case .array(let xs) = v else { throw fail("#\(k) is an array of names") }
            var out: [String] = []
            for x in xs {
                guard let t = x.text else { throw fail("#\(k) is an array of names") }
                for part in t.split(separator: " ") {
                    guard isIdentifier(String(part)) else { throw fail("bad name '\(part)' in #\(k)") }
                    out.append(String(part))
                }
            }
            return out
        }
        let isExtension = kind == "Extension"
        var superclass: String? = nil
        if !isExtension {
            switch entry("superclass") {
            case .some(.identifier("nil")), .none: superclass = nil
            case .some(let s):
                guard let t = s.text, isIdentifier(t) else { throw fail("bad #superclass") }
                superclass = t
            }
        }
        var cls = TonelClass(file: file, line: headLine, isExtension: isExtension, name: name, superclass: superclass,
                             instanceVariables: try names("instVars"), classInstanceVariables: try names("classInstVars"),
                             classVariables: isExtension ? [] : try names("classVars"),
                             type: entry("type")?.text, comment: comment, methods: [])
        while true {
            _ = try space()
            if i >= b.count { break }
            var category = ""
            if b[i] == 123 {
                // A method's metadata is read for its category; any other
                // key (an `#author` of a file written before the
                // development answers among them: the mark is a pragma in
                // the source now) is read and ignored, as Pharo's Tonel
                // ignores keys it does not know.
                let meta = try map()
                category = meta.first { $0.0 == "category" }?.1.text ?? ""
                _ = try space()
            }
            let methodLine = line
            let owner = identifier()
            guard !owner.isEmpty else { throw fail("expected a method: Class >> selector [ ... ]") }
            _ = try space()
            var classSide = false
            if b.count - i >= 5 && String(decoding: b[i..<(i + 5)], as: UTF8.self) == "class" {
                i += 5
                classSide = true
                _ = try space()
            }
            guard i + 1 < b.count, b[i] == 62, b[i + 1] == 62 else { throw fail("expected >> after \(owner)") }
            i += 2
            _ = try space()
            let patternStart = i
            let patternLine = line
            // the pattern runs to the first [ outside a comment (the review
            // fixes, part 2, item 3: a comment in a pattern, `at: i "in
            // [1, size]" put: v`, keeps its brackets; a pattern holds no
            // string)
            while i < b.count && b[i] != 91 {
                if b[i] == 34 {
                    i += 1
                    while i < b.count && b[i] != 34 {
                        if b[i] == 10 { line += 1 }
                        i += 1
                    }
                    if i < b.count { i += 1 }
                    continue
                }
                if b[i] == 10 { line += 1 }
                i += 1
            }
            guard i < b.count else { throw fail("a method without a body") }
            let open = i
            let close = try matchingBracket(open)
            // Module 8e: the recorded source is the pattern without the
            // blanks before `[`, then the body as it stands between the
            // brackets (a blank between them when the body starts with
            // neither a blank nor a line break), so the Tonel writer in
            // Smalltalk puts `[` and `]` back where they were.
            var end = open
            while end > patternStart, [9, 10, 13, 32].contains(b[end - 1]) { end -= 1 }
            var src = Array(b[patternStart..<end])
            let body = b[(open + 1)..<close]
            if let first = body.first, ![9, 10, 13, 32].contains(first) { src.append(32) }
            src += body
            i = close + 1
            guard owner == name else {
                throw CompileError("a method of \(owner) in \(name)'s file", file: file, line: methodLine)
            }
            cls.methods.append(TonelMethod(className: name, classSide: classSide, category: category, source: src, line: patternLine))
        }
        return cls
    }
}

/// The tag a class file's path gives (tags as subdirectories): `path` is
/// relative to the package's directory; a file at its root has none, a
/// file one directory down has that directory's name as its tag, and a
/// file further down is refused naming the path. `TonelReader
/// class>>tagOfPath:` is the same rule in the image; a test compares them.
public func tonelTag(ofPath path: String) throws(CompileError) -> String? {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    switch parts.count {
    case 1: return nil
    case 2:
        guard isTonelTag(parts[0]) else { throw CompileError("\(path): '\(parts[0])' is not a tag's directory") }
        return parts[0]
    default: throw CompileError("\(path): a class file two directories below its package (a tag is one directory)")
    }
}

/// Whether `name` can be a tag: one path component, not empty, not `.` or
/// `..`, no `/` or NUL, not hidden (a leading `.`).
public func isTonelTag(_ name: String) -> Bool {
    !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\0")
}

/// Read one Tonel file.
public func readTonel(_ text: [UInt8], file: String) throws(CompileError) -> TonelClass {
    var r = TonelReader(text, file: file)
    return try r.read()
}
