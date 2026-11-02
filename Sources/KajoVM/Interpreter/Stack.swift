import Darwin

/// A stack of tagged words that frames live on. Grows up; word 0 holds nil
/// and every word in [0, sp] is a valid oop, so the collector scans it
/// uniformly. Module 2 runs one; module 3 gives one to each Process, so the
/// interpreter takes a stack as an argument and never assumes there is one.
///
/// The stack is malloc'ed, not in the heap: no collection moves it, and
/// nothing inside it is a raw address (frame links are word indices, saved
/// pcs are bytecode offsets), so module 3 may move or grow it.
@safe struct Stack: @unchecked Sendable {
    let base: UnsafeMutablePointer<UInt64>
    let words: Int

    /// At least 64 words: the bottom frame needs its header and some room.
    init(words: Int = 1 << 16) {
        precondition(words >= 64, "a stack holds at least 64 words")
        self.words = words
        unsafe base = UnsafeMutablePointer<UInt64>.allocate(capacity: words)
        unsafe base.initialize(repeating: 1, count: words)  // SmallInteger 0
    }

    func destroy() { unsafe base.deallocate() }

    subscript(i: Int) -> Oop {
        precondition(i >= 0 && i < words)
        return unsafe Oop(raw: base[i])
    }
}

/// A frame on a stack, `fp` at the receiver (SPEC-SHARED "Frames"):
///
///     fp[0]                 receiver           (pushed by the caller)
///     fp[1 ... argc]        arguments          (pushed by the caller)
///     fp[1 + argc ...]      temps, nil
///     hdr[0]                method             hdr = fp + 1 + argc + temps
///     hdr[1]                caller pc          SmallInteger: offset into the caller's bytecodes
///     hdr[2]                caller fp          SmallInteger: word index in the stack, 0 = the host
///     hdr[3]                caller hdr         SmallInteger: word index in the stack
///     hdr[4 ...]            operand stack, at most the method's maxStack words
///
/// The three links are SmallIntegers, so the collector scans them as
/// integers. They are offsets and indices, not addresses: the bytecodes
/// they point into move under compaction, and the stack may move in module 3.
enum Frame {
    static let method = 0
    static let callerPC = 1
    static let callerFP = 2
    static let callerHdr = 3
    static let headerWords = 4

    /// The caller fp of a frame the host entered.
    static let hostFP = Oop(smallInteger: 0).raw
}
