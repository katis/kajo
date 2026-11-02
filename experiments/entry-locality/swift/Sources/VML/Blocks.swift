// Block arenas for variant L (SPEC.md "Variant L layout"). Replaces the
// shared Blocks.swift of object-representation for this module only.
// Differences from the shared file:
// - two arenas in one reservation: small blocks of 16 KiB (one page; bodies
//   grow up from the bottom, entries grow down from the top) and, after
//   them, a large-object arena of 32 KiB blocks (bodies only, never moved);
// - per-block `entryLow` beside `used`; a TLAB's `end` is the entry bump
//   pointer, so retiring records both;
// - the small pool holds every block whose free gap is at least `minGap`
//   (partially used blocks too), and a refill starts at the block's gap.
// The shared VM code sees the same API as before: Heap, Tlab, blockSize,
// heap.retire(&tlab), heap.base, heap.baseAddr, heap.freeBlocks().

import Darwin
import Synchronization

public let blockSize = 16 * 1024
public let largeBlockSize = 32 * 1024
/// Bodies larger than this go to the large-object arena.
public let largeThreshold = 4096
/// A partially used small block goes back to the pool if its gap is this big.
let minGap = 1024
public let noBlock: UInt32 = .max

/// Thread-local allocation buffer. Small arena: `cur` bumps bodies up, `end`
/// bumps entries down. Large arena: `end` is the block end.
public struct Tlab {
    public var cur: UInt = 0
    public var end: UInt = 0
    public var block: UInt32 = noBlock
}

/// One arena of equal blocks with its lock-free pool.
public struct Arena {
    public var start: UInt
    public var bsize: Int
    public var nblocks: Int
    var partialReuse: Bool
    var used: UnsafeMutablePointer<UInt32>
    var entryLow: UnsafeMutablePointer<UInt32>
    var inUse: UnsafeMutablePointer<Bool>
    var live: UnsafeMutablePointer<Bool>
    var freeList: UnsafeMutablePointer<UInt32>
    var freeCount: UnsafeMutablePointer<Atomic<Int>>
    var freeNext: UnsafeMutablePointer<Atomic<Int>>

    init(start: UInt, bsize: Int, nblocks: Int, partialReuse: Bool) {
        self.start = start
        self.bsize = bsize
        self.nblocks = nblocks
        self.partialReuse = partialReuse
        used = .allocate(capacity: max(nblocks, 1))
        used.initialize(repeating: 0, count: max(nblocks, 1))
        entryLow = .allocate(capacity: max(nblocks, 1))
        entryLow.initialize(repeating: UInt32(bsize), count: max(nblocks, 1))
        inUse = .allocate(capacity: max(nblocks, 1))
        inUse.initialize(repeating: false, count: max(nblocks, 1))
        live = .allocate(capacity: max(nblocks, 1))
        live.initialize(repeating: false, count: max(nblocks, 1))
        freeList = .allocate(capacity: max(nblocks, 1))
        for i in 0..<nblocks { freeList[i] = UInt32(i) }
        freeCount = .allocate(capacity: 1)
        freeCount.initialize(to: Atomic(nblocks))
        freeNext = .allocate(capacity: 1)
        freeNext.initialize(to: Atomic(0))
    }

    @inline(__always) func blockStart(_ b: Int) -> UInt { start &+ UInt(b) &* UInt(bsize) }
    @inline(__always) func blockOf(_ addr: UInt) -> Int { Int((addr &- start) / UInt(bsize)) }
    @inline(__always) func contains(_ addr: UInt) -> Bool {
        addr >= start && addr < start &+ UInt(nblocks) &* UInt(bsize)
    }
    @inline(__always) func usedBytes(_ b: Int) -> Int { Int(used[b]) }
    @inline(__always) func isInUse(_ b: Int) -> Bool { inUse[b] }
    @inline(__always) func gap(_ b: Int) -> Int { Int(entryLow[b]) - Int(used[b]) }

