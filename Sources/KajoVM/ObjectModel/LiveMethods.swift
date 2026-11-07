// Module 8d: installing from Smalltalk.
//
//   85   CompiledMethod valueWithReceiver: anObject arguments: anArray
//        (an activation primitive, Interpreter/Special.swift): run a method
//        once without installing it; the receiver's class must inherit the
//        method's class, the method takes the Array's size of arguments and
//        has no primitive
//   97   Behavior primAddSelector:withMethod: (8a's install, in a stop),
//   98   Behavior primRemoveSelector:, now refused in a release image and
//        for a sealed class (below, `installTarget`)
//   143  CompiledCode primMakeMethodIn: aBehavior: the kernel compiler's
//        output (a CompiledCode: bytecodes, literals with block methods as
//        CompiledCode and pragmas as Pragmas, counts, primitive, flags,
//        copied count) made into a CompiledMethod of aBehavior, or a String
//        saying why not; fails in a release image
//   144  Smalltalk isReleaseImage
//   166  CompiledMethod plainBytecodes (interpreter speed): a new ByteArray
//        of the method's bytecodes with every fused opcode replaced by its
//        first part, what the compilers emitted before the peephole
//        (`fuseBytecodes`); the compiler tests compare against it
//
// The make primitive is the trust boundary, not the compiler: whatever the
// CompiledCode says, the method it answers passed the one bytecode
// verifier (`verifyHeapMethod`, the image loader's check) as a method of
// aBehavior, each of its block methods as a block of it; its bytecodes are
// a copy (the compiler's ByteArray stays the compiler's), its literal
// frame and every literal it made are read-only, the method objects are
// read-only and pinned for good, all before any other Process can see
// them: the graph is read and the objects made in one stop, with the
// shared `makeMethodObjects` the image build uses.

/// The kernel's CompiledCode (`kernel/CompiledCode.class.st`): what the
/// make primitive reads, by slot. Any object of the receiver's class in
/// the literals is a block method's code.
enum CompiledCodeLayout {
    static let selector = 0
    static let bytecodes = 1
    static let literals = 2
    static let argc = 3
    static let temps = 4
    static let maxStack = 5
    static let primitive = 6
    static let flags = 7
    static let copied = 8
    static let size = 9
}

/// Bounds on what one make reads, so a hostile graph is refused before it
/// costs much: block methods, literal Array elements, nesting.
enum MakeLimits {
    static let blocks = 4096
    static let arrayElements = 1 << 16
    static let depth = 64
}

enum LiveMethodPrimitives {
    static let table: [(number: Int, selector: String, argc: Int)] = [
        (143, "CompiledCode primMakeMethodIn:", 1), (144, "Smalltalk isReleaseImage", 0),
        (166, "CompiledMethod plainBytecodes", 0),
    ]
}

@inline(never)
func liveMethodPrimitive(_ n: Int, _ m: Machine, _ c: PrimitiveCall) -> Oop {
    switch n {
    case 143: return primMakeMethod(m, c)
    case 144: return c.argc == 0 ? m.boolean(m.om.isReleaseImage) : .none
    case 166: return primPlainBytecodes(m, c)
    default: return .none
    }
}

/// The class a method may be installed into or removed from: refused in a
/// release image and for a sealed class. A metaclass is sealed (its
/// instances are classes), but `Foo class` takes class-side methods unless
/// Foo itself is sealed: the rule is the class the methods are for. The
/// kernel's Class, Metaclass, Behavior, CompiledMethod, MethodDictionary,
/// Process, Context and the other `isSealed` classes, and their class
/// sides, change only through the image build.
func installTarget(_ m: Machine, _ cls: Oop) -> UInt64? {
    let om = m.om
    guard !om.isReleaseImage, om.isBehavior(cls) else { return nil }
    let ciOop = om.load(cls, ClassLayout.classIndex)
    guard ciOop.isSmallInteger, ciOop.smallIntegerValue > 0, ciOop.smallIntegerValue < Int64(om.classCount) else { return nil }
    let ci = UInt64(ciOop.smallIntegerValue)
    guard om.classOop(ci) == cls else { return nil }
    var instancesOf = ci
    if om.classIndex(of: cls) == WellKnown.metaclass {
        let this = om.load(cls, MetaclassLayout.thisClass)
        guard om.isBehavior(this) else { return nil }
        let ti = om.load(this, ClassLayout.classIndex)
        guard ti.isSmallInteger, ti.smallIntegerValue > 0, ti.smallIntegerValue < Int64(om.classCount) else { return nil }
        instancesOf = UInt64(ti.smallIntegerValue)
    }
    return om.isSealed(instancesOf) ? nil : ci
}

