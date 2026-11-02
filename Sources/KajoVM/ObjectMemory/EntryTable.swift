/// The entry table: 16-byte entries, the oop of an object is the byte
/// offset of its entry (ADR 0003).
///
///     word 0  state word
///     word 1  header word (see `Header`); 0 in a free entry
///
/// State word:
///
///     used        body offset from the heap base, < 2^32, a multiple of 8
///     RELOCATING  body offset + 2^32 (module 6; reads go through the heap
///                 alias). Reserved: never present in module 1.
///     free        bit 63 set; bits 0..62 the oop of the next free entry in
///                 the same list, 0 at the end
///
/// Entry 0 is reserved and never used, so no reference is 0 and a filler
/// body's back reference (index 0) names no object. Entries above the high
/// water mark were never used and are zero.
enum EntryState {
    static let freeBit: UInt64 = 1 << 63
    static let relocatingBit: UInt64 = VirtualMemory.aliasDistance
    static let nextMask: UInt64 = ~freeBit

    @inline(__always) static func isFree(_ s: UInt64) -> Bool { s & freeBit != 0 }
    @inline(__always) static func free(next: UInt64) -> UInt64 { freeBit | next }
}
