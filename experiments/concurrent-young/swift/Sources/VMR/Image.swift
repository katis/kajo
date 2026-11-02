// Boot the object memory and install .kasm programs (SPEC-SHARED.md "Boot").
// Copied from ../ui-thread-scheduling. The boot worker has no nursery, so the
// image is allocated old and its stores need no barrier (SPEC.md "Write
// barrier").

import Kasm

/// Host-side view of a VM: name tables used while loading. Not touched by the
/// interpreter, which only sees the raw `VMCore`.
public final class Image {
    public let vm: VMRef
    public var classNames: [String: UInt32] = [:]
    /// name -> index into vm.roots (symbols are roots, so a moving GC keeps this valid)
    var symbolIndex: [String: Int] = [:]
    let boot: WorkerRef

    /// A VM with nil/true/false, builtin classes and special selectors.
    /// `nurseryBytes`: per-worker nursery, 0 = non-generational. Forced to 0
    /// in a `NO_BARRIER` build.
    public init(heapSize: Int, nurseryBytes: Int) {
        #if NO_BARRIER
        let nb = 0
        #else
        let nb = nurseryBytes
        #endif
        vm = VMCore.create(heapSize: heapSize, nurseryBytes: nb)
        boot = Worker.create(id: -1, nilObj: 0)
        let v = vm, w = boot
        let om = v.pointee.om
        v.pointee.nilObj = alloc(v, w, ciNil, 0, false)
        v.pointee.trueObj = alloc(v, w, ciTrue, 0, false)
        v.pointee.falseObj = alloc(v, w, ciFalse, 0, false)
        v.pointee.roots.push(v.pointee.nilObj)
        v.pointee.roots.push(v.pointee.trueObj)
        v.pointee.roots.push(v.pointee.falseObj)
        for o in [v.pointee.nilObj, v.pointee.trueObj, v.pointee.falseObj] { pinForGood(v, o) }
        for i in 0..<globalCount { v.pointee.globals[i] = v.pointee.nilObj }
        for (i, name) in builtinClassNames.enumerated() {
            let idx = UInt32(i + 1)
            v.pointee.classTable[Int(idx)] = alloc(v, w, ciClass, classSlots, false)
            pinForGood(v, v.pointee.classTable[Int(idx)])
            classNames[name] = idx
        }
        v.pointee.classCount = 1 + builtinClassNames.count
        let object = classAt(v, UInt64(ciObject))
        for idx in 1..<v.pointee.classCount {
            let c = classAt(v, UInt64(idx))
            om.setSlotRaw(c, cSuper, UInt32(idx) == ciObject ? v.pointee.nilObj : object)
            let inst = UInt32(idx) == ciProcess ? processSlots : UInt32(idx) == ciSemaphore ? semaphoreSlots : 0
            om.setSlotRaw(c, cInstSize, mkInt(Int64(inst)))
            om.setSlotRaw(c, cIndex, mkInt(Int64(idx)))
        }
        for (i, s) in specialSelectors.enumerated() {
            v.pointee.special[i] = intern(s)
        }
    }

    public func symbol(_ name: String) -> Oop? {
        guard let i = symbolIndex[name] else { return nil }
        return vm.pointee.roots.ptr[i]
    }

    @discardableResult
    public func intern(_ name: String) -> Oop {
        if let s = symbol(name) { return s }
        let id = Int64(symbolIndex.count)
        let s = alloc(vm, boot, ciSymbol, 1, false)
        pinForGood(vm, s)
        vm.pointee.om.setSlotRaw(s, 0, mkInt(id))
        symbolIndex[name] = vm.pointee.roots.count
        vm.pointee.roots.push(s)
        vm.pointee.symbolNames.append(name)
        return s
    }

    public func classIndex(_ name: String) throws -> UInt32 {
        guard let i = classNames[name] else { throw KasmError("unknown class \(name)") }
        return i
    }

