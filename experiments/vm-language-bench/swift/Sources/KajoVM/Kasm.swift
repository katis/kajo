// .kasm parser and assembler (SPEC-SHARED.md ".kasm text format", "Bytecodes").
// Produces heap-independent bytecode + literal lists; Image.swift installs them.

public enum Op {
    public static let pushTemp: UInt8 = 0x00
    public static let pushLit: UInt8 = 0x01
    public static let pushSelf: UInt8 = 0x02
    public static let pushIvar: UInt8 = 0x03
    public static let storeTemp: UInt8 = 0x04
    public static let storeIvar: UInt8 = 0x05
    public static let pop: UInt8 = 0x06
    public static let dup: UInt8 = 0x07
    public static let pushNil: UInt8 = 0x08
    public static let pushTrue: UInt8 = 0x09
    public static let pushFalse: UInt8 = 0x0A
    public static let pushInt: UInt8 = 0x0B
    public static let send: UInt8 = 0x0C
    public static let returnTop: UInt8 = 0x0D
    public static let returnSelf: UInt8 = 0x0E
    public static let jump: UInt8 = 0x0F
    public static let jumpIfTrue: UInt8 = 0x10
    public static let jumpIfFalse: UInt8 = 0x11
    public static let add: UInt8 = 0x12
    public static let sub: UInt8 = 0x13
    public static let mul: UInt8 = 0x14
    public static let lt: UInt8 = 0x15
    public static let gt: UInt8 = 0x16
    public static let le: UInt8 = 0x17
    public static let ge: UInt8 = 0x18
    public static let eq: UInt8 = 0x19
    public static let identical: UInt8 = 0x1A
}

/// Special selectors, in opcode order add..identical.
public let specialSelectors = ["+", "-", "*", "<", ">", "<=", ">=", "=", "=="]

public enum Lit: Hashable, Sendable {
    case int(Int64), sym(String), cls(String), nilLit, trueLit, falseLit
}

public enum Ins: Equatable, Sendable {
    case simple(UInt8)
    case withByte(UInt8, UInt8)
    case pushInt(Int8)
    case pushLit(Lit)
    case send(String, UInt8)
    case jump(UInt8, String)
    case label(String)
}

public struct ClassDef: Equatable, Sendable {
    public var name: String
    public var superclass: String
    public var instSize: Int
}

public struct MethodDef: Equatable, Sendable {
    public var cls: String
    public var selector: String
    public var temps: Int
    public var prim: Int
    public var code: [Ins]
}

public struct Program: Equatable, Sendable {
    public var classes: [ClassDef] = []
    public var methods: [MethodDef] = []
}

public struct Assembled: Equatable {
    public var bytecodes: [UInt8]
    public var literals: [Lit]
    public var argc: Int
    public var maxStack: Int
}

public struct KasmError: Error, CustomStringConvertible {
    public var description: String
    init(_ d: String) { description = d }
}

public func selectorArgc(_ sel: String) -> Int {
    guard let first = sel.first else { return 0 }
    if !(first.isASCII && (first.isLetter || first == "_")) { return 1 }
    return sel.filter { $0 == ":" }.count
}

private func parseKV(_ tok: Substring, _ key: String) -> Int? {
    guard tok.hasPrefix(key + "=") else { return nil }
    return Int(tok.dropFirst(key.count + 1))
}

private func parseLit(_ tok: Substring) throws -> Lit {
    switch tok {
    case "nil": return .nilLit
    case "true": return .trueLit
    case "false": return .falseLit
    default:
        if tok.hasPrefix("#") { return .sym(String(tok.dropFirst())) }
        if tok.hasPrefix("@") { return .cls(String(tok.dropFirst())) }
        guard let i = Int64(tok) else { throw KasmError("bad literal '\(tok)'") }
        return .int(i)
    }
}

