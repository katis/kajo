// Block-structured arena, free-block pool and TLABs (SPEC-SHARED.md "Heap,
// TLAB, GC"). Representation-neutral: it hands out bytes. What an object
// looks like inside a block is the variant's business (Memory.swift).

import Darwin
import Synchronization

public let blockSize = 32 * 1024
public let noBlock: UInt32 = .max

/// Thread-local allocation buffer: a bump pointer into one block.
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
    /// Scratch for sweeps: set for blocks that hold a live object.
    var live: UnsafeMutablePointer<Bool>
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
        live = .allocate(capacity: nblocks)
        live.initialize(repeating: false, count: nblocks)
        freeList = .allocate(capacity: nblocks)
        for i in 0..<nblocks { freeList[i] = UInt32(i) }
        freeCount = .allocate(capacity: 1)
        freeCount.initialize(to: Atomic(nblocks))
        freeNext = .allocate(capacity: 1)
        freeNext.initialize(to: Atomic(0))
    }

    @inline(__always) var baseAddr: UInt { UInt(bitPattern: base) }

    @inline(__always) func blockStart(_ b: Int) -> UInt {
        baseAddr &+ UInt(b) &* UInt(blockSize)
    }

    @inline(__always) func blockOf(_ addr: UInt) -> Int {
        Int((addr &- baseAddr) / UInt(blockSize))
    }

    @inline(__always) func usedBytes(_ b: Int) -> Int { Int(used[b]) }
    @inline(__always) func isInUse(_ b: Int) -> Bool { inUse[b] }

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

    public func freeBlocks() -> Int {
        max(0, freeCount.pointee.load(ordering: .relaxed) - freeNext.pointee.load(ordering: .relaxed))
    }

    func lastInUse() -> Int {
        var b = nblocks - 1
        while b >= 0 && !inUse[b] { b -= 1 }
        return b
    }

    /// World stopped: in-use blocks whose `live` flag is clear return to the
    /// pool; clears the flags; rebuilds the pool in block index order.
    func rebuildPool() -> Int {
        var nfree = 0
        for b in 0..<nblocks {
            if inUse[b] {
                if live[b] { live[b] = false; continue }
                inUse[b] = false
                used[b] = 0
            }
            freeList[nfree] = UInt32(b)
            nfree &+= 1
        }
        freeCount.pointee.store(nfree, ordering: .relaxed)
        freeNext.pointee.store(0, ordering: .relaxed)
        return nfree
    }

    /// Compaction: block `b` is a destination holding `bytes`. Call for every
    /// destination block, then `rebuildPool()` frees all other blocks.
    func setDestination(_ b: Int, bytes: Int) {
        inUse[b] = true
        used[b] = UInt32(bytes)
        live[b] = true
    }

    /// Snapshot load: restore block metadata.
    func restore(used u: [UInt32]) {
        for b in 0..<nblocks {
            let x = b < u.count ? u[b] : UInt32.max
            if x == UInt32.max { inUse[b] = false; used[b] = 0 } else { inUse[b] = true; used[b] = x }
        }
        for b in 0..<nblocks { live[b] = inUse[b] }
        _ = rebuildPool()
    }
}
