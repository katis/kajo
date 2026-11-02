/// The kasm text format (experiments/vm-language-bench SPEC-SHARED.md
/// ".kasm text format"):
///
///     ; comment to end of line
///     class <Name> <Superclass> <instSize>
///     method <Class> <selector> temps=<n> [prim=<k>]
///       <label>:
///       <opname> [operands]
///     end
struct KasmFile {
    var classes: [KasmClass] = []
    var methods: [KasmMethod] = []
}

struct KasmClass {
    let name: String
    let superclass: String
    let instSize: Int
    let line: Int
}

struct KasmMethod {
    let file: String
    let line: Int
    let className: String
    let selector: String
    let temps: Int
    /// 0: none.
    let primitive: Int
    var body: [KasmLine] = []
}

struct KasmLine {
    enum Content {
        case label(String)
        case instruction(String, [String])
    }

    let line: Int
    let content: Content
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
        var tokens: [String] = []
        var i = start
        while i < end && bytes[i] != 59 { // ';'
            let b = bytes[i]
            if b == 32 || b == 9 || b == 13 { i += 1; continue }
            var j = i
            while j < end && bytes[j] != 32 && bytes[j] != 9 && bytes[j] != 13 && bytes[j] != 59 { j += 1 }
            tokens.append(String(decoding: bytes[i..<j], as: UTF8.self))
            i = j
        }
        guard let head = tokens.first else { continue }
        func fail(_ kind: LoadError.Kind, _ msg: String) -> LoadError {
            LoadError(kind, msg, file: file, line: lineNo)
        }
        if current != nil {
            if head == "end" {
                if tokens.count != 1 { throw fail(.syntax, "'end' takes nothing") }
                out.methods.append(current!)
                current = nil
            } else if head == "class" || head == "method" {
                throw fail(.syntax, "'\(head)' inside a method (missing 'end')")
            } else if tokens.count == 1, head.hasSuffix(":"), head.count > 1 {
                let name = String(head.dropLast())
                if !isIdentifier(name) { throw fail(.syntax, "bad label '\(name)'") }
                current!.body.append(KasmLine(line: lineNo, content: .label(name)))
            } else {
                current!.body.append(KasmLine(line: lineNo, content: .instruction(head, Array(tokens.dropFirst()))))
            }
            continue
        }
        switch head {
        case "class":
            if tokens.count != 4 { throw fail(.syntax, "expected: class <Name> <Superclass> <instSize>") }
            if !isIdentifier(tokens[1]) || !isIdentifier(tokens[2]) { throw fail(.syntax, "bad class name") }
            guard let n = Int(tokens[3]), n >= 0, n <= Header.maxSlots else {
                throw fail(.badOperand, "instSize must be 0...\(Header.maxSlots)")
            }
            out.classes.append(KasmClass(name: tokens[1], superclass: tokens[2], instSize: n, line: lineNo))
        case "method":
            if tokens.count < 4 || tokens.count > 5 { throw fail(.syntax, "expected: method <Class> <selector> temps=<n> [prim=<k>]") }
            if !isIdentifier(tokens[1]) { throw fail(.syntax, "bad class name") }
            if !isSelector(tokens[2]) { throw fail(.syntax, "bad selector '\(tokens[2])'") }
            var temps: Int?
            var prim = 0
            for opt in tokens[3...] {
                if opt.hasPrefix("temps="), temps == nil {
                    guard let n = Int(opt.dropFirst(6)), n >= 0, n + arity(of: tokens[2]) <= limits.maxTemps else {
                        throw fail(.badOperand, "temps must leave arguments plus temps at most \(limits.maxTemps)")
                    }
                    temps = n
                } else if opt.hasPrefix("prim="), prim == 0 {
                    guard let k = Int(opt.dropFirst(5)), k >= 1, k < primitiveTableSize else {
                        throw fail(.badOperand, "prim must be 1...\(primitiveTableSize - 1)")
                    }
                    prim = k
                } else {
                    throw fail(.syntax, "unexpected '\(opt)'")
                }
            }
            guard let t = temps else { throw fail(.syntax, "temps=<n> missing") }
            current = KasmMethod(file: file, line: lineNo, className: tokens[1], selector: tokens[2], temps: t, primitive: prim)
        default:
            throw fail(.syntax, "expected 'class' or 'method', got '\(head)'")
        }
    }
    if let m = current { throw LoadError(.syntax, "method \(m.className)>>\(m.selector) has no 'end'", file: file, line: m.line) }
    return out
}

func isIdentifier(_ s: String) -> Bool {
    guard let f = s.unicodeScalars.first, f.properties.isAlphabetic || f == "_" else { return false }
    return s.unicodeScalars.allSatisfy { $0.properties.isAlphabetic || $0.properties.numericType != nil || $0 == "_" }
}

private let binaryCharacters = Set("+-*/\\<>=~&|@%,?!".unicodeScalars)

func isSelector(_ s: String) -> Bool {
    guard let f = s.unicodeScalars.first else { return false }
    if binaryCharacters.contains(f) { return s.unicodeScalars.allSatisfy { binaryCharacters.contains($0) } }
    if !s.contains(":") { return isIdentifier(s) }
    guard s.hasSuffix(":") else { return false }
    return s.dropLast().split(separator: ":", omittingEmptySubsequences: false).allSatisfy { isIdentifier(String($0)) }
}
