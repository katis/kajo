// Block-structured arena, free-block pool, TLABs, and the nursery region
// (SPEC.md "Spaces"). Representation-neutral: it hands out bytes. What an
// object looks like inside a block is Memory.swift's business.
//
// One reservation: old blocks up to the soft limit, then the promotion
// reserve (also blocks, used only by the scavenge), then 16 nurseries.

import Darwin
import Synchronization

public let blockSize = 32 * 1024
public let noBlock: UInt32 = .max
/// Nursery slots, one per worker id (SPEC.md "Spaces").
public let maxNurseries = 16

/// Thread-local allocation buffer: a bump pointer into one block, or into a
/// whole nursery (then `block == noBlock`).
public struct Tlab {
    public var cur: UInt = 0
    public var end: UInt = 0
    public var block: UInt32 = noBlock
}

public struct Heap {
    public var base: UnsafeMutableRawPointer
    /// Old blocks including the promotion reserve.
    public var nblocks: Int
    /// Mutator old allocation stops here (the heap size parameter).
    public var softBlocks: Int
    public var nurseryBytes: Int
    var used: UnsafeMutablePointer<UInt32>
    var inUse: UnsafeMutablePointer<Bool>
    /// Scratch for sweeps: set for blocks that hold a live object.
    var live: UnsafeMutablePointer<Bool>
    var freeList: UnsafeMutablePointer<UInt32>
    var freeCount: UnsafeMutablePointer<Atomic<Int>>
    var freeNext: UnsafeMutablePointer<Atomic<Int>>
    /// Blocks in use (taken since the last rebuild plus the live ones).
    var taken: UnsafeMutablePointer<Atomic<Int>>

    init(size: Int, nurseryBytes: Int) {
        precondition(size % blockSize == 0 && nurseryBytes % blockSize == 0)
        let reserve = nurseryBytes * maxNurseries
        softBlocks = size / blockSize
        nblocks = (size + reserve) / blockSize
        self.nurseryBytes = nurseryBytes
        let total = nblocks * blockSize + reserve
        guard let p = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), p != MAP_FAILED else {
            fatal("mmap failed")
        }
        base = p
        used = .allocate(capacity: nblocks)
        used.initialize(repeating: 0, count: nblocks)
        inUse = .allocate(capacity: nblocks)
        inUse.initialize(repeating: false, count: nblocks)
        live = .allocate(capacity: nblocks)
        live.initialize(repeating: false, count: nblocks)
        freeList = .allocate(capacity: nblocks)
        for i in 0..<nblocks { freeList[i] = UInt32(i) }
        freeCount = .allocate(capacity: 1)
        freeCount.initialize(to: Atomic(nblocks))
        freeNext = .allocate(capacity: 1)
        freeNext.initialize(to: Atomic(0))
        taken = .allocate(capacity: 1)
        taken.initialize(to: Atomic(0))
    }

    @inline(__always) var baseAddr: UInt { UInt(bitPattern: base) }

    @inline(__always) func blockStart(_ b: Int) -> UInt {
        baseAddr &+ UInt(b) &* UInt(blockSize)
    }

    @inline(__always) func blockOf(_ addr: UInt) -> Int {
        Int((addr &- baseAddr) / UInt(blockSize))
    }

    /// First byte of nursery `slot`.
    @inline(__always) func nurseryStart(_ slot: Int) -> UInt {
        baseAddr &+ UInt(nblocks &* blockSize) &+ UInt(slot &* nurseryBytes)
    }

    /// True if `addr` lies in the nursery region.
    @inline(__always) func inNurseries(_ addr: UInt) -> Bool {
        addr >= baseAddr &+ UInt(nblocks &* blockSize)
    }

    @inline(__always) func usedBytes(_ b: Int) -> Int { Int(used[b]) }
    @inline(__always) func isInUse(_ b: Int) -> Bool { inUse[b] }

    /// Takes a completely empty block from the pool. Lock-free; the pool is
    /// only rebuilt while the world is stopped. `soft`: refuse once the soft
    /// limit is in use (mutator allocation); promotion passes false.
    func takeBlock(soft: Bool) -> UInt32? {
        if soft && taken.pointee.load(ordering: .relaxed) >= softBlocks { return nil }
        let i = freeNext.pointee.wrappingAdd(1, ordering: .relaxed).oldValue
        if i < freeCount.pointee.load(ordering: .relaxed) {
            let b = freeList[i]
            inUse[Int(b)] = true
            taken.pointee.wrappingAdd(1, ordering: .relaxed)
            return b
        }
        return nil
    }

    /// Point the TLAB at a fresh block. Returns false if none is available.
    func refill(_ t: inout Tlab, soft: Bool = true) -> Bool {
        retire(&t)
        guard let b = takeBlock(soft: soft) else { return false }
        t.block = b
        t.cur = blockStart(Int(b))
        t.end = t.cur &+ UInt(blockSize)
        return true
    }

    /// Record how much of the TLAB's block is used and detach it.
    func retire(_ t: inout Tlab) {
        if t.block != noBlock {
            used[Int(t.block)] = UInt32(t.cur &- blockStart(Int(t.block)))
        }
        t = Tlab()
    }

    /// Free blocks under the soft limit.
    public func freeBlocks() -> Int {
        max(0, softBlocks - taken.pointee.load(ordering: .relaxed))
    }

    public func blocksInUse() -> Int { taken.pointee.load(ordering: .relaxed) }

    /// World stopped: in-use blocks whose `live` flag is clear return to the
    /// pool; clears the flags; rebuilds the pool in block index order.
    func rebuildPool() -> Int {
        var nfree = 0
        var inuse = 0
        for b in 0..<nblocks {
            if inUse[b] {
                if live[b] { live[b] = false; inuse &+= 1; continue }
                inUse[b] = false
                used[b] = 0
            }
            freeList[nfree] = UInt32(b)
            nfree &+= 1
        }
        freeCount.pointee.store(nfree, ordering: .relaxed)
        freeNext.pointee.store(0, ordering: .relaxed)
        taken.pointee.store(inuse, ordering: .relaxed)
        return nfree
    }
}
