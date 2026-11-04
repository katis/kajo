import KajoVM

// The bootstrap compiler's semantic analysis and code generation (module
// 8b). It emits the assembler's input (`AsmMethod`), which KajoVM encodes
// and runs through the one bytecode verifier; the kernel's
// BytecodeGenerator encodes the same instructions itself and must arrive
// at the same bytes (CompilerComparisonTests).
//
// The rules both compilers follow, exactly (a difference is a test
// failure):
//
// - Variables. A variable is *captured* when a real block (one not
//   inlined) other than the scope that declares it reads or writes it. A
//   captured variable that is ever assigned lives in its scope's temp
//   vector; every other captured variable is copied into the closure.
//   Arguments are never assigned, so never in a vector.
// - A variable's vector belongs to its *owner*: the nearest enclosing scope
//   that is real or the body of an inlined loop (module 8d, Pharo's rule).
//   An inlined loop body (the receiver and argument blocks of whileTrue:,
//   whileFalse:, whileTrue, whileFalse, repeat, the block of to:do:,
//   to:by:do: and timesRepeat:) that owns captured and assigned variables
//   makes a fresh vector at the start of every pass (`push_new_array`,
//   `store_temp`), so a closure made in one iteration keeps that
//   iteration's values. The vector's temp is a local of the enclosing real
//   scope; the loop scope takes a sequence number when it is entered, and
//   the temp takes that place among the locals. Inlined conditionals own
//   nothing: their variables belong to the nearest loop body or real scope.
// - Every declaration takes a sequence number in source order; a real
//   scope takes one when it is entered, before its arguments. A real
//   scope's frame: its arguments; for a block its copied values (outer
//   variables and outer temp vectors it or a block inside it uses, ordered
//   by sequence number, a vector by its scope's); then its temp vector, if
//   any; then its other locals (temporaries, those of the blocks inlined
//   into it, and the compiler's hidden loop temps) in sequence order. The
//   vector's slots are its variables in sequence order.
// - Inlined: ifTrue:, ifFalse:, ifTrue:ifFalse:, ifFalse:ifTrue:, and:,
//   or:, ifNil:, ifNotNil:, ifNil:ifNotNil:, ifNotNil:ifNil:, whileTrue:,
//   whileFalse:, whileTrue, whileFalse, repeat, to:do:, to:by:do: (an
//   integer step) and timesRepeat:, when the arguments (and the receiver
//   of the loops) are literal blocks of the right arity. Hidden temps: an
//   inlined to:do: keeps its limit in one unless the limit is an integer
//   literal; timesRepeat: keeps a counter, then a limit (the same rule).
// - Names (module 8d): temps and arguments, instance variables, class
//   variables (the class's own, then its superclasses'; the same on the
//   class side), then classes. A class variable is its Binding in the
//   literal frame: read `push_literal B; value` (the special send), write
//   `push_literal B; <value>; value:` (`Binding>>value:` answers its
//   argument), then `pop` for effect. No temp or argument may shadow one.
// - Literals: an integer in -128...127 is `push_int`, nil, true and false
//   their own opcodes, anything else a literal; the literal frame is in
//   first-use order with duplicates merged (the assembler), pragmas last.
// - The special selectors (`Opcode.specialSelector`) compile to their
//   opcodes, never under `super` or in a cascade's... no: in cascades too.
// - A pure expression for effect (a literal, a variable, a block) emits
//   nothing.
// - Blocks are numbered in the order their closures are generated
//   (pre-order).

/// What a name means in a method.
enum Binding {
    case unresolved
    case selfVariable
    case superVariable
    case thisContext
    case local(Variable)
    case instanceVariable(Int)
    /// Module 8d: a class variable (the class that declares it, its name).
    case classVariable(String, String)
    /// A class (its name).
    case global(String)
}

/// A temporary or argument, of a method, a real block or an inlined block.
final class Variable {
    // `scope` is unowned: a scope holds its variables (`declared`,
    // `locals`), and a strong reference back leaked every compilation (the
    // syntax fuzzer ran out of memory after 4.5 minutes). The method's tree
    // owns every scope for as long as its variables are used.
    /// `inlinedArgument`: an inlined block's argument, a local of the real
    /// scope that only the inlined code writes.
    enum Kind { case argument, temporary, hidden, inlinedArgument }
    let name: String
    let kind: Kind
    unowned let scope: Scope
    let seq: Int
    var captured = false
    var written = false
    /// Frame index (not in a vector), or the vector slot.
    var index = -1
    var vectorSlot = -1
    init(_ name: String, kind: Kind, scope: Scope, seq: Int) {
        self.name = name
        self.kind = kind
        self.scope = scope
        self.seq = seq
    }
    var real: Scope { scope.real }
    /// The scope whose temp vector holds the variable when `inVector`.
    var owner: Scope { scope.owner }
    var inVector: Bool { captured && written }
}