/// Module 9b: the class index of a sealed class (or its class side) a
/// method may extend (`sealedExtensionProblem`), nil in a release image or
/// for anything else `installTarget` refuses.
func sealedTarget(_ m: Machine, _ cls: Oop) -> UInt64? {
    let om = m.om
    guard !om.isReleaseImage, om.isBehavior(cls) else { return nil }
    let ciOop = om.load(cls, ClassLayout.classIndex)
    guard ciOop.isSmallInteger, ciOop.smallIntegerValue > 0, ciOop.smallIntegerValue < Int64(om.classCount) else { return nil }
    let ci = UInt64(ciOop.smallIntegerValue)
    return om.classOop(ci) == cls ? ci : nil
}

/// Module 9b (the owner's question 2 of 8d, provisional): why a method
/// may not join a sealed class, or nil. Such a method can only send
/// messages, which a method of any class could already: no primitive, no
/// instance-variable access (the verifier refuses it too for a sealed
/// class), and no send of a selector that writes a slot or swaps
/// identities (`slotAt:put:`, `instVarAt:put:`, `become:`,
/// `becomeForward:`; a Symbol literal of them counts, for `perform:`), in
/// the method and in every block method of it.
func sealedExtensionProblem(_ om: ObjectMemory, _ method: Oop, depth: Int = 0) -> String? {
    guard depth < 64, method.isObject, om.classIndex(of: method) == WellKnown.method, !om.isBytes(method) else {
        return "not a method"
    }
    let prim = om.load(method, MethodLayout.primitive)
    if prim != Oop(smallInteger: 0) { return "it has a primitive" }
    let bc = om.load(method, MethodLayout.bytecodes)
    guard bc.isObject, om.isBytes(bc) else { return "not a method" }
    let bytes = om.bytes(of: bc)
    var at = 0
    while at < bytes.count {
        guard let i = decodeInstruction(bytes, at: at) else { return "unreadable bytecodes" }
        if i.op == .pushIvar || i.op == .storeIvar { return "it reads or writes an instance variable" }
        at += i.length
    }
    let lits = om.load(method, MethodLayout.literals)
    guard lits.isObject, !om.isBytes(lits) else { return "not a method" }
    let forbidden: Set<String> = ["slotAt:put:", "instVarAt:put:", "become:", "becomeForward:"]
    for k in 0..<Int(om.count(of: lits)) {
        let l = om.load(lits, k)
        guard l.isObject else { continue }
        let lc = om.classIndex(of: l)
        if lc == WellKnown.symbol, om.isBytes(l), let s = String(validating: om.bytes(of: l), as: UTF8.self), forbidden.contains(s) {
            return "it sends \(s)"
        }
        if lc == WellKnown.method, let why = sealedExtensionProblem(om, l, depth: depth + 1) { return why }
    }
    return nil
}

/// What making a method came to: the method, or why not.
enum MakeOutcome {
    case made(Oop)
    case refused(String)
}

/// Primitive 143: `aCompiledCode primMakeMethodIn: aBehavior`.
private func primMakeMethod(_ m: Machine, _ c: PrimitiveCall) -> Oop {
    let om = m.om
    guard c.argc == 1, !om.isReleaseImage, c.receiver.isObject, !om.isBytes(c.receiver), om.isBehavior(c.arg0) else { return .none }
    let ciOop = om.load(c.arg0, ClassLayout.classIndex)
    guard ciOop.isSmallInteger, ciOop.smallIntegerValue > 0, ciOop.smallIntegerValue < Int64(om.classCount),
          om.classOop(UInt64(ciOop.smallIntegerValue)) == c.arg0 else { return .none }
    let ci = UInt64(ciOop.smallIntegerValue)
    var outcome = MakeOutcome.refused("not made")
    if let vm = unsafe workerOf(m.state).pointee.vm {
        unsafe stopWorld(vm, workerOf(m.state), retry: true, keeping: [c.receiver, c.arg0]) { stop in
            outcome = makeMethod(m, code: c.receiver, methodClass: c.arg0, classIndex: ci, roots: stop.roots() + [c.receiver, c.arg0])
        }
    } else {
        outcome = makeMethod(m, code: c.receiver, methodClass: c.arg0, classIndex: ci, roots: m.rootsForPause() + [c.receiver, c.arg0])
    }
    switch outcome {
    case .made(let meth):
        unsafe m.state.pointee.counters.methodsMade &+= 1
        return meth
    case .refused(let why):
        unsafe m.state.pointee.counters.methodsRefused &+= 1
        return m.newString(Array(why.utf8))
    }
}

