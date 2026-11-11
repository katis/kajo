import CommonCrypto

// AOT 1 (docs/modules/aot.md): what the generator and the binding share.
//
// - The layout constants the generated C is compiled against: offsets of
//   the worker's fields the native code reads (computed here from the Swift
//   declarations, never written by hand), the header and tag masks, the
//   well-known class indices, the frame layout, the cache geometry. Their
//   hash is the module's layout hash: a module built against another build
//   of the VM is refused whole at bind.
// - The content hash of a method (rule 10): everything the generator folds
//   into a method's code. Both sides compute it with `nativeMethodHash`.
// - The method facts the generator emits from (`NativeMethodInfo`): the
//   plain instructions with the verifier's traced depth before each.

/// The interface's version: the descriptor's and the vtable's shape. A
/// module of another version is refused whole.
package let nativeFormatVersion: UInt64 = 1

/// A native return marker is a SmallInteger `nativeMarkerBase + index` in a
/// frame's context word (or a Context's marker field): resume the caller at
/// the module's resume table entry `index`. 1 to 3 are `FrameMarker`'s.
package let nativeMarkerBase = 4

/// The descriptor's magic word: "KAJONATV" little-endian.
package let nativeModuleMagic: UInt64 = 0x5654_414E_4F4A_414B

package enum NativeLayout {
    /// Every constant the generated prelude defines, in a fixed order.
    package static let constants: [(name: String, value: UInt64)] = {
        func off(_ k: PartialKeyPath<Worker>) -> UInt64 { UInt64(unsafe MemoryLayout<Worker>.offset(of: k)!) }
        let nativeAt = unsafe off(\Worker.native)
        let outAt = nativeAt + UInt64(unsafe MemoryLayout<NativeWorkerState>.offset(of: \NativeWorkerState.out)!)
        let countersAt = nativeAt + UInt64(unsafe MemoryLayout<NativeWorkerState>.offset(of: \NativeWorkerState.counters)!)
        return unsafe [
            ("FORMAT_VERSION", nativeFormatVersion),
            ("W_COUNTDOWN", off(\Worker.interp.countdown)),
            ("W_FLAG", off(\Worker.interp.safepointFlag)),
            ("W_SENDS", off(\Worker.interp.counters.sends)),
            ("W_CACHE", off(\Worker.interp.cache)),
            ("W_STACKBASE", off(\Worker.interp.stackBase)),
            ("W_STACKEND", off(\Worker.interp.stackEnd)),
            ("W_TABLE", off(\Worker.interp.om.table)),
            ("W_HEAP", off(\Worker.interp.om.heapBase)),
            ("W_NTAB", nativeAt + UInt64(unsafe MemoryLayout<NativeWorkerState>.offset(of: \NativeWorkerState.table)!)),
            ("W_VT", nativeAt + UInt64(unsafe MemoryLayout<NativeWorkerState>.offset(of: \NativeWorkerState.vt)!)),
            ("W_OUT_FP", outAt + UInt64(unsafe MemoryLayout<NativeOut>.offset(of: \NativeOut.fp)!)),
            ("W_OUT_HDR", outAt + UInt64(unsafe MemoryLayout<NativeOut>.offset(of: \NativeOut.hdr)!)),
            ("W_OUT_V", outAt + UInt64(unsafe MemoryLayout<NativeOut>.offset(of: \NativeOut.v)!)),
            ("W_OUT_PC", outAt + UInt64(unsafe MemoryLayout<NativeOut>.offset(of: \NativeOut.pc)!)),
            ("W_NSENDS", countersAt + UInt64(MemoryLayout<NativeCounters>.offset(of: \NativeCounters.nativeSends)!)),
            ("W_NRETURNS", countersAt + UInt64(MemoryLayout<NativeCounters>.offset(of: \NativeCounters.nativeReturns)!)),
            ("CACHE_ENTRIES", UInt64(InterpreterState.cacheEntries)),
            ("CACHE_STRIDE", UInt64(MemoryLayout<CacheEntry>.stride)),
            ("CACHE_CLS", UInt64(MemoryLayout<CacheEntry>.offset(of: \CacheEntry.classIndex)!)),
            ("CACHE_SEL", UInt64(MemoryLayout<CacheEntry>.offset(of: \CacheEntry.selector)!)),
            ("CACHE_METHOD", UInt64(MemoryLayout<CacheEntry>.offset(of: \CacheEntry.method)!)),
            ("HDR_CLASS_MASK", Header.classMask),
            ("HDR_COUNT_MASK", Header.countMask),
            ("HDR_COUNT_SHIFT", Header.countShift),
            ("HDR_BYTES_BIT", Header.bytesBit),
            ("HDR_READONLY_BIT", Header.readOnlyBit),
            ("HDR_YOUNG_BIT", Header.youngBit),
            ("HDR_YOUNG_NURSERY_MASK", Header.youngNurseryMask),
            ("ENTRY_RELOCATING_BIT", EntryState.relocatingBit),
            ("SITE_STORE_IVAR", UInt64(BarrierSite.storeIvar.rawValue)),
            ("SITE_STORE_TEMP_VECTOR", UInt64(BarrierSite.storeTempVector.rawValue)),
            ("OOP_TAG_MASK", Oop.objectTagMask),
            ("CLS_SMALLINTEGER", WellKnown.smallInteger),
            ("CLS_SMALLFLOAT", WellKnown.smallFloat),
            ("CLS_CHARACTER", WellKnown.character),
            ("CLS_ARRAY", WellKnown.array),
            ("CLS_BLOCKCLOSURE", WellKnown.blockClosure),
            ("CLOSURE_METHOD", UInt64(ClosureLayout.method)),
            ("CLOSURE_RECEIVER", UInt64(ClosureLayout.receiver)),
            ("CLOSURE_SIZE", UInt64(ClosureLayout.size)),
            ("W_CLOSURE_ACTIVATIONS", off(\Worker.interp.counters.closureActivations)),
            ("FRAME_METHOD", UInt64(Frame.method)),
            ("FRAME_CALLER_PC", UInt64(Frame.callerPC)),
            ("FRAME_CALLER_FP", UInt64(Frame.callerFP)),
            ("FRAME_CALLER_HDR", UInt64(Frame.callerHdr)),
            ("FRAME_CONTEXT", UInt64(Frame.context)),
            ("FRAME_HEADER_WORDS", UInt64(Frame.headerWords)),
            ("EMPTY_CONTEXT", Frame.emptyContext),
            ("MARKER_BASE", UInt64(nativeMarkerBase)),
            ("NTAB_STRIDE", 16),
            ("SPECIAL_SELECTORS", UInt64(specialSelectorNames.count)),
        ]
    }()

    /// The layout hash: SHA-256 of the constants' names and values.
    package static let hash: (UInt64, UInt64) = {
        var bytes: [UInt8] = []
        for (n, v) in constants {
            bytes += Array(n.utf8) + [0]
            for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) }
        }
        return nativeDigest(bytes)
    }()
}