/// A method, a real block (a closure) or an inlined block.
final class Scope {
    let parent: Scope?
    let isReal: Bool
    /// An inlined loop body: it owns a temp vector of its own (module 8d).
    let isLoop: Bool
    let seq: Int
    var declared: [Variable] = []
    // Real scopes only:
    var locals: [Variable] = []
    var needed: [Variable] = []
    enum Copied: Equatable {
        case variable(Variable)
        case vector(Scope)
        static func == (a: Copied, b: Copied) -> Bool {
            switch (a, b) {
            case (.variable(let x), .variable(let y)): return x === y
            case (.vector(let x), .vector(let y)): return x === y
            default: return false
            }
        }
        var key: Int {
            switch self {
            case .variable(let v): return v.seq
            case .vector(let s): return s.seq
            }
        }
    }
    var copied: [Copied] = []
    /// Real scopes: the loop bodies inlined into this scope, which may own
    /// vectors whose temps are this scope's locals.
    var loops: [Scope] = []
    /// Real and loop scopes: the variables of the vector this scope owns,
    /// and the frame temp that holds it (in the real scope's frame).
    var vectorVariables: [Variable] = []
    var vectorTemp = -1
    var argumentCount = 0
    /// Temps after the arguments and copied values (the vector's temp and
    /// the other locals).
    var tempCount = 0

    init(parent: Scope?, isReal: Bool, isLoop: Bool = false, seq: Int) {
        self.parent = parent
        self.isReal = isReal
        self.isLoop = isLoop
        self.seq = seq
    }

    var real: Scope { isReal ? self : parent!.real }
    var owner: Scope { isReal || isLoop ? self : parent!.owner }

    func copiedIndex(_ c: Copied) -> Int {
        argumentCount + copied.firstIndex(of: c)!
    }
}

/// The class a method is compiled in.
public struct ClassContext: Sendable {
    public let className: String
    public let classSide: Bool
    /// Every instance variable name, inherited first (for a class-side
    /// method: the class-side instance variables after the class layout's
    /// slots, which have no names).
    public let instanceVariables: [String]
    /// The first slot the names above stand for (0, or the class layout's
    /// size on the class side).
    public let firstSlot: Int
    public let isClassName: @Sendable (String) -> Bool
    /// Module 8d: the class variables the class sees (its own and its
    /// superclasses'; the same on either side), each with the class that
    /// declares it.
    public let classVariables: [String: String]

    public init(className: String, classSide: Bool, instanceVariables: [String], firstSlot: Int = 0,
                isClassName: @escaping @Sendable (String) -> Bool, classVariables: [String: String] = [:]) {
        self.className = className
        self.classSide = classSide
        self.instanceVariables = instanceVariables
        self.firstSlot = firstSlot
        self.isClassName = isClassName
        self.classVariables = classVariables
    }
}

/// A compiled method before assembly, and what the builder needs from it.
struct CompiledSource {
    let method: AsmMethod
    let pragmas: [PragmaNode]
}

/// The selectors with a special-send opcode.
let specialOpcodes: [String: Opcode] = {
    var d: [String: Opcode] = [:]
    for op in Opcode.allCases { if let s = op.specialSelector { d[s] = op } }
    return d
}()

/// Pragmas the compiler itself consumes: they set the method's header and
/// are not Pragma literals.
let compilerPragmas: Set<String> = ["primitive:", "unwind", "handler"]

struct Compiler {
    let context: ClassContext
    let file: String
    var seq = 0
    var blockCounter = 0
    var labelCounter = 0
    var blocks: [AsmBlock] = []

    init(context: ClassContext, file: String) {
        self.context = context
        self.file = file
    }

    func fail(_ m: String, _ line: Int) -> CompileError { CompileError(m, file: file, line: line) }

    mutating func nextSeq() -> Int {
        seq += 1
        return seq
    }

    // MARK: analysis

    mutating func declare(_ name: String, _ kind: Variable.Kind, in scope: Scope, line: Int) throws(CompileError) -> Variable {
        if kind != .hidden {
            if ["self", "super", "thisContext", "nil", "true", "false"].contains(name) {
                throw fail("'\(name)' cannot be a variable name", line)
            }
            if scope.declared.contains(where: { $0.name == name }) { throw fail("'\(name)' declared twice", line) }
            if let owner = context.classVariables[name] { throw fail("'\(name)' shadows \(owner)'s class variable", line) }
        }
        let v = Variable(name, kind: kind, scope: scope, seq: nextSeq())
        scope.declared.append(v)
        scope.real.locals.append(v)
        return v
    }