/// Read the CompiledCode graph, make the method, verify it and each of its
/// block methods. The world is stopped (or there is no VM): nothing else
/// changes the graph while it is read, and nothing else sees the method
/// until the primitive answers it.
func makeMethod(_ m: Machine, code: Oop, methodClass: Oop, classIndex ci: UInt64, roots: [Oop], format: ClassFormat? = nil,
                onMade: ((Oop, [Int: Oop]) -> Void)? = nil) -> MakeOutcome {
    let om = m.om
    var reader = CodeReader(om: om, nilObject: m.nilObject, trueObject: m.trueObject, falseObject: m.falseObject,
                            codeClass: om.classIndex(of: code))
    let top: MethodParts
    switch reader.read(code, isBlock: false, depth: 0) {
    case .success(let p): top = p
    case .failure(let why): return .refused(why.message)
    }
    let selector = om.load(code, CompiledCodeLayout.selector)
    guard selector.isObject, om.classIndex(of: selector) == WellKnown.symbol else { return .refused("the selector is not a Symbol") }
    var heap = LiveMethodHeap(m: m, roots: roots)
    let made: (method: Oop, blocks: [Int: Oop])
    do {
        made = try makeMethodObjects(top, blocks: reader.blocks, selector: selector, methodClass: methodClass, heap: &heap)
    } catch {
        return .refused(error.message)
    }
    if let issue = verifyHeapMethod(om, made.method, classIndex: ci, nilObject: m.nilObject, format: format) { return .refused(issue) }
    for (k, b) in made.blocks.sorted(by: { $0.key < $1.key }) {
        if let issue = verifyHeapMethod(om, b, classIndex: ci, nilObject: m.nilObject, format: format) {
            return .refused("block method \(k + 1): \(issue)")
        }
    }
    if made.blocks.count != reader.blocks.count { return .refused("a block method no literal names") }
    onMade?(made.method, made.blocks)
    return .made(made.method)
}

struct MakeRefusal: Error { let message: String }

/// The CompiledCode graph to `MethodParts`, checking only what making the
/// objects needs (shapes, sizes, literal kinds); the verifier checks the
/// rest on the objects made.
struct CodeReader {
    let om: ObjectMemory
    let nilObject: Oop
    let trueObject: Oop
    let falseObject: Oop
    let codeClass: UInt64
    var blocks: [MethodParts] = []
    var seen: [Oop] = []
    var elements = 0