/// SHA-256 of `bytes`, its first 128 bits as two words.
package func nativeDigest(_ bytes: [UInt8]) -> (UInt64, UInt64) {
    var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    bytes.withUnsafeBufferPointer { b in
        out.withUnsafeMutableBufferPointer { o in
            _ = unsafe CC_SHA256(b.baseAddress, CC_LONG(b.count), o.baseAddress)
        }
    }
    func word(_ at: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(out[at + $1]) << (8 * UInt64($1)) } }
    return (word(0), word(8))
}

/// One plain instruction of a method as the generator reads it.
package struct NativeInstruction: Sendable {
    package let op: Opcode
    package let offset: Int
    /// Bytes, an `ext` prefix included.
    package let length: Int
    package let a: Int
    package let b: Int
    /// Written with the `ext` prefix (the first operand past a byte).
    package let extended: Bool
    /// The verifier's traced operand depth before it, -1 when no path
    /// reaches it.
    package let depth: Int
}

/// A CompiledMethod (or block method) as the generator reads it.
package struct NativeMethodInfo: Sendable {
    package let oop: UInt64
    package let name: String
    package let argc: Int
    package let temps: Int
    package let maxStack: Int
    package let flags: Int64
    package let primitive: Int
    package let copied: Int
    package let codeLength: Int
    package let instructions: [NativeInstruction]
    /// The literal frame's raw words.
    package let literals: [UInt64]
    package let hash: (UInt64, UInt64)
    package var isBlock: Bool { flags & MethodFlags.block != 0 }
}

/// The plain bytecodes of a method (fused first bytes put back), decoded.
func plainInstructions(_ bytes: [UInt8]) -> (plain: [UInt8], instructions: [DecodedInstruction])? {
    var plain = bytes
    var out: [DecodedInstruction] = []
    var off = 0
    while off < plain.count {
        guard let d = decodeInstruction(plain, at: off) else { return nil }
        if d.fused != nil { plain[off] = d.op.rawValue }
        out.append(d)
        off += d.length
    }
    return (plain, out)
}

