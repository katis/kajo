// Module 8d: a method's heap objects, made one way for the image build
// (`Image.installKernelMethods` and the kasm loader, on the host before any
// VM) and for the make-method primitive (143, in a stop of a running VM):
// the CompiledMethod and its block methods, their bytecodes and literal
// Arrays pinned for good (the interpreter caches raw pointers into the
// last two) and read-only, the method objects read-only, String, Float,
// LargeInteger and ByteArray literals and literal Arrays made afresh,
// pinned and read-only, Pragmas made for the method and read-only. The
// callers differ only in where the objects are allocated and how the ones
// made so far are kept reachable (`MethodHeap`).

/// One method or block method before it is in the heap.
struct MethodParts {
    var bytecodes: [UInt8]
    var literals: [PartLiteral]
    var argc: Int
    var temps: Int
    var maxStack: Int
    var primitive: Int
    var flags: Int64
    var copied: Int
}

/// A literal of `MethodParts`.
indirect enum PartLiteral {
    /// An immediate, or an object used as it is: a Symbol, a class, a
    /// class variable's Binding, nil, true, false.
    case object(Oop)
    /// A byte object made afresh (class index, bytes): a String, a boxed
    /// Float, a LargeInteger, a ByteArray.
    case bytes(UInt64, [UInt8])
    /// A literal Array made afresh with its elements.
    case array([PartLiteral])
    /// Block method k of the method's blocks.
    case block(Int)
    /// A Pragma made for the method: its selector (a Symbol) and arguments.
    case pragma(Oop, [PartLiteral])
}

/// Where a method's objects come from: allocation in the caller's context
/// (old space), with every object made so far kept reachable (`keep`)
/// until the method holds it.
protocol MethodHeap {
    var om: ObjectMemory { get }
    var nilObject: Oop { get }
    /// Module 6: pin for good (false only in module 2's re-derivation tests).
    var pinsForGood: Bool { get }
    mutating func pointers(_ cls: UInt64, _ slots: Int) throws(LoadError) -> Oop
    mutating func bytes(_ cls: UInt64, _ b: [UInt8]) throws(LoadError) -> Oop
    mutating func keep(_ o: Oop)
}

/// Make `top` (a method, `selector` a Symbol) and its block methods
/// (`blocks`, each made once, at its first `.block` literal), every one
/// compiled in `methodClass`. Answers the method and the block methods
/// made, by index. Verifies nothing: the image build verified the
/// assembler's output, the primitive verifies what this made.
func makeMethodObjects<H: MethodHeap>(_ top: MethodParts, blocks: [MethodParts], selector: Oop, methodClass: Oop,
                                       heap: inout H) throws(LoadError) -> (method: Oop, blocks: [Int: Oop]) {
    let om = heap.om
    var made: [Int: Oop] = [:]
    func readOnlyPinned(_ o: Oop) {
        if heap.pinsForGood { om.pinForGood(o) }
        om.setReadOnly(o, true)
    }
    func value(_ l: PartLiteral) throws(LoadError) -> Oop {
        switch l {
        case .object(let o):
            return o
        case .bytes(let cls, let b):
            let o = try heap.bytes(cls, b)
            readOnlyPinned(o)
            heap.keep(o)
            return o
        case .array(let elements):
            var values: [Oop] = []
            for e in elements {
                let v = try value(e)
                values.append(v)
            }
            let a = try heap.pointers(WellKnown.array, values.count)
            for (i, v) in values.enumerated() { om.store(a, i, v) }
            readOnlyPinned(a)
            heap.keep(a)
            return a
        case .block(let k):
            if let b = made[k] { return b }
            let b = try build(blocks[k], selector: heap.nilObject)
            made[k] = b
            return b
        case .pragma:
            return heap.nilObject  // made once the method exists
        }
    }
    func build(_ a: MethodParts, selector: Oop) throws(LoadError) -> Oop {
        var lits: [Oop] = []
        for l in a.literals { lits.append(try value(l)) }
        var pragmas: [Oop] = []
        for (k, l) in a.literals.enumerated() {
            guard case .pragma(let sel, let arguments) = l else { continue }
            var values: [Oop] = []
            for x in arguments { values.append(try value(x)) }
            let args = try heap.pointers(WellKnown.array, values.count)
            heap.keep(args)
            for (i, v) in values.enumerated() { om.store(args, i, v) }
            om.setReadOnly(args, true)
            let po = try heap.pointers(WellKnown.pragma, PragmaLayout.size)
            heap.keep(po)
            om.store(po, PragmaLayout.selector, sel)
            om.store(po, PragmaLayout.arguments, args)
            lits[k] = po
            pragmas.append(po)
        }
        let bytes = try heap.bytes(WellKnown.byteArray, a.bytecodes)
        readOnlyPinned(bytes)
        heap.keep(bytes)
        let litArray = try heap.pointers(WellKnown.array, lits.count)
        if heap.pinsForGood { om.pinForGood(litArray) }
        for (i, v) in lits.enumerated() { om.store(litArray, i, v) }
        om.setReadOnly(litArray, true)
        heap.keep(litArray)
        let meth = try heap.pointers(WellKnown.method, MethodLayout.size)
        if heap.pinsForGood { om.pinForGood(meth) }
        om.store(meth, MethodLayout.bytecodes, bytes)
        om.store(meth, MethodLayout.literals, litArray)
        om.store(meth, MethodLayout.argc, Oop(smallInteger: Int64(a.argc)))
        om.store(meth, MethodLayout.temps, Oop(smallInteger: Int64(a.temps)))
        om.store(meth, MethodLayout.maxStack, Oop(smallInteger: Int64(a.maxStack)))
        om.store(meth, MethodLayout.selector, selector)
        om.store(meth, MethodLayout.primitive, Oop(smallInteger: Int64(a.primitive)))
        om.store(meth, MethodLayout.flags, Oop(smallInteger: a.flags))
        om.store(meth, MethodLayout.methodClass, methodClass)
        om.store(meth, MethodLayout.copied, Oop(smallInteger: Int64(a.copied)))
        om.setReadOnly(meth, true)
        heap.keep(meth)
        for po in pragmas {
            om.store(po, PragmaLayout.method, meth)
            om.setReadOnly(po, true)
        }
        return meth
    }
    let m = try build(top, selector: selector)
    return (m, made)
}
