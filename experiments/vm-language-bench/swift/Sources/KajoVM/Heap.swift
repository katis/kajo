// Block-structured arena, free-block pool and TLABs (SPEC-SHARED.md "Heap, TLAB, GC").

import Darwin
import Synchronization

public let blockSize = 32 * 1024
public let heapSize = 64 << 20
public let noBlock: UInt32 = .max

/// Thread-local allocation buffer: a bump pointer into one block.
/// Addresses are kept as UInt so the fast path has no optionals.
public struct Tlab {
    public var cur: UInt = 0
    public var end: UInt = 0
    public var block: UInt32 = noBlock
}

public struct Heap {
    public var base: UnsafeMutableRawPointer
    public var nblocks: Int
    var used: UnsafeMutablePointer<UInt32>
    var inUse: UnsafeMutablePointer<Bool>
    var freeList: UnsafeMutablePointer<UInt32>
    var freeCount: UnsafeMutablePointer<Atomic<Int>>
    var freeNext: UnsafeMutablePointer<Atomic<Int>>

    init(size: Int) {
        precondition(size % blockSize == 0)
        guard let p = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), p != MAP_FAILED else {
            fatal("mmap failed")
        }
        base = p
        nblocks = size / blockSize
        used = .allocate(capacity: nblocks)
        used.initialize(repeating: 0, count: nblocks)
        inUse = .allocate(capacity: nblocks)
        inUse.initialize(repeating: false, count: nblocks)
        freeList = .allocate(capacity: nblocks)
        for i in 0..<nblocks { freeList[i] = UInt32(i) }
        freeCount = .allocate(capacity: 1)
        freeCount.initialize(to: Atomic(nblocks))
        freeNext = .allocate(capacity: 1)
        freeNext.initialize(to: Atomic(0))
    }

    @inline(__always) func blockStart(_ b: UInt32) -> UInt {
        UInt(bitPattern: base) &+ UInt(b) &* UInt(blockSize)
    }

    /// Takes a completely empty block from the pool. Lock-free; the pool is
    /// only rebuilt while the world is stopped.
    func takeBlock() -> UInt32? {
        let i = freeNext.pointee.wrappingAdd(1, ordering: .relaxed).oldValue
        if i < freeCount.pointee.load(ordering: .relaxed) {
            let b = freeList[i]
            inUse[Int(b)] = true
            return b
        }
        return nil
    }

    /// Point the TLAB at a fresh block. Returns false if the pool is empty.
    func refill(_ t: inout Tlab) -> Bool {
        retire(&t)
        guard let b = takeBlock() else { return false }
        t.block = b
        t.cur = blockStart(b)
        t.end = t.cur &+ UInt(blockSize)
        return true
    }

    /// Record how much of the TLAB's block is used and detach it.
    func retire(_ t: inout Tlab) {
        if t.block != noBlock {
            used[Int(t.block)] = UInt32(t.cur &- blockStart(t.block))
        }
        t = Tlab()
    }

    public func freeBlocks() -> Int {
        max(0, freeCount.pointee.load(ordering: .relaxed) - freeNext.pointee.load(ordering: .relaxed))
    }

    /// Sweep (world stopped, all TLABs retired): clear marks, return blocks
    /// without live objects to the pool. Returns (free blocks, live bytes).
    func sweep() -> (Int, Int) {
        var liveBytes = 0
        var nfree = 0
        for b in 0..<nblocks {
            if inUse[b] {
                let start = blockStart(UInt32(b))
                let end = start &+ UInt(used[b])
                var p = start
                var live = false
                while p < end {
                    let hp = UnsafeMutablePointer<UInt64>(bitPattern: p).unsafelyUnwrapped
                    let h = hp.pointee
                    let size = objectBytes(h)
                    if hdrMarked(h) {
                        hp.pointee = h & ~markBit
                        live = true
                        liveBytes &+= size
                    }
                    p &+= UInt(size)
                }
                if live { continue }
                inUse[b] = false
                used[b] = 0
            }
            freeList[nfree] = UInt32(b)
            nfree &+= 1
        }
        freeCount.pointee.store(nfree, ordering: .relaxed)
        freeNext.pointee.store(0, ordering: .relaxed)
        return (nfree, liveBytes)
    }
}

/// Allocation fast path. Returns 0 when the TLAB is exhausted.
@inline(__always)
func tlabAlloc(_ t: inout Tlab, _ cls: UInt32, _ slots: Int, _ bytes: Bool, _ fill: Oop) -> Oop {
    let size = sizeFor(slots, bytes)
    if t.end &- t.cur < UInt(size) { return 0 }
    let p = UnsafeMutablePointer<UInt64>(bitPattern: t.cur).unsafelyUnwrapped
    t.cur &+= UInt(size)
    p.pointee = makeHeader(cls, slots, bytes)
    let n = (size &- 8) / 8
    let f = bytes ? 0 : fill
    var i = 1
    while i <= n { p[i] = f; i &+= 1 }
    return Oop(UInt(bitPattern: p))
}