public func parseKasm(_ src: String) throws -> Program {
    var prog = Program()
    var cur: MethodDef? = nil
    for (lineno, raw) in src.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
        if toks.isEmpty { continue }
        func err(_ m: String) -> KasmError { KasmError("line \(lineno + 1): \(m)") }
        if var m = cur {
            if toks[0] == "end" {
                prog.methods.append(m)
                cur = nil
                continue
            }
            if toks.count == 1 && toks[0].hasSuffix(":") && toks[0].count > 1 {
                m.code.append(.label(String(toks[0].dropLast())))
                cur = m
                continue
            }
            func operand(_ i: Int) throws -> Substring {
                guard i < toks.count else { throw err("missing operand for \(toks[0])") }
                return toks[i]
            }
            func byte(_ i: Int) throws -> UInt8 {
                guard let b = UInt8(try operand(i)) else { throw err("bad u8 operand") }
                return b
            }
            let ins: Ins
            switch toks[0] {
            case "push_temp": ins = .withByte(Op.pushTemp, try byte(1))
            case "push_ivar": ins = .withByte(Op.pushIvar, try byte(1))
            case "store_temp": ins = .withByte(Op.storeTemp, try byte(1))
            case "store_ivar": ins = .withByte(Op.storeIvar, try byte(1))
            case "push_lit": ins = .pushLit(try parseLit(try operand(1)))
            case "push_int":
                guard let i = Int8(try operand(1)) else { throw err("bad i8 operand") }
                ins = .pushInt(i)
            case "send":
                let sel = String(try operand(1))
                let argc = try byte(2)
                if selectorArgc(sel) != Int(argc) { throw err("argc mismatch for \(sel)") }
                ins = .send(sel, argc)
            case "jump": ins = .jump(Op.jump, String(try operand(1)))
            case "jump_if_true": ins = .jump(Op.jumpIfTrue, String(try operand(1)))
            case "jump_if_false": ins = .jump(Op.jumpIfFalse, String(try operand(1)))
            case "push_self": ins = .simple(Op.pushSelf)
            case "pop": ins = .simple(Op.pop)
            case "dup": ins = .simple(Op.dup)
            case "push_nil": ins = .simple(Op.pushNil)
            case "push_true": ins = .simple(Op.pushTrue)
            case "push_false": ins = .simple(Op.pushFalse)
            case "return_top": ins = .simple(Op.returnTop)
            case "return_self": ins = .simple(Op.returnSelf)
            case "add": ins = .simple(Op.add)
            case "sub": ins = .simple(Op.sub)
            case "mul": ins = .simple(Op.mul)
            case "lt": ins = .simple(Op.lt)
            case "gt": ins = .simple(Op.gt)
            case "le": ins = .simple(Op.le)
            case "ge": ins = .simple(Op.ge)
            case "eq": ins = .simple(Op.eq)
            case "identical": ins = .simple(Op.identical)
            default: throw err("unknown op '\(toks[0])'")
            }
            m.code.append(ins)
            cur = m
            continue
        }
        switch toks[0] {
        case "class":
            guard toks.count == 4, let n = Int(toks[3]) else { throw err("class <Name> <Super> <instSize>") }
            prog.classes.append(ClassDef(name: String(toks[1]), superclass: String(toks[2]), instSize: n))
        case "method":
            guard toks.count >= 3 else { throw err("method <Class> <selector> temps=n [prim=k]") }
            var temps = 0, prim = 0
            for t in toks.dropFirst(3) {
                if let v = parseKV(t, "temps") { temps = v }
                else if let v = parseKV(t, "prim") { prim = v }
                else { throw err("bad method attribute '\(t)'") }
            }
            cur = MethodDef(cls: String(toks[1]), selector: String(toks[2]), temps: temps, prim: prim, code: [])
        default:
            throw err("unexpected '\(toks[0])'")
        }
    }
    if cur != nil { throw KasmError("unterminated method") }
    return prog
}

private func insSize(_ ins: Ins) -> Int {
    switch ins {
    case .label: return 0
    case .simple: return 1
    case .withByte, .pushInt, .pushLit: return 2
    case .send, .jump: return 3
    }
}

private func stackEffect(_ ins: Ins) -> Int {
    switch ins {
    case .label: return 0
    case .withByte(let op, _): return (op == Op.pushTemp || op == Op.pushIvar) ? 1 : -1
    case .pushInt, .pushLit: return 1
    case .send(_, let argc): return -Int(argc)
    case .jump(let op, _): return op == Op.jump ? 0 : -1
    case .simple(let op):
        switch op {
        case Op.pushSelf, Op.dup, Op.pushNil, Op.pushTrue, Op.pushFalse: return 1
        case Op.pop: return -1
        case Op.returnTop, Op.returnSelf: return 0
        default: return -1 // binary specials
        }
    }
}

public func assemble(_ m: MethodDef) throws -> Assembled {
    var labels: [String: Int] = [:]
    var pos = 0
    for ins in m.code {
        if case .label(let l) = ins { labels[l] = pos }
        pos += insSize(ins)
    }
    var literals: [Lit] = []
    func litIndex(_ l: Lit) throws -> UInt8 {
        let i: Int
        if let j = literals.firstIndex(of: l) { i = j } else { literals.append(l); i = literals.count - 1 }
        guard let b = UInt8(exactly: i) else { throw KasmError("too many literals") }
        return b
    }
    var out: [UInt8] = []
    out.reserveCapacity(pos)
    var depth = 0, maxDepth = 0
    for ins in m.code {
        switch ins {
        case .label: break
        case .simple(let op): out.append(op)
        case .withByte(let op, let b): out += [op, b]
        case .pushInt(let i): out += [Op.pushInt, UInt8(bitPattern: i)]
        case .pushLit(let l): out += [Op.pushLit, try litIndex(l)]
        case .send(let sel, let argc): out += [Op.send, try litIndex(.sym(sel)), argc]
        case .jump(let op, let label):
            guard let target = labels[label] else { throw KasmError("\(m.selector): unknown label \(label)") }
            guard let off = Int16(exactly: target - (out.count + 3)) else { throw KasmError("jump too far") }
            let u = UInt16(bitPattern: off)
            out += [op, UInt8(u & 0xFF), UInt8(u >> 8)]
        }
        depth += stackEffect(ins)
        maxDepth = max(maxDepth, depth)
    }
    return Assembled(bytecodes: out, literals: literals, argc: selectorArgc(m.selector), maxStack: max(maxDepth, 1))
}