    func lookup(_ name: String, _ scope: Scope) -> Variable? {
        var s: Scope? = scope
        while let c = s {
            if let v = c.declared.last(where: { $0.name == name && $0.kind != .hidden }) { return v }
            s = c.parent
        }
        return nil
    }

    mutating func resolve(_ node: VariableNode, _ scope: Scope) throws(CompileError) {
        switch node.name {
        case "self": node.binding = .selfVariable
        case "super": node.binding = .superVariable
        case "thisContext": node.binding = .thisContext
        default:
            if let v = lookup(node.name, scope) {
                node.binding = .local(v)
                reference(v, from: scope)
            } else if let i = context.instanceVariables.firstIndex(of: node.name) {
                node.binding = .instanceVariable(context.firstSlot + i)
            } else if let owner = context.classVariables[node.name] {
                node.binding = .classVariable(owner, node.name)
            } else if context.isClassName(node.name) {
                node.binding = .global(node.name)
            } else {
                throw fail("undeclared variable '\(node.name)'", node.line)
            }
        }
    }

    func reference(_ v: Variable, from scope: Scope) {
        var r = scope.real
        if r === v.real { return }
        v.captured = true
        while r !== v.real {
            if !r.needed.contains(where: { $0 === v }) { r.needed.append(v) }
            r = r.parent!.real
        }
    }

    static func isBlock(_ n: Node, args: Int) -> Bool { (n as? BlockNode)?.arguments.count == args }

    /// Whether a send compiles inline (the rules at the top of the file).
    static func inlinable(_ s: SendNode) -> Bool {
        if s.isSuper { return false }
        let a = s.arguments
        switch s.selector {
        case "ifTrue:", "ifFalse:", "and:", "or:", "ifNil:", "timesRepeat:":
            return isBlock(a[0], args: 0)
        case "ifTrue:ifFalse:", "ifFalse:ifTrue:":
            return isBlock(a[0], args: 0) && isBlock(a[1], args: 0)
        case "ifNotNil:":
            return isBlock(a[0], args: 0) || isBlock(a[0], args: 1)
        case "ifNil:ifNotNil:":
            return isBlock(a[0], args: 0) && (isBlock(a[1], args: 0) || isBlock(a[1], args: 1))
        case "ifNotNil:ifNil:":
            return (isBlock(a[0], args: 0) || isBlock(a[0], args: 1)) && isBlock(a[1], args: 0)
        case "whileTrue:", "whileFalse:":
            return isBlock(s.receiver, args: 0) && isBlock(a[0], args: 0)
        case "whileTrue", "whileFalse", "repeat":
            return isBlock(s.receiver, args: 0)
        case "to:do:":
            return isBlock(a[1], args: 1)
        case "to:by:do:":
            guard isBlock(a[2], args: 1), let l = a[1] as? LiteralNode, case .integer(let step) = l.value else { return false }
            return step != 0
        default:
            return false
        }
    }

    static func isIntegerLiteral(_ n: Node) -> Bool {
        if let l = n as? LiteralNode, case .integer = l.value { return true }
        return false
    }

    mutating func analyze(_ n: Node, _ scope: Scope) throws(CompileError) {
        switch n {
        case is LiteralNode:
            break
        case let v as VariableNode:
            try resolve(v, scope)
        case let a as AssignNode:
            try resolve(a.variable, scope)
            switch a.variable.binding {
            case .local(let v):
                if v.kind == .argument || v.kind == .inlinedArgument {
                    throw fail("cannot assign to the argument '\(v.name)'", a.line)
                }
                v.written = true
            case .instanceVariable, .classVariable:
                break
            default:
                throw fail("cannot assign to '\(a.variable.name)'", a.line)
            }
            try analyze(a.value, scope)
        case let s as SendNode:
            if Compiler.inlinable(s) {
                s.inlined = true
                try analyzeInlined(s, scope)
            } else {
                try analyze(s.receiver, scope)
                for x in s.arguments { try analyze(x, scope) }
            }
        case let c as CascadeNode:
            try analyze(c.receiver, scope)
            for m in c.messages { for x in m.arguments { try analyze(x, scope) } }
        case let a as ArrayNode:
            for e in a.elements { try analyze(e, scope) }
        case let b as BlockNode:
            let s = Scope(parent: scope, isReal: true, seq: nextSeq())
            b.scope = s
            for (name, line) in b.arguments { _ = try declare(name, .argument, in: s, line: line) }
            s.argumentCount = b.arguments.count
            for (name, line) in b.temporaries { _ = try declare(name, .temporary, in: s, line: line) }
            try analyzeStatements(b.statements, s)
        default:
            break
        }
    }