/// Rule 10's hash of a method: its plain bytecodes, argument, temp and
/// copied counts, stack maximum, flags, primitive, literal count, and every
/// literal the generated code folds (`push_lit` values and `send`
/// selectors, by index). nil when the bytecodes do not decode (never for a
/// verified method).
func nativeMethodHash(_ om: ObjectMemory, _ method: Oop) -> (UInt64, UInt64)? {
    let bc = om.load(method, MethodLayout.bytecodes), lits = om.load(method, MethodLayout.literals)
    guard let (plain, instrs) = plainInstructions(om.bytes(of: bc)) else { return nil }
    let n = Int(om.count(of: lits))
    var folded: [(Int, UInt64)] = []
    for i in instrs where i.op == .pushLiteral || i.op == .send {
        guard i.a < n else { return nil }
        folded.append((i.a, om.load(lits, i.a).raw))
    }
    func int(_ i: Int) -> UInt64 { om.load(method, i).raw }
    return nativeContentHash(plain: plain, header: [int(MethodLayout.argc), int(MethodLayout.temps), int(MethodLayout.maxStack),
                                                    int(MethodLayout.flags), int(MethodLayout.primitive), int(MethodLayout.copied)],
                             literalCount: n, folded: folded)
}

func nativeContentHash(plain: [UInt8], header: [UInt64], literalCount: Int, folded: [(Int, UInt64)]) -> (UInt64, UInt64) {
    var bytes: [UInt8] = []
    func put(_ v: UInt64) { for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
    put(nativeFormatVersion)
    put(UInt64(plain.count))
    bytes += plain
    for h in header { put(h) }
    put(UInt64(literalCount))
    put(UInt64(folded.count))
    for (i, v) in folded {
        put(UInt64(i))
        put(v)
    }
    return nativeDigest(bytes)
}

extension Image {
    /// Every CompiledMethod and block method of the image, with what the
    /// generator needs (AOT 1). The image as loaded: nothing young, no VM.
    /// Methods whose verifier does not trace are left out (none in a loaded
    /// image: the loader verified each).
    package func nativeMethodInfos() -> [NativeMethodInfo] {
        var methods: [Oop] = []
        var classes = [Bool](repeating: false, count: Int(WellKnown.method) + 1)
        classes[Int(WellKnown.method)] = true
        om.walkInstances(of: classes) { methods.append($0); return true }
        var out: [NativeMethodInfo] = []
        out.reserveCapacity(methods.count)
        for m in methods {
            guard let info = nativeMethodInfo(m) else { continue }
            out.append(info)
        }
        return out
    }

    func nativeMethodInfo(_ m: Oop) -> NativeMethodInfo? {
        guard let hash = nativeMethodHash(om, m) else { return nil }
        let mc = om.load(m, MethodLayout.methodClass)
        let ci = om.load(mc, ClassLayout.classIndex)
        guard ci.isSmallInteger else { return nil }
        var traced: VerifiedCode? = nil
        guard verifyHeapMethod(om, m, classIndex: UInt64(ci.smallIntegerValue), nilObject: nilObject, traced: { traced = $0 }) == nil,
              let v = traced, v.depths.count == v.instructions.count else { return nil }
        func int(_ i: Int) -> Int { Int(om.load(m, i).smallIntegerValue) }
        let lits = om.load(m, MethodLayout.literals)
        let literals = (0..<Int(om.count(of: lits))).map { om.load(lits, $0).raw }
        let bytes = om.bytes(of: om.load(m, MethodLayout.bytecodes))
        var instrs: [NativeInstruction] = []
        for (k, d) in v.instructions.enumerated() {
            instrs.append(NativeInstruction(op: d.op, offset: d.offset, length: d.length, a: d.a, b: d.b,
                                            extended: d.length > d.op.length, depth: v.depths[k]))
        }
        return NativeMethodInfo(oop: m.raw, name: methodName(m) ?? "a block of \(className(UInt64(ci.smallIntegerValue)) ?? "?")",
                                argc: int(MethodLayout.argc), temps: int(MethodLayout.temps), maxStack: int(MethodLayout.maxStack),
                                flags: Int64(int(MethodLayout.flags)), primitive: int(MethodLayout.primitive),
                                copied: int(MethodLayout.copied), codeLength: bytes.count, instructions: instrs,
                                literals: literals, hash: hash)
    }
}
