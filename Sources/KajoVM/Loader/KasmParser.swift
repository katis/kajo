/// The kasm text format (experiments/vm-language-bench SPEC-SHARED.md
/// ".kasm text format", extended for bytecode set v1 in module 8):
///
///     ; comment to end of line
///     class <Name> <Superclass> <instSize> [<format>] [meta=<n>]
///         format: fixed | variable (default) | bytes | words16 | words32 |
///                 words64 | weak | ephemeron; meta: class-side instance
///                 variables
///     method <Class> [class] <selector> temps=<n> [prim=<k>] [unwind] [handler]
///       pragma <selector> <literal>...      (before the first instruction)
///       <label>:
///       <opname> [operands]
///     block <name> args=<n> copied=<n> temps=<n>
///       ... (a block method of the enclosing method, until the next
///       `block` or `end`; `push_closure <name> <copied>` creates it)
///     end
///
/// Literal tokens: integers (beyond the SmallInteger range a
/// LargePositiveInteger or LargeNegativeInteger), floats (`1.5`, `2e10`,
/// `-0.0`), characters (`$a`, `$U+1F600`), strings (`'it''s here'`, spaces
/// allowed), `#selector`, `@Class`, nil, true, false.
struct KasmFile {
    var classes: [KasmClass] = []
    var methods: [KasmMethod] = []
}

struct KasmClass {
    let name: String
    let superclass: String
    let instSize: Int
    let line: Int
    /// ADR 0009 section 6: `weak` (indexed slots weak) or `ephemeron` (slot
    /// 0 the key); neither is inherited.
    var weak = false
    var ephemeron = false
    var kind = ClassFormat.Kind.variable
    /// Class-side instance variables (after the class layout's slots).
    var metaSlots = 0

    var format: ClassFormat {
        ClassFormat(namedSlots: instSize, kind: kind, weak: weak, ephemeron: ephemeron)
    }
}

struct KasmPragma {
    let selector: String
    let arguments: [String]
    let line: Int
}

struct KasmBlock {
    let name: String
    let line: Int
    let args: Int
    let copied: Int
    let temps: Int
    var body: [KasmLine] = []
}

struct KasmMethod {
    let file: String
    let line: Int
    let className: String
    let selector: String
    let temps: Int
    /// 0: none.
    let primitive: Int
    /// `method Foo class bar`: a method of Foo's metaclass.
    var classSide = false
    var unwind = false
    var handler = false
    var pragmas: [KasmPragma] = []
    var body: [KasmLine] = []
    var blocks: [KasmBlock] = []
}

struct KasmLine {
    enum Content {
        case label(String)
        case instruction(String, [String])
    }

    let line: Int
    let content: Content
}

/// The tokens of one line: whitespace separates, `;` starts a comment, a
/// `'` starts a string token that runs to its closing quote (`''` inside is
/// a quote), and `$` takes the next scalar into its token whatever it is.
func kasmTokens(_ bytes: [UInt8], _ start: Int, _ end: Int) -> [String]? {
    var tokens: [String] = []
    var i = start
    func isSpace(_ b: UInt8) -> Bool { b == 32 || b == 9 || b == 13 }
    while i < end {
        let b = bytes[i]
        if b == 59 { break }  // ';'
        if isSpace(b) { i += 1; continue }
        var j = i
        while j < end && !isSpace(bytes[j]) && bytes[j] != 59 {
            if bytes[j] == 39 {  // a quote: to its close
                j += 1
                while true {
                    if j >= end { return nil }
                    if bytes[j] == 39 {
                        if j + 1 < end && bytes[j + 1] == 39 { j += 2; continue }
                        j += 1
                        break
                    }
                    j += 1
                }
                continue
            }
            if bytes[j] == 36 && j + 1 < end {  // '$': the next scalar belongs to the token
                j += 2
                while j < end && bytes[j] & 0xC0 == 0x80 { j += 1 }
                continue
            }
            j += 1
        }
        tokens.append(String(decoding: bytes[i..<j], as: UTF8.self))
        i = j
    }
    return tokens
}