    mutating func read(_ o: Oop, isBlock: Bool, depth: Int) -> Result<MethodParts, MakeRefusal> {
        func refuse(_ s: String) -> Result<MethodParts, MakeRefusal> { .failure(MakeRefusal(message: s)) }
        if depth > MakeLimits.depth { return refuse("block methods nested deeper than \(MakeLimits.depth)") }
        guard o.isObject, om.classIndex(of: o) == codeClass, !om.isBytes(o),
              om.count(of: o) >= UInt64(CompiledCodeLayout.size) else { return refuse("not a CompiledCode") }
        if seen.contains(o) { return refuse("a CompiledCode named twice (each block method has one place)") }
        seen.append(o)
        func int(_ i: Int) -> Int? {
            let v = om.load(o, i)
            return v.isSmallInteger && v.smallIntegerValue >= 0 && v.smallIntegerValue < 1 << 20 ? Int(v.smallIntegerValue) : nil
        }
        guard let argc = int(CompiledCodeLayout.argc), let temps = int(CompiledCodeLayout.temps),
              let maxStack = int(CompiledCodeLayout.maxStack), let prim = int(CompiledCodeLayout.primitive),
              let flags = int(CompiledCodeLayout.flags), let copied = int(CompiledCodeLayout.copied)
        else { return refuse("a count is not a small non-negative integer") }
        if (Int64(flags) & MethodFlags.block != 0) != isBlock {
            return refuse(isBlock ? "a block literal without the block flag" : "a method with the block flag")
        }
        if isBlock && om.load(o, CompiledCodeLayout.selector) != nilObject { return refuse("a block method with a selector") }
        let bc = om.load(o, CompiledCodeLayout.bytecodes)
        guard bc.isObject, om.classIndex(of: bc) == WellKnown.byteArray, om.isBytes(bc) else { return refuse("bytecodes not a ByteArray") }
        let lits = om.load(o, CompiledCodeLayout.literals)
        guard lits.isObject, om.classIndex(of: lits) == WellKnown.array, !om.isBytes(lits) else { return refuse("literals not an Array") }
        let n = Int(om.count(of: lits))
        if n > LoaderLimits().maxLiterals { return refuse("more than \(LoaderLimits().maxLiterals) literals") }
        var out: [PartLiteral] = []
        for k in 0..<n {
            switch literal(om.load(lits, k), depth: depth, inArray: false) {
            case .success(let l): out.append(l)
            case .failure(let e): return refuse("literal \(k + 1): \(e.message)")
            }
        }
        return .success(MethodParts(bytecodes: om.bytes(of: bc), literals: out, argc: argc, temps: temps, maxStack: maxStack,
                                    primitive: prim, flags: Int64(flags), copied: copied))
    }

    mutating func literal(_ v: Oop, depth: Int, inArray: Bool) -> Result<PartLiteral, MakeRefusal> {
        func refuse(_ s: String) -> Result<PartLiteral, MakeRefusal> { .failure(MakeRefusal(message: s)) }
        if !v.isObject || v == nilObject || v == trueObject || v == falseObject { return .success(.object(v)) }
        let ci = om.classIndex(of: v)
        if ci == WellKnown.symbol || om.isBehavior(v) { return .success(.object(v)) }
        if om.isBytes(v) {
            let b = om.bytes(of: v)
            switch ci {
            case WellKnown.string, WellKnown.byteArray:
                return .success(.bytes(ci, b))
            case WellKnown.float:
                guard b.count == 8 else { return refuse("a Float of \(b.count) bytes") }
                var bits: UInt64 = 0
                for (i, x) in b.enumerated() { bits |= UInt64(x) << (8 * UInt64(i)) }
                if let f = Oop(smallFloat: Double(bitPattern: bits)) { return .success(.object(f)) }
                return .success(.bytes(ci, b))
            case WellKnown.largePositiveInteger, WellKnown.largeNegativeInteger:
                // normalized: no high zero byte, beyond SmallInteger's range
                guard let last = b.last, last != 0 else { return refuse("a LargeInteger with a high zero byte") }
                if b.count <= 8 {
                    var mag: UInt64 = 0
                    for (i, x) in b.enumerated() { mag |= UInt64(x) << (8 * UInt64(i)) }
                    if mag <= UInt64(Int64.max), Oop.fitsSmallInteger(ci == WellKnown.largeNegativeInteger ? -Int64(mag) : Int64(mag)) {
                        return refuse("a LargeInteger in SmallInteger's range")
                    }
                }
                return .success(.bytes(ci, b))
            default:
                return refuse("a byte object of class \(ci)")
            }
        }
        if depth > MakeLimits.depth { return refuse("literal Arrays nested deeper than \(MakeLimits.depth)") }
        if ci == WellKnown.array {
            let n = Int(om.count(of: v))
            elements += n
            if elements > MakeLimits.arrayElements { return refuse("more than \(MakeLimits.arrayElements) literal Array elements") }
            var out: [PartLiteral] = []
            for i in 0..<n {
                switch literal(om.load(v, i), depth: depth + 1, inArray: true) {
                case .success(let l): out.append(l)
                case .failure(let e): return .failure(e)
                }
            }
            return .success(.array(out))
        }
        if inArray { return refuse("an element of class \(ci) in a literal Array") }
        if ci == codeClass {
            if blocks.count >= MakeLimits.blocks { return refuse("more than \(MakeLimits.blocks) block methods") }
            switch read(v, isBlock: true, depth: depth + 1) {
            case .success(let p):
                blocks.append(p)
                return .success(.block(blocks.count - 1))
            case .failure(let e): return .failure(MakeRefusal(message: "a block method: \(e.message)"))
            }
        }
        if ci == WellKnown.pragma {
            guard !om.isBytes(v), om.count(of: v) >= UInt64(PragmaLayout.size) else { return refuse("a Pragma's shape") }
            let sel = om.load(v, PragmaLayout.selector), args = om.load(v, PragmaLayout.arguments)
            guard sel.isObject, om.classIndex(of: sel) == WellKnown.symbol else { return refuse("a Pragma whose selector is not a Symbol") }
            guard args.isObject, om.classIndex(of: args) == WellKnown.array, !om.isBytes(args) else {
                return refuse("a Pragma whose arguments are not an Array")
            }
            guard let name = String(validating: om.bytes(of: sel), as: UTF8.self), isSelector(name),
                  arity(of: name) == Int(om.count(of: args)) else { return refuse("a Pragma's selector and argument count disagree") }
            var out: [PartLiteral] = []
            for i in 0..<Int(om.count(of: args)) {
                switch literal(om.load(args, i), depth: depth + 1, inArray: true) {
                case .success(let l): out.append(l)
                case .failure(let e): return .failure(e)
                }
            }
            return .success(.pragma(sel, out))
        }
        if om.isSealed(ci) { return refuse("an instance of a sealed class (\(ci))") }
        // Any other object is used as it is (a class variable's Binding).
        return .success(.object(v))
    }
}

