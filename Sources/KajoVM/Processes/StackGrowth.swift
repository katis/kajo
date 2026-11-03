import Darwin

// Stack growth by copying (module 8; kernel.md question 4). A Process's
// stack is one malloc'ed segment. When the next frame does not fit, a
// segment twice the size is allocated, the words [0, sp] copied, the old
// one freed, and the interpreter's live registers recomputed from the
// saved ones. Frame links, saved pcs and Context frame numbers are indices
// and offsets (module 2's rule), so nothing in the stack or the heap
// changes. Segment chaining is not built.
//
// Who holds a pointer into a stack: the worker running it (its registers,
// `stackBase`, `stackEnd`; recomputed here) and the record (`base`,
// `end`; updated under the scheduler lock). Stoppers and young collectors
// read a stack only while its Process is parked or its worker is stopped,
// so a running Process, the only kind that grows, is never being read by
// another thread when its segment changes.

/// Grow the running Process's stack to fit `needed` more words above the
/// saved sp. The registers are saved. False when there is no Process (module
/// 2's standalone interpreter keeps its fixed stack) or the maximum is
/// reached.
func growStack(_ s: StatePointer, needed: Int) -> Bool {
    let w = unsafe workerOf(s)
    guard let vm = unsafe w.pointee.vm, unsafe w.pointee.record >= 0 else { return false }
    let old = unsafe s.pointee.stackBase
    let oldWords = unsafe s.pointee.stackEnd - old
    let sp = unsafe s.pointee.regs.sp
    var words = oldWords
    while words < sp + needed + 64 { words *= 2 }
    guard unsafe words <= vm.pointee.config.maxStackWords else { return false }
    let new = UnsafeMutablePointer<UInt64>.allocate(capacity: words)
    unsafe new.update(from: old, count: sp + 1)
    let r = unsafe records(vm, w.pointee.record)
    unsafe schedLock(vm)
    unsafe r.pointee.base = new
    unsafe r.pointee.end = new + words
    unsafe schedUnlock(vm)
    unsafe s.pointee.stackBase = new
    unsafe s.pointee.stackEnd = new + words
    unsafe old.deallocate()
    unsafe s.pointee.stackGrowths &+= 1
    unsafe vm.count(.stackGrowths)
    return true
}