    /// An inlined block's body in a scope of its own (not real); its
    /// argument, if any, is a local written by the inlined code.
    mutating func analyzeInlinedBlock(_ n: Node, _ scope: Scope, loop: Bool = false) throws(CompileError) {
        let b = n as! BlockNode
        let s = Scope(parent: scope, isReal: false, isLoop: loop, seq: loop ? nextSeq() : 0)
        if loop { scope.real.loops.append(s) }
        b.scope = s
        for (name, line) in b.arguments { _ = try declare(name, .inlinedArgument, in: s, line: line) }
        for (name, line) in b.temporaries { _ = try declare(name, .temporary, in: s, line: line) }
        try analyzeStatements(b.statements, s)
    }

    mutating func analyzeInlined(_ s: SendNode, _ scope: Scope) throws(CompileError) {
        switch s.selector {
        case "whileTrue:", "whileFalse:", "whileTrue", "whileFalse", "repeat":
            try analyzeInlinedBlock(s.receiver, scope, loop: true)
            for a in s.arguments { try analyzeInlinedBlock(a, scope, loop: true) }
        case "to:do:", "to:by:do:":
            try analyze(s.receiver, scope)
            try analyze(s.arguments[0], scope)
            if s.selector == "to:by:do:" { try analyze(s.arguments[1], scope) }
            if !Compiler.isIntegerLiteral(s.arguments[0]) {
                s.hidden = [try declare("", .hidden, in: scope, line: s.line)]
            }
            try analyzeInlinedBlock(s.arguments.last!, scope, loop: true)
        case "timesRepeat:":
            try analyze(s.receiver, scope)
            s.hidden = [try declare("", .hidden, in: scope, line: s.line)]
            if !Compiler.isIntegerLiteral(s.receiver) { s.hidden.append(try declare("", .hidden, in: scope, line: s.line)) }
            try analyzeInlinedBlock(s.arguments[0], scope, loop: true)
        default:
            try analyze(s.receiver, scope)
            for a in s.arguments { try analyzeInlinedBlock(a, scope) }
        }
    }

    mutating func analyzeStatements(_ st: [Statement], _ scope: Scope) throws(CompileError) {
        for s in st {
            switch s {
            case .expression(let e): try analyze(e, scope)
            case .ret(let e, _): try analyze(e, scope)
            }
        }
    }

    /// Frame layouts, once every reference is known (outermost first).
    func layout(_ r: Scope) {
        let locals = r.locals.sorted { $0.seq < $1.seq }
        if r.parent != nil {
            var items: [Scope.Copied] = []
            for v in r.needed {
                let c: Scope.Copied = v.inVector ? .vector(v.owner) : .variable(v)
                if !items.contains(c) { items.append(c) }
            }
            r.copied = items.sorted { $0.key < $1.key }
        }
        var next = r.argumentCount + r.copied.count
        for (i, v) in locals.filter({ $0.kind == .argument }).enumerated() { v.index = i }
        r.vectorVariables = locals.filter { $0.inVector && $0.owner === r }
        for (i, v) in r.vectorVariables.enumerated() { v.vectorSlot = i }
        if !r.vectorVariables.isEmpty {
            r.vectorTemp = next
            next += 1
        }
        // The other locals and the loop bodies' vector temps, in sequence
        // order (a loop's temp at the loop's own number).
        enum Item { case variable(Variable), loop(Scope) }
        var items: [(Int, Item)] = locals.filter { $0.kind != .argument && !$0.inVector }.map { ($0.seq, .variable($0)) }
        for l in r.loops {
            l.vectorVariables = locals.filter { $0.inVector && $0.owner === l }
            for (i, v) in l.vectorVariables.enumerated() { v.vectorSlot = i }
            if !l.vectorVariables.isEmpty { items.append((l.seq, .loop(l))) }
        }
        for (_, item) in items.sorted(by: { $0.0 < $1.0 }) {
            switch item {
            case .variable(let v): v.index = next
            case .loop(let l): l.vectorTemp = next
            }
            next += 1
        }
        r.tempCount = next - r.argumentCount - r.copied.count
    }

    // MARK: code generation

    final class Emitter {
        var lines: [AsmLine] = []
        func op(_ o: Opcode, _ a: Int = 0, _ b: Int = 0, _ line: Int) { lines.append(AsmLine(.op(o, a, b), line: line)) }
        func emit(_ c: AsmLine.Content, _ line: Int) { lines.append(AsmLine(c, line: line)) }
    }

    mutating func label() -> String {
        labelCounter += 1
        return "L\(labelCounter)"
    }

    func pushVariable(_ v: Variable, _ r: Scope, _ e: Emitter, _ line: Int) {
        if v.real === r {
            if v.inVector { e.op(.pushTempVectorSlot, v.vectorSlot, v.owner.vectorTemp, line) } else { e.op(.pushTemp, v.index, 0, line) }
        } else if v.inVector {
            e.op(.pushTempVectorSlot, v.vectorSlot, r.copiedIndex(.vector(v.owner)), line)
        } else {
            e.op(.pushTemp, r.copiedIndex(.variable(v)), 0, line)
        }
    }