/// The make primitive's `MethodHeap`: the worker's allocation context, old
/// space (the world is stopped), with the stop's roots and every object
/// made so far as extra roots of each allocation.
struct LiveMethodHeap: MethodHeap {
    let m: Machine
    var roots: [Oop]
    var om: ObjectMemory { m.om }
    var nilObject: Oop { m.nilObject }
    var pinsForGood: Bool { true }

    mutating func pointers(_ cls: UInt64, _ slots: Int) throws(LoadError) -> Oop {
        guard slots <= Header.maxSlots,
              let o = om.allocate(unsafe m.state.pointee.context, classIndex: cls, slots: slots, fill: m.nilObject, extraRoots: roots)
        else { throw LoadError(.heapFull, "the heap has no room for the method") }
        return o
    }

    mutating func bytes(_ cls: UInt64, _ b: [UInt8]) throws(LoadError) -> Oop {
        // Module 10: a literal String or ByteArray may be a large object
        // (old, never moved); the bytecodes are bounded by the loader's
        // limits before they get here.
        guard b.count <= Header.maxLargeCount,
              let o = om.allocateBytes(unsafe m.state.pointee.context, classIndex: cls, count: b.count, extraRoots: roots)
        else { throw LoadError(.heapFull, "the heap has no room for the method") }
        for (i, x) in b.enumerated() { om.storeByte(o, i, x) }
        return o
    }

    mutating func keep(_ o: Oop) { if o.isObject { roots.append(o) } }
}

/// Primitive 166: the receiver's bytecodes as the compilers emitted them,
/// before the fusion peephole (`fuseBytecodes` only rewrites first bytes,
/// each to a fused opcode whose first part it was).
func primPlainBytecodes(_ m: Machine, _ c: PrimitiveCall) -> Oop {
    let om = m.om
    guard c.argc == 0, c.receiver.isObject, om.classIndex(of: c.receiver) == WellKnown.method else { return .none }
    let bc = om.load(c.receiver, MethodLayout.bytecodes)
    var bytes = om.bytes(of: bc)
    var off = 0
    while off < bytes.count, let d = decodeInstruction(bytes, at: off) {
        if d.fused != nil { bytes[off] = d.op.rawValue }
        off += d.length
    }
    let out = m.allocateBytes(WellKnown.byteArray, count: bytes.count)
    if out == .none { return .none }
    for (i, b) in bytes.enumerated() { om.storeByte(out, i, b) }
    return out
}
