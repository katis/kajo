import Darwin

/// The block heap: one reservation, mapped twice (see `VirtualMemory`), cut
/// into 32 KiB blocks. An ordinary body never spans blocks; a large object's
/// body (module 10) is a run of contiguous blocks it owns alone.
///
/// Per block: bytes used, whether it is in use, and its kind (the side
/// table of module 10: ordinary, the head of a run, a continuation of a
/// run). A block held by an allocation context has a stale `used` until the
/// context is retired; every reader of `used` runs with the contexts
/// retired. A run's head has `used` equal to the large body's bytes (more
/// than a block) and each continuation `used` 0, so a reader that walks a
/// block from its start to its `used` walks the run's one body.
@safe struct BlockHeap {
    static let blockBytes = 32 * 1024
    static let blockShift: UInt64 = 15

    let base: UnsafeMutableRawPointer
    /// The block range: offsets `[0, bytes)`.
    let bytes: Int
    /// Module 7: bytes mapped twice after the block range, for the nursery
    /// region (young bodies may be RELOCATING while a young collector copies
    /// them, so the alias must cover them too). 0: none.
    let extraBytes: Int
    let blockCount: Int
    let memoryEntry: mach_port_t
    let used: UnsafeMutablePointer<UInt32>
    let inUse: UnsafeMutablePointer<Bool>
    /// Module 10: `BlockKind` per block. Written under the pools lock or
    /// with the world stopped, as `inUse` is.
    let kind: UnsafeMutablePointer<UInt8>

    init(bytes: Int, extraBytes: Int = 0) throws(ObjectMemoryError) {
        let (p, entry) = try unsafe VirtualMemory.reserveTwice(bytes + extraBytes)
        unsafe base = p
        self.bytes = bytes
        self.extraBytes = extraBytes
        blockCount = bytes / BlockHeap.blockBytes
        memoryEntry = entry
        unsafe used = .allocate(capacity: blockCount)
        unsafe used.initialize(repeating: 0, count: blockCount)
        unsafe inUse = .allocate(capacity: blockCount)
        unsafe inUse.initialize(repeating: false, count: blockCount)
        unsafe kind = .allocate(capacity: blockCount)
        unsafe kind.initialize(repeating: BlockKind.ordinary, count: blockCount)
    }

    func release() {
        unsafe VirtualMemory.releaseTwice(base, bytes + extraBytes, memoryEntry)
        unsafe used.deallocate()
        unsafe inUse.deallocate()
        unsafe kind.deallocate()
    }

    @inline(__always)
    static func start(ofBlock b: Int) -> UInt64 { UInt64(b) &<< blockShift }

    @inline(__always)
    static func block(ofOffset off: UInt64) -> Int { Int(truncatingIfNeeded: off &>> blockShift) }

    func usedBytes(_ b: Int) -> UInt64 { UInt64(unsafe used[b]) }
    func setUsed(_ b: Int, _ v: UInt64) { unsafe used[b] = UInt32(v) }
    func isInUse(_ b: Int) -> Bool { unsafe inUse[b] }
    func setInUse(_ b: Int, _ v: Bool) { unsafe inUse[b] = v }
    func kind(_ b: Int) -> UInt8 { unsafe kind[b] }
    func setKind(_ b: Int, _ v: UInt8) { unsafe kind[b] = v }
    /// Module 10: the block is part of a run (its head or a continuation).
    func isRun(_ b: Int) -> Bool { unsafe kind[b] != BlockKind.ordinary }

    /// The blocks a run whose body has `bytes` covers.
    @inline(__always)
    static func runBlocks(bytes: UInt64) -> Int {
        Int(truncatingIfNeeded: (bytes &+ UInt64(blockBytes) &- 1) &>> blockShift)
    }

    /// The head of the run `b` belongs to (a continuation walks back), or
    /// `b` itself. Callers know `b` is a run block.
    func runHead(of b: Int) -> Int {
        var h = b
        while h > 0 && kind(h) == BlockKind.continuation { h -= 1 }
        return h
    }

    /// The blocks of the run whose head is `b`: from its `used`.
    func runLength(head b: Int) -> Int { BlockHeap.runBlocks(bytes: usedBytes(b)) }

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

/// Module 10's side table: what a block is. A free block is ordinary and
/// not in use.
enum BlockKind {
    static let ordinary: UInt8 = 0
    /// The first block of a large object's run: its body starts here.
    static let head: UInt8 = 1
    /// A later block of a run: no body starts here, and no entry may point
    /// into it.
    static let continuation: UInt8 = 2
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