    /// Pop the top into a variable.
    func storeVariable(_ v: Variable, _ r: Scope, _ e: Emitter, _ line: Int) {
        if v.real === r {
            if v.inVector { e.op(.storeTempVectorSlot, v.vectorSlot, v.owner.vectorTemp, line) } else { e.op(.storeTemp, v.index, 0, line) }
        } else {
            // only vector variables are written from inner blocks
            e.op(.storeTempVectorSlot, v.vectorSlot, r.copiedIndex(.vector(v.owner)), line)
        }
    }

    func pushLiteral(_ l: Literal, _ e: Emitter, _ line: Int) {
        switch l {
        case .integer(let v) where v >= -128 && v <= 127: e.op(.pushInt, Int(v), 0, line)
        case .nilObject: e.op(.pushNil, 0, 0, line)
        case .trueObject: e.op(.pushTrue, 0, 0, line)
        case .falseObject: e.op(.pushFalse, 0, 0, line)
        default: e.emit(.pushLiteral(l), line)
        }
    }

    func pushInteger(_ v: Int64, _ e: Emitter, _ line: Int) { pushLiteral(.integer(v), e, line) }

    mutating func gen(_ n: Node, _ r: Scope, _ e: Emitter, value: Bool) throws(CompileError) {
        switch n {
        case let l as LiteralNode:
            if value { pushLiteral(l.value, e, l.line) }
        case let v as VariableNode:
            guard value else { return }
            switch v.binding {
            case .selfVariable, .superVariable: e.op(.pushSelf, 0, 0, v.line)
            case .thisContext: e.op(.pushThisContext, 0, 0, v.line)
            case .local(let x): pushVariable(x, r, e, v.line)
            case .instanceVariable(let i): e.op(.pushIvar, i, 0, v.line)
            case .classVariable(let owner, let name):
                // The Binding, then its value (module 8d: no new bytecode;
                // `value` is the special send, which a Binding answers).
                e.emit(.pushLiteral(.binding(owner: owner, name: name)), v.line)
                send("value", 0, e, v.line)
            case .global(let name): e.emit(.pushLiteral(.classRef(name)), v.line)
            case .unresolved: throw fail("unresolved '\(v.name)'", v.line)
            }
        case let a as AssignNode:
            if case .classVariable(let owner, let name) = a.variable.binding {
                // `value:` answers its argument: the assignment's value.
                e.emit(.pushLiteral(.binding(owner: owner, name: name)), a.line)
                try gen(a.value, r, e, value: true)
                send("value:", 1, e, a.line)
                if !value { e.op(.pop, 0, 0, a.line) }
                return
            }
            try gen(a.value, r, e, value: true)
            if value { e.op(.dup, 0, 0, a.line) }
            switch a.variable.binding {
            case .local(let x): storeVariable(x, r, e, a.line)
            case .instanceVariable(let i): e.op(.storeIvar, i, 0, a.line)
            default: throw fail("cannot assign to '\(a.variable.name)'", a.line)
            }
        case let s as SendNode:
            if s.inlined {
                try genInlined(s, r, e, value: value)
                return
            }
            if s.isSuper {
                e.op(.pushSelf, 0, 0, s.line)
                for a in s.arguments { try gen(a, r, e, value: true) }
                e.emit(.send(.sendSuper, s.selector, s.arguments.count), s.line)
            } else {
                try gen(s.receiver, r, e, value: true)
                for a in s.arguments { try gen(a, r, e, value: true) }
                send(s.selector, s.arguments.count, e, s.line)
            }
            if !value { e.op(.pop, 0, 0, s.line) }
        case let c as CascadeNode:
            let isSuper = (c.receiver as? VariableNode)?.name == "super"
            try gen(c.receiver, r, e, value: true)
            for (k, m) in c.messages.enumerated() {
                let last = k == c.messages.count - 1
                if !last { e.op(.dup, 0, 0, m.line) }
                for a in m.arguments { try gen(a, r, e, value: true) }
                if isSuper { e.emit(.send(.sendSuper, m.selector, m.arguments.count), m.line) }
                else { send(m.selector, m.arguments.count, e, m.line) }
                if !last { e.op(.pop, 0, 0, m.line) }
            }
            if !value { e.op(.pop, 0, 0, c.line) }
        case let a as ArrayNode:
            e.op(.pushNewArray, a.elements.count, 0, a.line)
            for (i, x) in a.elements.enumerated() {
                e.op(.dup, 0, 0, x.line)
                pushInteger(Int64(i + 1), e, x.line)
                try gen(x, r, e, value: true)
                e.op(.atPut, 0, 0, x.line)
                e.op(.pop, 0, 0, x.line)
            }
            if !value { e.op(.pop, 0, 0, a.line) }
        case let b as BlockNode:
            if value { try genClosure(b, r, e) }
        default:
            throw fail("unknown node", n.line)
        }
    }

