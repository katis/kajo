import Synchronization

// Read-only objects (ADR 0009 section 9). Header bit 50; every store path
// checks it: `store_ivar` and `store_tv_slot` in the dispatch loop (the
// receiver's header is loaded for the slot check anyway, so the bit costs
// a wider mask, not an instruction), the store primitives (`at:put:`,
// `instVarAt:put:`, `replaceFrom:to:with:startingAt:`, `globalAt:put:`,
// Context `tempAt:put:`, the UTF-8 encoder's buffer), `become:` and
// `reshape`. A refused store in a bytecode sends `attemptToModify:at:value:`
// to the object; a refused primitive store sends it in place of the
// primitive's answer (`primitiveSend`). The collectors never read it.

extension ObjectMemory {
    @inline(__always)
    func isReadOnly(_ o: Oop) -> Bool { o.isImmediate || headerWord(o.raw) & Header.readOnlyBit != 0 }

    /// Set or clear the bit with one atomic or/and on the header word: a
    /// relaxed read-modify-write, so a concurrent young collector's claim
    /// (which compare-and-swaps the young-only bits and retries when the
    /// word changed) loses neither its bits nor this one.
    func setReadOnly(_ o: Oop, _ on: Bool) {
        let h = unsafe headerAtomic(o.raw)
        if on { unsafe h.pointee.bitwiseOr(Header.readOnlyBit, ordering: .relaxed) }
        else { unsafe h.pointee.bitwiseAnd(~Header.readOnlyBit, ordering: .relaxed) }
    }

    /// The class's instances are sealed (module 2's structural classes,
    /// Process, Semaphore, BlockClosure, Context, and every metaclass).
    @inline(__always)
    func isSealed(_ classIndex: UInt64) -> Bool { classFormat(classIndex).isSealed }

    /// `o` is a class or a metaclass.
    func isBehavior(_ o: Oop) -> Bool {
        o.isObject && classFormat(header(o).classIndex).instancesAreBehaviors
    }
}