    /// Install programs in order, then build method dictionaries.
    public func load(_ programs: [Program]) throws {
        let v = vm, w = boot
        let om = v.pointee.om
        var installed: [(UInt32, Oop, Oop)] = []
        for p in programs {
            var newClasses: [(Oop, ClassDef)] = []
            for cd in p.classes {
                let idx = UInt32(v.pointee.classCount)
                if classNames[cd.name] != nil { throw KasmError("duplicate class \(cd.name)") }
                let c = alloc(v, w, ciClass, classSlots, false)
                pinForGood(v, c)
                v.pointee.classTable[Int(idx)] = c
                v.pointee.classCount += 1
                classNames[cd.name] = idx
                om.setSlotRaw(c, cInstSize, mkInt(Int64(cd.instSize)))
                om.setSlotRaw(c, cIndex, mkInt(Int64(idx)))
                newClasses.append((c, cd))
            }
            for (c, cd) in newClasses {
                om.setSlotRaw(c, cSuper, classAt(v, UInt64(try classIndex(cd.superclass))))
            }
            for m in p.methods {
                let cls = try classIndex(m.cls)
                let a = try assemble(m)
                let sel = intern(m.selector)
                for l in a.literals { if case .sym(let s) = l { intern(s) } }
                let bc = alloc(v, w, ciByteArray, a.bytecodes.count, true)
                a.bytecodes.withUnsafeBufferPointer { src in
                    om.bytesPtr(bc).update(from: src.baseAddress!, count: src.count) // RAW (host, no safepoint)
                }
                let lits = alloc(v, w, ciArray, a.literals.count, false)
                for (i, l) in a.literals.enumerated() {
                    let val: Oop
                    switch l {
                    case .int(let n):
                        if !fitsInt(n) { throw KasmError("literal \(n) out of range") }
                        val = mkInt(n)
                    case .sym(let s): val = symbol(s)!
                    case .cls(let c): val = classAt(v, UInt64(try classIndex(c)))
                    case .nilLit: val = v.pointee.nilObj
                    case .trueLit: val = v.pointee.trueObj
                    case .falseLit: val = v.pointee.falseObj
                    }
                    om.setSlotRaw(lits, i, val)
                }
                let meth = alloc(v, w, ciMethod, methodSlots, false)
                // The interpreter keeps raw pointers into bytecodes and
                // literal frames (SPEC.md "Pins and hazards").
                for o in [bc, lits, meth] { pinForGood(v, o) }
                om.setSlotRaw(meth, mBytecodes, bc)
                om.setSlotRaw(meth, mLiterals, lits)
                om.setSlotRaw(meth, mArgc, mkInt(Int64(a.argc)))
                om.setSlotRaw(meth, mNTemps, mkInt(Int64(m.temps)))
                om.setSlotRaw(meth, mMaxStack, mkInt(Int64(a.maxStack)))
                om.setSlotRaw(meth, mSelector, sel)
                om.setSlotRaw(meth, mPrim, mkInt(Int64(m.prim)))
                installed.append((cls, sel, meth))
            }
        }
        for idx in 1..<UInt32(v.pointee.classCount) {
            let ms = installed.filter { $0.0 == idx }
            if ms.isEmpty { continue }
            var cap = 8
            while cap < 2 * ms.count { cap *= 2 }
            let dict = alloc(v, w, ciMethodDict, 2 * cap, false)
            for (_, sel, meth) in ms {
                var i = selectorHash(om, sel) & (cap - 1)
                while true {
                    let k = om.slot(dict, 2 * i)
                    if k == v.pointee.nilObj || k == sel {
                        om.setSlotRaw(dict, 2 * i, sel)
                        om.setSlotRaw(dict, 2 * i + 1, meth)
                        break
                    }
                    i = (i + 1) & (cap - 1)
                }
            }
            om.setSlotRaw(classAt(v, UInt64(idx)), cDict, dict)
        }
    }

    /// Boot, load sources, retire the boot allocation buffers.
    public static func fromSources(_ sources: [String], heapSize: Int = 64 << 20,
                                   nurseryBytes: Int = defaultNurseryBytes()) throws -> Image {
        let progs = try sources.map(parseKasm)
        let img = Image(heapSize: heapSize, nurseryBytes: nurseryBytes)
        try img.load(progs)
        retireBoot(img.vm, img.boot)
        return img
    }
}

/// Image build, single-threaded: never relocate `o` (SPEC.md "Pin rule").
func pinForGood(_ vm: VMRef, _ o: Oop) {
    let om = vm.pointee.om
    om.setHeader(o, om.header(o) | pinBit)
}

/// Method-dictionary hash: the symbol's id, not its address. An address hash
/// would be invalidated by every moving collection in A/C (found by the
/// compaction test); B's oops are stable but uses the same hash for fairness.
@inline(__always) func selectorHash(_ om: OM, _ sel: Oop) -> Int {
    Int(truncatingIfNeeded: intVal(om.slot(sel, 0)))
}

/// Full method lookup along the superclass chain. Returns 0 if not found.
public func lookup(_ vm: VMRef, _ classIdx: UInt64, _ sel: Oop) -> Oop {
    let om = vm.pointee.om
    let nilObj = vm.pointee.nilObj
    var c = classAt(vm, classIdx)
    while c != nilObj {
        let dict = om.slot(c, cDict)
        if dict != nilObj {
            let cap = hdrSlots(om.header(dict)) / 2
            var i = selectorHash(om, sel) & (cap - 1)
            while true {
                let k = om.slot(dict, 2 * i)
                if k == sel { return om.slot(dict, 2 * i + 1) }
                if k == nilObj { break }
                i = (i + 1) & (cap - 1)
            }
        }
        c = om.slot(c, cSuper)
    }
    return 0
}

/// `KAJO_NURSERY_KB` (0 = non-generational), else 4 MiB.
public func defaultNurseryBytes() -> Int {
    if let kb = envInt("KAJO_NURSERY_KB") { return kb * 1024 }
    return 4 << 20
}