    func send(_ selector: String, _ argc: Int, _ e: Emitter, _ line: Int) {
        if let op = specialOpcodes[selector], op.specialArgc == argc { e.op(op, 0, 0, line) }
        else { e.emit(.send(.send, selector, argc), line) }
    }

    /// A real block: its body as a block method, then the closure from `r`.
    mutating func genClosure(_ b: BlockNode, _ r: Scope, _ e: Emitter) throws(CompileError) {
        let s = b.scope!
        layout(s)
        blockCounter += 1
        let name = "block\(blockCounter)"
        let slot = blocks.count
        blocks.append(AsmBlock(name: name, line: b.line, args: s.argumentCount, copied: s.copied.count, temps: s.tempCount, body: []))
        let body = Emitter()
        if s.vectorTemp >= 0 {
            body.op(.pushNewArray, s.vectorVariables.count, 0, b.line)
            body.op(.storeTemp, s.vectorTemp, 0, b.line)
        }
        if b.statements.isEmpty {
            body.op(.pushNil, 0, 0, b.line)
            body.op(.blockReturn, 0, 0, b.line)
        } else {
            for (k, st) in b.statements.enumerated() {
                let last = k == b.statements.count - 1
                switch st {
                case .expression(let x):
                    try gen(x, s, body, value: last)
                    if last { body.op(.blockReturn, 0, 0, x.line) }
                case .ret(let x, let line):
                    try genReturn(x, s, body, line)
                }
            }
        }
        blocks[slot].body = body.lines
        // the copied values, as `r` sees them
        for c in s.copied {
            switch c {
            case .variable(let v):
                e.op(.pushTemp, v.real === r ? v.index : r.copiedIndex(.variable(v)), 0, b.line)
            case .vector(let owner):
                e.op(.pushTemp, owner.real === r ? owner.vectorTemp : r.copiedIndex(.vector(owner)), 0, b.line)
            }
        }
        e.emit(.pushClosure(name, s.copied.count), b.line)
    }

    mutating func genReturn(_ x: Node, _ r: Scope, _ e: Emitter, _ line: Int) throws(CompileError) {
        if r.parent == nil {
            if let v = x as? VariableNode, case .selfVariable = v.binding {
                e.op(.returnSelf, 0, 0, line)
                return
            }
            try gen(x, r, e, value: true)
            e.op(.returnTop, 0, 0, line)
        } else {
            try gen(x, r, e, value: true)
            e.op(.nonlocalReturn, 0, 0, line)
        }
    }

    /// An inlined block's statements in the enclosing real scope; the last
    /// one's value is left when `value`; an empty body is nil.
    mutating func genInlinedBody(_ n: Node, _ r: Scope, _ e: Emitter, value: Bool) throws(CompileError) {
        let b = n as! BlockNode
        // A loop body that owns a vector makes a fresh one on every pass.
        if b.scope.isLoop && b.scope.vectorTemp >= 0 {
            e.op(.pushNewArray, b.scope.vectorVariables.count, 0, b.line)
            e.op(.storeTemp, b.scope.vectorTemp, 0, b.line)
        }
        if b.statements.isEmpty {
            if value { e.op(.pushNil, 0, 0, b.line) }
            return
        }
        for (k, st) in b.statements.enumerated() {
            let last = k == b.statements.count - 1
            switch st {
            case .expression(let x): try gen(x, r, e, value: last && value)
            case .ret(let x, let line): try genReturn(x, r, e, line)
            }
        }
    }

    /// The inlined block's argument (a local) takes the top of the stack;
    /// without an argument the top is dropped.
    func bindInlinedArgument(_ n: Node, _ r: Scope, _ e: Emitter) {
        let b = n as! BlockNode
        if let v = b.scope.declared.first, b.arguments.count == 1 { storeVariable(v, r, e, b.line) }
        else { e.op(.pop, 0, 0, b.line) }
    }