func parseKasm(_ text: String, file: String, limits: LoaderLimits = LoaderLimits()) throws(LoadError) -> KasmFile {
    if text.utf8.count > limits.maxSourceBytes {
        throw LoadError(.inputTooLarge, "source larger than \(limits.maxSourceBytes) bytes", file: file)
    }
    var out = KasmFile()
    var current: KasmMethod?
    var lineNo = 0
    // Bytes, not Characters: grapheme breaking made a 20 000-line file take
    // seconds in debug builds.
    let bytes = Array(text.utf8)
    var start = 0
    while start <= bytes.count {
        var end = start
        while end < bytes.count && bytes[end] != 10 { end += 1 }
        defer { start = end + 1 }
        lineNo += 1
        func fail(_ kind: LoadError.Kind, _ msg: String) -> LoadError {
            LoadError(kind, msg, file: file, line: lineNo)
        }
        guard let tokens = kasmTokens(bytes, start, end) else { throw fail(.syntax, "unterminated string") }
        guard let head = tokens.first else { continue }
        if current != nil {
            func append(_ l: KasmLine) {
                if current!.blocks.isEmpty { current!.body.append(l) } else { current!.blocks[current!.blocks.count - 1].body.append(l) }
            }
            if head == "end" {
                if tokens.count != 1 { throw fail(.syntax, "'end' takes nothing") }
                out.methods.append(current!)
                current = nil
            } else if head == "class" || head == "method" {
                throw fail(.syntax, "'\(head)' inside a method (missing 'end')")
            } else if head == "block" {
                guard tokens.count == 5, isIdentifier(tokens[1]) else {
                    throw fail(.syntax, "expected: block <name> args=<n> copied=<n> temps=<n>")
                }
                func num(_ t: String, _ key: String) throws(LoadError) -> Int {
                    guard t.hasPrefix(key + "="), let n = Int(t.dropFirst(key.count + 1)), n >= 0, n <= limits.maxTemps else {
                        throw fail(.badOperand, "expected \(key)=<0...\(limits.maxTemps)>, got '\(t)'")
                    }
                    return n
                }
                let a = try num(tokens[2], "args"), c = try num(tokens[3], "copied"), t = try num(tokens[4], "temps")
                if a + c + t > limits.maxTemps { throw fail(.badOperand, "a block's arguments, copied values and temps exceed \(limits.maxTemps)") }
                if current!.blocks.contains(where: { $0.name == tokens[1] }) { throw fail(.duplicateLabel, "block '\(tokens[1])' defined twice") }
                current!.blocks.append(KasmBlock(name: tokens[1], line: lineNo, args: a, copied: c, temps: t))
            } else if head == "pragma" {
                guard tokens.count >= 2, isSelector(tokens[1]) else { throw fail(.syntax, "expected: pragma <selector> <literal>...") }
                guard current!.body.isEmpty && current!.blocks.isEmpty else {
                    throw fail(.syntax, "a pragma comes before the method's first instruction")
                }
                current!.pragmas.append(KasmPragma(selector: tokens[1], arguments: Array(tokens.dropFirst(2)), line: lineNo))
            } else if tokens.count == 1, head.hasSuffix(":"), head.count > 1 {
                let name = String(head.dropLast())
                if !isIdentifier(name) { throw fail(.syntax, "bad label '\(name)'") }
                append(KasmLine(line: lineNo, content: .label(name)))
            } else {
                append(KasmLine(line: lineNo, content: .instruction(head, Array(tokens.dropFirst()))))
            }
            continue
        }
        switch head {
        case "class":
            if tokens.count < 4 || tokens.count > 6 {
                throw fail(.syntax, "expected: class <Name> <Superclass> <instSize> [format] [meta=<n>]")
            }
            if !isIdentifier(tokens[1]) || !isIdentifier(tokens[2]) { throw fail(.syntax, "bad class name") }
            guard let n = Int(tokens[3]), n >= 0, n <= Header.maxSlots else {
                throw fail(.badOperand, "instSize must be 0...\(Header.maxSlots)")
            }
            var c = KasmClass(name: tokens[1], superclass: tokens[2], instSize: n, line: lineNo)
            var sawFormat = false, sawMeta = false
            for t in tokens.dropFirst(4) {
                if t.hasPrefix("meta="), !sawMeta {
                    guard let k = Int(t.dropFirst(5)), k >= 0, k + ClassLayout.size <= Header.maxSlots else {
                        throw fail(.badOperand, "meta must be 0...\(Header.maxSlots - ClassLayout.size)")
                    }
                    c.metaSlots = k
                    sawMeta = true
                    continue
                }
                guard !sawFormat else { throw fail(.syntax, "unexpected '\(t)'") }
                sawFormat = true
                switch t {
                case "weak": c.weak = true
                case "ephemeron":
                    guard n >= 1 else { throw fail(.badOperand, "an ephemeron class has a key: instSize at least 1") }
                    c.ephemeron = true
                    c.kind = .fixed
                case "fixed": c.kind = .fixed
                case "variable": c.kind = .variable
                case "bytes", "words16", "words32", "words64":
                    guard n == 0 else { throw fail(.badOperand, "a \(t) class has no named slots") }
                    c.kind = t == "bytes" ? .bytes : t == "words16" ? .words16 : t == "words32" ? .words32 : .words64
                default:
                    throw fail(.syntax, "expected a format (fixed, variable, bytes, words16, words32, words64, weak, ephemeron), got '\(t)'")
                }
            }
            out.classes.append(c)
        case "method":
            var t = Array(tokens.dropFirst())
            var classSide = false
            // `method Foo class bar ...` is Foo's metaclass; `method Foo
            // class temps=0` is the selector #class.
            if t.count >= 3 && t[1] == "class" && !t[2].contains("=") {
                classSide = true
                t.remove(at: 1)
            }
            if t.count < 3 { throw fail(.syntax, "expected: method <Class> [class] <selector> temps=<n> [prim=<k>] [unwind] [handler]") }
            if !isIdentifier(t[0]) { throw fail(.syntax, "bad class name") }
            if !isSelector(t[1]) { throw fail(.syntax, "bad selector '\(t[1])'") }
            var temps: Int?
            var prim = 0
            var unwind = false, handler = false
            for opt in t[2...] {
                if opt.hasPrefix("temps="), temps == nil {
                    guard let n = Int(opt.dropFirst(6)), n >= 0, n + arity(of: t[1]) <= limits.maxTemps else {
                        throw fail(.badOperand, "temps must leave arguments plus temps at most \(limits.maxTemps)")
                    }
                    temps = n
                } else if opt.hasPrefix("prim="), prim == 0 {
                    guard let k = Int(opt.dropFirst(5)), k >= 1, k < primitiveTableSize else {
                        throw fail(.badOperand, "prim must be 1...\(primitiveTableSize - 1)")
                    }
                    prim = k
                } else if opt == "unwind" && !unwind {
                    unwind = true
                } else if opt == "handler" && !handler {
                    handler = true
                } else {
                    throw fail(.syntax, "unexpected '\(opt)'")
                }
            }
            guard let temps else { throw fail(.syntax, "temps=<n> missing") }
            var m = KasmMethod(file: file, line: lineNo, className: t[0], selector: t[1], temps: temps, primitive: prim)
            m.classSide = classSide
            m.unwind = unwind
            m.handler = handler
            current = m
        default:
            throw fail(.syntax, "expected 'class' or 'method', got '\(head)'")
        }
    }
    if let m = current { throw LoadError(.syntax, "method \(m.className)>>\(m.selector) has no 'end'", file: file, line: m.line) }
    return out
}

package func isIdentifier(_ s: String) -> Bool {
    guard let f = s.unicodeScalars.first, f.properties.isAlphabetic || f == "_" else { return false }
    return s.unicodeScalars.allSatisfy { $0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "_" }
}

private let binaryCharacters = Set("+-*/\\<>=~&|@%,?!".unicodeScalars)

package func isSelector(_ s: String) -> Bool {
    guard let f = s.unicodeScalars.first else { return false }
    if binaryCharacters.contains(f) { return s.unicodeScalars.allSatisfy { binaryCharacters.contains($0) } }
    if !s.contains(":") { return isIdentifier(s) }
    guard s.hasSuffix(":") else { return false }
    return s.dropLast().split(separator: ":", omittingEmptySubsequences: false).allSatisfy { isIdentifier(String($0)) }
}