    func takeBlock() -> UInt32? {
        let i = freeNext.pointee.wrappingAdd(1, ordering: .relaxed).oldValue
        if i < freeCount.pointee.load(ordering: .relaxed) {
            let b = freeList[i]
            inUse[Int(b)] = true
            return b
        }
        return nil
    }

    /// Point the TLAB at the free gap of a block from the pool.
    func refill(_ t: inout Tlab) -> Bool {
        retire(&t)
        guard let b = takeBlock() else { return false }
        let s = blockStart(Int(b))
        t.block = b
        t.cur = s &+ UInt(used[Int(b)])
        t.end = s &+ UInt(entryLow[Int(b)])
        return true
    }

    func retire(_ t: inout Tlab) {
        if t.block != noBlock {
            let s = blockStart(Int(t.block))
            used[Int(t.block)] = UInt32(t.cur &- s)
            entryLow[Int(t.block)] = UInt32(t.end &- s)
        }
        t = Tlab()
    }

    func freeBlocks() -> Int {
        max(0, freeCount.pointee.load(ordering: .relaxed) - freeNext.pointee.load(ordering: .relaxed))
    }

    func lastInUse() -> Int {
        var b = nblocks - 1
        while b >= 0 && !inUse[b] { b -= 1 }
        return b
    }

    func inUseCount() -> Int {
        var n = 0
        for b in 0..<nblocks where inUse[b] { n += 1 }
        return n
    }

    /// World stopped: in-use blocks without the `live` flag are freed; the
    /// pool is every free block plus (if `partialReuse`) every live block
    /// whose gap is at least `minGap`, in block order. Clears the flags.
    @discardableResult
    func rebuildPool() -> Int {
        var n = 0
        for b in 0..<nblocks {
            if inUse[b] {
                if live[b] {
                    live[b] = false
                    if partialReuse && gap(b) >= minGap { freeList[n] = UInt32(b); n &+= 1 }
                    continue
                }
                inUse[b] = false
                used[b] = 0
                entryLow[b] = UInt32(bsize)
            }
            freeList[n] = UInt32(b)
            n &+= 1
        }
        freeCount.pointee.store(n, ordering: .relaxed)
        freeNext.pointee.store(0, ordering: .relaxed)
        return n
    }

    /// Snapshot load: restore block metadata (`.max` = not in use).
    func restore(used u: [UInt32], entryLow lo: [UInt32]) {
        for b in 0..<nblocks {
            let x = b < u.count ? u[b] : UInt32.max
            if x == UInt32.max {
                inUse[b] = false; used[b] = 0; entryLow[b] = UInt32(bsize)
            } else {
                inUse[b] = true; used[b] = x; entryLow[b] = lo[b]
            }
            live[b] = inUse[b]
        }
        rebuildPool()
    }
}

public struct Heap {
    public var base: UnsafeMutableRawPointer
    public var small: Arena
    public var large: Arena

    /// `size` bytes of small blocks, then size / 2 of large blocks, in one
    /// reservation; pages arrive on first touch.
    init(size: Int) {
        precondition(size % blockSize == 0)
        let lsize = max(size / 2 / largeBlockSize, 1) * largeBlockSize
        guard let p = mmap(nil, size + lsize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), p != MAP_FAILED else {
            fatal("mmap failed")
        }
        precondition(UInt(bitPattern: p) % UInt(blockSize) == 0, "heap not 16 KiB aligned")
        base = p
        small = Arena(start: UInt(bitPattern: p), bsize: blockSize, nblocks: size / blockSize, partialReuse: true)
        large = Arena(start: UInt(bitPattern: p) &+ UInt(size), bsize: largeBlockSize,
                      nblocks: lsize / largeBlockSize, partialReuse: false)
    }

    @inline(__always) public var baseAddr: UInt { UInt(bitPattern: base) }
    public var nblocks: Int { small.nblocks }

    func retire(_ t: inout Tlab) { small.retire(&t) }

    public func freeBlocks() -> Int { small.freeBlocks() }
}