    mutating func genInlined(_ s: SendNode, _ r: Scope, _ e: Emitter, value: Bool) throws(CompileError) {
        let a = s.arguments
        let line = s.line
        switch s.selector {
        case "ifTrue:", "ifFalse:":
            try gen(s.receiver, r, e, value: true)
            let jump: Opcode = s.selector == "ifTrue:" ? .jumpIfFalse : .jumpIfTrue
            let end = label()
            if value {
                let other = label()
                e.emit(.jump(jump, other), line)
                try genInlinedBody(a[0], r, e, value: true)
                e.emit(.jump(.jump, end), line)
                e.emit(.label(other), line)
                e.op(.pushNil, 0, 0, line)
            } else {
                e.emit(.jump(jump, end), line)
                try genInlinedBody(a[0], r, e, value: false)
            }
            e.emit(.label(end), line)
        case "ifTrue:ifFalse:", "ifFalse:ifTrue:":
            try gen(s.receiver, r, e, value: true)
            let jump: Opcode = s.selector == "ifTrue:ifFalse:" ? .jumpIfFalse : .jumpIfTrue
            let other = label(), end = label()
            e.emit(.jump(jump, other), line)
            try genInlinedBody(a[0], r, e, value: value)
            e.emit(.jump(.jump, end), line)
            e.emit(.label(other), line)
            try genInlinedBody(a[1], r, e, value: value)
            e.emit(.label(end), line)
        case "and:", "or:":
            try gen(s.receiver, r, e, value: true)
            let short = label(), end = label()
            e.emit(.jump(s.selector == "and:" ? .jumpIfFalse : .jumpIfTrue, short), line)
            try genInlinedBody(a[0], r, e, value: true)
            e.emit(.jump(.jump, end), line)
            e.emit(.label(short), line)
            e.op(s.selector == "and:" ? .pushFalse : .pushTrue, 0, 0, line)
            e.emit(.label(end), line)
            if !value { e.op(.pop, 0, 0, line) }
        case "ifNil:", "ifNotNil:":
            try gen(s.receiver, r, e, value: true)
            let end = label()
            e.op(.dup, 0, 0, line)
            e.op(.isNil, 0, 0, line)
            if s.selector == "ifNil:" {
                e.emit(.jump(.jumpIfFalse, end), line)
                e.op(.pop, 0, 0, line)
            } else {
                e.emit(.jump(.jumpIfTrue, end), line)
                bindInlinedArgument(a[0], r, e)
            }
            try genInlinedBody(a[0], r, e, value: true)
            e.emit(.label(end), line)
            if !value { e.op(.pop, 0, 0, line) }
        case "ifNil:ifNotNil:", "ifNotNil:ifNil:":
            try gen(s.receiver, r, e, value: true)
            let other = label(), end = label()
            e.op(.dup, 0, 0, line)
            e.op(.isNil, 0, 0, line)
            if s.selector == "ifNil:ifNotNil:" {
                e.emit(.jump(.jumpIfFalse, other), line)
                e.op(.pop, 0, 0, line)
                try genInlinedBody(a[0], r, e, value: true)
                e.emit(.jump(.jump, end), line)
                e.emit(.label(other), line)
                bindInlinedArgument(a[1], r, e)
                try genInlinedBody(a[1], r, e, value: true)
            } else {
                e.emit(.jump(.jumpIfTrue, other), line)
                bindInlinedArgument(a[0], r, e)
                try genInlinedBody(a[0], r, e, value: true)
                e.emit(.jump(.jump, end), line)
                e.emit(.label(other), line)
                e.op(.pop, 0, 0, line)
                try genInlinedBody(a[1], r, e, value: true)
            }
            e.emit(.label(end), line)
            if !value { e.op(.pop, 0, 0, line) }
        case "whileTrue:", "whileFalse:":
            let loop = label(), end = label()
            e.emit(.label(loop), line)
            try genInlinedBody(s.receiver, r, e, value: true)
            e.emit(.jump(s.selector == "whileTrue:" ? .jumpIfFalse : .jumpIfTrue, end), line)
            try genInlinedBody(a[0], r, e, value: false)
            e.emit(.jump(.jump, loop), line)
            e.emit(.label(end), line)
            if value { e.op(.pushNil, 0, 0, line) }
        case "whileTrue", "whileFalse":
            let loop = label()
            e.emit(.label(loop), line)
            try genInlinedBody(s.receiver, r, e, value: true)
            e.emit(.jump(s.selector == "whileTrue" ? .jumpIfTrue : .jumpIfFalse, loop), line)
            if value { e.op(.pushNil, 0, 0, line) }
        case "repeat":
            let loop = label()
            e.emit(.label(loop), line)
            try genInlinedBody(s.receiver, r, e, value: false)
            e.emit(.jump(.jump, loop), line)
        case "to:do:", "to:by:do:":
            let block = a.last! as! BlockNode
            let counter = block.scope.declared[0]
            var step: Int64 = 1
            if s.selector == "to:by:do:", let l = a[1] as? LiteralNode, case .integer(let v) = l.value { step = v }
            try gen(s.receiver, r, e, value: true)
            storeVariable(counter, r, e, line)
            if let limit = s.hidden.first {
                try gen(a[0], r, e, value: true)
                storeVariable(limit, r, e, line)
            }
            let loop = label(), end = label()
            e.emit(.label(loop), line)
            pushVariable(counter, r, e, line)
            if let limit = s.hidden.first { pushVariable(limit, r, e, line) } else { try gen(a[0], r, e, value: true) }
            e.op(step > 0 ? .le : .ge, 0, 0, line)
            e.emit(.jump(.jumpIfFalse, end), line)
            try genInlinedBody(block, r, e, value: false)
            pushVariable(counter, r, e, line)
            pushInteger(step, e, line)
            e.op(.add, 0, 0, line)
            storeVariable(counter, r, e, line)
            e.emit(.jump(.jump, loop), line)
            e.emit(.label(end), line)
            if value { e.op(.pushNil, 0, 0, line) }
        case "timesRepeat:":
            let counter = s.hidden[0]
            pushInteger(1, e, line)
            storeVariable(counter, r, e, line)
            if s.hidden.count > 1 {
                try gen(s.receiver, r, e, value: true)
                storeVariable(s.hidden[1], r, e, line)
            }
            let loop = label(), end = label()
            e.emit(.label(loop), line)
            pushVariable(counter, r, e, line)
            if s.hidden.count > 1 { pushVariable(s.hidden[1], r, e, line) } else { try gen(s.receiver, r, e, value: true) }
            e.op(.le, 0, 0, line)
            e.emit(.jump(.jumpIfFalse, end), line)
            try genInlinedBody(a[0], r, e, value: false)
            pushVariable(counter, r, e, line)
            pushInteger(1, e, line)
            e.op(.add, 0, 0, line)
            storeVariable(counter, r, e, line)
            e.emit(.jump(.jump, loop), line)
            e.emit(.label(end), line)
            if value { e.op(.pushNil, 0, 0, line) }
        default:
            throw fail("not inlinable: \(s.selector)", line)
        }
    }

