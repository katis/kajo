// Boot the object memory and install .kasm programs (SPEC-SHARED.md "Boot").

/// Host-side view of a VM: name tables used while loading. Not touched by the
/// interpreter, which only sees the raw `VMCore`.
public final class Image {
    public let vm: VMRef
    public var classNames: [String: UInt32] = [:]
    public var symbols: [String: Oop] = [:]
    let boot: WorkerRef

    /// A VM with nil/true/false, builtin classes and special selectors.
    public init(heapSize: Int = heapSize) {
        vm = VMCore.create(heapSize: heapSize)
        boot = Worker.create(id: -1, nilObj: 0)
        let v = vm, w = boot
        v.pointee.nilObj = alloc(v, w, ciNil, 0, false)
        v.pointee.trueObj = alloc(v, w, ciTrue, 0, false)
        v.pointee.falseObj = alloc(v, w, ciFalse, 0, false)
        v.pointee.roots.push(v.pointee.nilObj)
        v.pointee.roots.push(v.pointee.trueObj)
        v.pointee.roots.push(v.pointee.falseObj)
        for (i, name) in builtinClassNames.enumerated() {
            let idx = UInt32(i + 1)
            v.pointee.classTable[Int(idx)] = alloc(v, w, ciClass, classSlots, false)
            classNames[name] = idx
        }
        v.pointee.classCount = 1 + builtinClassNames.count
        let object = classAt(v, UInt64(ciObject))
        for idx in 1..<v.pointee.classCount {
            let c = classAt(v, UInt64(idx))
            setSlot(c, cSuper, UInt32(idx) == ciObject ? v.pointee.nilObj : object)
            setSlot(c, cInstSize, mkInt(0))
            setSlot(c, cIndex, mkInt(Int64(idx)))
        }
        for (i, s) in specialSelectors.enumerated() {
            v.pointee.special[i] = intern(s)
        }
    }

    @discardableResult
    public func intern(_ name: String) -> Oop {
        if let s = symbols[name] { return s }
        let id = Int64(symbols.count)
        let s = alloc(vm, boot, ciSymbol, 1, false)
        setSlot(s, 0, mkInt(id))
        symbols[name] = s
        vm.pointee.roots.push(s)
        return s
    }

    public func classIndex(_ name: String) throws -> UInt32 {
        guard let i = classNames[name] else { throw KasmError("unknown class \(name)") }
        return i
    }

    /// Install programs in order, then build method dictionaries.
    public func load(_ programs: [Program]) throws {
        let v = vm, w = boot
        var installed: [(UInt32, Oop, Oop)] = []
        for p in programs {
            var newClasses: [(Oop, ClassDef)] = []
            for cd in p.classes {
                let idx = UInt32(v.pointee.classCount)
                if classNames[cd.name] != nil { throw KasmError("duplicate class \(cd.name)") }
                let c = alloc(v, w, ciClass, classSlots, false)
                v.pointee.classTable[Int(idx)] = c
                v.pointee.classCount += 1
                classNames[cd.name] = idx
                setSlot(c, cInstSize, mkInt(Int64(cd.instSize)))
                setSlot(c, cIndex, mkInt(Int64(idx)))
                newClasses.append((c, cd))
            }
            for (c, cd) in newClasses {
                setSlot(c, cSuper, classAt(v, UInt64(try classIndex(cd.superclass))))
            }
            for m in p.methods {
                let cls = try classIndex(m.cls)
                let a = try assemble(m)
                let sel = intern(m.selector)
                for l in a.literals { if case .sym(let s) = l { intern(s) } }
                let bc = alloc(v, w, ciByteArray, a.bytecodes.count, true)
                a.bytecodes.withUnsafeBufferPointer { src in
                    bytesPtr(bc).update(from: src.baseAddress!, count: src.count)
                }
                let lits = alloc(v, w, ciArray, a.literals.count, false)
                for (i, l) in a.literals.enumerated() {
                    let val: Oop
                    switch l {
                    case .int(let n):
                        if !fitsInt(n) { throw KasmError("literal \(n) out of range") }
                        val = mkInt(n)
                    case .sym(let s): val = symbols[s]!
                    case .cls(let c): val = classAt(v, UInt64(try classIndex(c)))
                    case .nilLit: val = v.pointee.nilObj
                    case .trueLit: val = v.pointee.trueObj
                    case .falseLit: val = v.pointee.falseObj
                    }
                    setSlot(lits, i, val)
                }
                let meth = alloc(v, w, ciMethod, methodSlots, false)
                setSlot(meth, mBytecodes, bc)
                setSlot(meth, mLiterals, lits)
                setSlot(meth, mArgc, mkInt(Int64(a.argc)))
                setSlot(meth, mNTemps, mkInt(Int64(m.temps)))
                setSlot(meth, mMaxStack, mkInt(Int64(a.maxStack)))
                setSlot(meth, mSelector, sel)
                setSlot(meth, mPrim, mkInt(Int64(m.prim)))
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
                var i = Int(truncatingIfNeeded: sel >> 3) & (cap - 1)
                while true {
                    let k = slot(dict, 2 * i)
                    if k == v.pointee.nilObj || k == sel {
                        setSlot(dict, 2 * i, sel)
                        setSlot(dict, 2 * i + 1, meth)
                        break
                    }
                    i = (i + 1) & (cap - 1)
                }
            }
            setSlot(classAt(v, UInt64(idx)), cDict, dict)
        }
    }

    /// Boot, load sources, retire the boot TLAB.
    public static func fromSources(_ sources: [String], heapSize: Int = heapSize) throws -> Image {
        let progs = try sources.map(parseKasm)
        let img = Image(heapSize: heapSize)
        try img.load(progs)
        img.vm.pointee.heap.retire(&img.boot.pointee.tlab)
        return img
    }
}

/// Full method lookup along the superclass chain. Returns 0 if not found.
public func lookup(_ vm: VMRef, _ classIdx: UInt64, _ sel: Oop) -> Oop {
    let nilObj = vm.pointee.nilObj
    var c = classAt(vm, classIdx)
    while c != nilObj {
        let dict = slot(c, cDict)
        if dict != nilObj {
            let cap = hdrSlots(header(dict)) / 2
            var i = Int(truncatingIfNeeded: sel >> 3) & (cap - 1)
            while true {
                let k = slot(dict, 2 * i)
                if k == sel { return slot(dict, 2 * i + 1) }
                if k == nilObj { break }
                i = (i + 1) & (cap - 1)
            }
        }
        c = slot(c, cSuper)
    }
    return 0
}
