import Darwin

/// The block heap: one reservation, mapped twice (see `VirtualMemory`), cut
/// into 32 KiB blocks. Bodies never span blocks.
///
/// Per block: bytes used and whether it is in use. A block held by an
/// allocation context has a stale `used` until the context is retired;
/// every reader of `used` runs with the contexts retired.
@safe struct BlockHeap {
    static let blockBytes = 32 * 1024
    static let blockShift: UInt64 = 15

    let base: UnsafeMutableRawPointer
    let bytes: Int
    let blockCount: Int
    let memoryEntry: mach_port_t
    let used: UnsafeMutablePointer<UInt32>
    let inUse: UnsafeMutablePointer<Bool>

    init(bytes: Int) throws(ObjectMemoryError) {
        let (p, entry) = try unsafe VirtualMemory.reserveTwice(bytes)
        unsafe base = p
        self.bytes = bytes
        blockCount = bytes / BlockHeap.blockBytes
        memoryEntry = entry
        unsafe used = .allocate(capacity: blockCount)
        unsafe used.initialize(repeating: 0, count: blockCount)
        unsafe inUse = .allocate(capacity: blockCount)
        unsafe inUse.initialize(repeating: false, count: blockCount)
    }

    func release() {
        unsafe VirtualMemory.releaseTwice(base, bytes, memoryEntry)
        unsafe used.deallocate()
        unsafe inUse.deallocate()
    }

    @inline(__always)
    static func start(ofBlock b: Int) -> UInt64 { UInt64(b) &<< blockShift }

    @inline(__always)
    static func block(ofOffset off: UInt64) -> Int { Int(truncatingIfNeeded: off &>> blockShift) }

    func usedBytes(_ b: Int) -> UInt64 { UInt64(unsafe used[b]) }
    func setUsed(_ b: Int, _ v: UInt64) { unsafe used[b] = UInt32(v) }
    func isInUse(_ b: Int) -> Bool { unsafe inUse[b] }
    func setInUse(_ b: Int, _ v: Bool) { unsafe inUse[b] = v }

    @inline(__always)
    func word(atOffset off: UInt64) -> UInt64 {
        unsafe base.load(fromByteOffset: Int(truncatingIfNeeded: off), as: UInt64.self)
    }

    @inline(__always)
    func setWord(atOffset off: UInt64, _ v: UInt64) {
        unsafe base.storeBytes(of: v, toByteOffset: Int(truncatingIfNeeded: off), as: UInt64.self)
    }

    /// The word at `off` read through the alias mapping.
    func aliasLoadWord(atOffset off: UInt64) -> UInt64 {
        word(atOffset: off &+ VirtualMemory.aliasDistance)
    }

    func aliasStoreWord(atOffset off: UInt64, _ v: UInt64) {
        setWord(atOffset: off &+ VirtualMemory.aliasDistance, v)
    }
}

/// A body's first word: the back reference to its entry and its own size,
/// so the heap is walkable without the table (experiments/object-
/// representation SPEC, B).
///
///     bits  0..31  entry index (0: a filler, never live)
///     bits 32..63  body size in words, this word included
enum BackRef {
    @inline(__always)
    static func make(entryIndex: UInt64, words: UInt64) -> UInt64 { entryIndex | words &<< 32 }
    @inline(__always)
    static func entryIndex(_ w: UInt64) -> UInt64 { w & 0xFFFF_FFFF }
    @inline(__always)
    static func words(_ w: UInt64) -> UInt64 { w &>> 32 }
}