    // MARK: a method

    mutating func compile(_ m: MethodNode) throws(CompileError) -> CompiledSource {
        let scope = Scope(parent: nil, isReal: true, seq: nextSeq())
        m.scope = scope
        for (name, line) in m.arguments {
            if context.instanceVariables.contains(name) { throw fail("argument '\(name)' shadows an instance variable", line) }
            _ = try declare(name, .argument, in: scope, line: line)
        }
        scope.argumentCount = m.arguments.count
        for (name, line) in m.temporaries {
            if context.instanceVariables.contains(name) { throw fail("temporary '\(name)' shadows an instance variable", line) }
            _ = try declare(name, .temporary, in: scope, line: line)
        }
        try analyzeStatements(m.statements, scope)
        layout(scope)

        var primitive = 0, unwind = false, handler = false
        var pragmas: [PragmaNode] = []
        for p in m.pragmas {
            switch p.selector {
            case "primitive:":
                guard case .integer(let n) = p.arguments[0], n >= 1, n <= 255 else { throw fail("primitive: takes 1...255", p.line) }
                if primitive != 0 { throw fail("two primitives", p.line) }
                primitive = Int(n)
            case "unwind": unwind = true
            case "handler": handler = true
            default: pragmas.append(p)
            }
        }
        let e = Emitter()
        if scope.vectorTemp >= 0 {
            e.op(.pushNewArray, scope.vectorVariables.count, 0, m.line)
            e.op(.storeTemp, scope.vectorTemp, 0, m.line)
        }
        var returned = false
        for st in m.statements {
            switch st {
            case .expression(let x): try gen(x, scope, e, value: false)
            case .ret(let x, let line):
                try genReturn(x, scope, e, line)
                returned = true
            }
        }
        if !returned { e.op(.returnSelf, 0, 0, m.line) }

        var asm = AsmMethod(file: file, line: m.line, className: context.className, selector: m.selector,
                            temps: scope.tempCount, primitive: primitive)
        asm.classSide = context.classSide
        asm.unwind = unwind
        asm.handler = handler
        asm.pragmas = pragmas.map { ($0.selector, $0.arguments, $0.line) }
        asm.body = e.lines
        asm.blocks = blocks
        return CompiledSource(method: asm, pragmas: pragmas)
    }
}

/// Compile one method's source in a class: parse, analyse, generate,
/// assemble and verify. The result is ready for the image (`Image.install`).
func compileMethod(_ source: [UInt8], file: String, line: Int = 1, in context: ClassContext,
                   limits: LoaderLimits = LoaderLimits()) throws(CompileError) -> (AssembledMethod, [PragmaNode]) {
    let tree = try parseMethod(source, file: file, line: line)
    var c = Compiler(context: context, file: file)
    let out = try c.compile(tree)
    do {
        return (try assemble(out.method, limits: limits), out.pragmas)
    } catch {
        throw CompileError(error.message, file: file, line: error.line)
    }
}
