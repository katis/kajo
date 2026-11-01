// Derived pointers into movable bodies (SPEC.md "Compaction"): frames keep
// return pcs as raw addresses inside the caller's bytecode ByteArray, and a
// parked worker's pc points into its current method's bytecodes. A moving
// collector turns them into offsets before it moves anything and back after.
// Representation-neutral: every variant with a moving GC needs this.

let hostFP: UInt64 = 1 // mkInt(0)

@inline(__always)
private func bytecodeStart(_ om: OM, _ method: Oop) -> UInt {
    UInt(bitPattern: om.bytesPtr(om.slot(method, mBytecodes)))
}

/// Walk every frame of every worker inside the interpreter. `body` gets the
/// pc word's location and the method it points into.
private func forEachPc(_ vm: VMRef, _ body: (UnsafeMutablePointer<UInt64>?, UnsafeMutablePointer<Worker>, Oop) -> Void) {
    guard let ws = vm.pointee.workers else { return }
    for i in 0..<vm.pointee.workerCount {
        let w = ws[i]
        guard var h = w.pointee.hdr else { continue }
        body(nil, w, h[0]) // the worker's own pc
        while h[2] != hostFP {
            let caller = untagPtr(h[3], UInt64.self)
            body(h + 1, w, caller[0])
            h = caller
        }
    }
}

/// Before moving: pcs become offsets from their method's bytecode start.
func pcsToOffsets(_ vm: VMRef) -> Int {
    let om = vm.pointee.om
    var n = 0
    forEachPc(vm) { slot, w, m in
        let start = bytecodeStart(om, m)
        if let s = slot { s.pointee = mkInt(Int64(bitPattern: UInt64(bitPattern: intVal(s.pointee)) &- UInt64(start))) }
        else { w.pointee.pc = w.pointee.pc &- start }
        n += 1
    }
    return n
}

/// After moving (methods' new locations are in the frames): offsets back to
/// addresses. Every worker re-derives its registers when it resumes.
func pcsFromOffsets(_ vm: VMRef) {
    let om = vm.pointee.om
    forEachPc(vm) { slot, w, m in
        let start = bytecodeStart(om, m)
        if let s = slot { s.pointee = mkInt(Int64(bitPattern: UInt64(start)) &+ intVal(s.pointee)) }
        else { w.pointee.pc = w.pointee.pc &+ start }
    }
    if let ws = vm.pointee.workers {
        for i in 0..<vm.pointee.workerCount { ws[i].pointee.moved = true }
    }
}
