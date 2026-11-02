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
    var freeCap: Int
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
        if getenv("KAJO_SINGLE_MAP") != nil {
            guard let p = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), p != MAP_FAILED else { fatal("mmap") }
            base = p
        } else {
            base = mapTwice(total)
        }
        used = .allocate(capacity: nblocks)
        used.initialize(repeating: 0, count: nblocks)
        inUse = .allocate(capacity: nblocks)
        inUse.initialize(repeating: false, count: nblocks)
        live = .allocate(capacity: nblocks)
        live.initialize(repeating: false, count: nblocks)
        // Room for blocks appended outside pauses (SPEC.md "Freeing old blocks").
        freeCap = 2 * nblocks
        freeList = .allocate(capacity: freeCap)
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
        // A CAS on the take index bounded by the count (acquire: the
        // relocator appends freed blocks outside pauses, SPEC.md "Freeing
        // old blocks: epochs").
        var i = freeNext.pointee.load(ordering: .relaxed)
        while true {
            if i >= freeCount.pointee.load(ordering: .acquiring) { return nil }
            let (ok, cur) = freeNext.pointee.compareExchange(expected: i, desired: i &+ 1, ordering: .relaxed)
            if ok { break }
            i = cur
        }
        let b = freeList[i]
        inUse[Int(b)] = true
        taken.pointee.wrappingAdd(1, ordering: .relaxed)
        return b
    }

    /// Relocator, outside a pause (one appender at a time; pauses rebuild
    /// the list): a freed block becomes takeable. False when the list is
    /// full (the block then waits for a pause).
    func appendFree(_ b: Int) -> Bool {
        let c = freeCount.pointee.load(ordering: .relaxed)
        if c >= freeCap { return false }
        used[b] = 0
        inUse[b] = false
        taken.pointee.wrappingSubtract(1, ordering: .relaxed)
        freeList[c] = UInt32(b)
        freeCount.pointee.store(c &+ 1, ordering: .releasing)
        return true
    }

    /// World stopped: free one block (it is added by the next rebuild, or
    /// appended now).
    func freeAtPause(_ b: Int) {
        if !appendFree(b) {
            used[b] = 0
            inUse[b] = false
        }
    }

    /// Whether block `b` is in the unconsumed part of the free list (verifier).
    func freeListContains(_ b: Int) -> Int {
        let lo = min(freeNext.pointee.load(ordering: .relaxed), freeCount.pointee.load(ordering: .relaxed))
        var n = 0
        for i in lo..<freeCount.pointee.load(ordering: .relaxed) where Int(freeList[i]) == b { n += 1 }
        return n
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

    /// World stopped: rebuild the free list from `inUse` alone (the lazy
    /// sweep's apply has already cleared `inUse` of dead blocks).
    func rebuildFreeList() {
        var nfree = 0
        var inuse = 0
        for b in 0..<nblocks {
            if inUse[b] { inuse &+= 1; continue }
            freeList[nfree] = UInt32(b)
            nfree &+= 1
        }
        freeCount.pointee.store(nfree, ordering: .relaxed)
        freeNext.pointee.store(0, ordering: .relaxed)
        taken.pointee.store(inuse, ordering: .relaxed)
    }

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

/// The heap's alias distance (SPEC.md "Entry state encoding"): every body is
/// also addressable at `address + relocBit`, so an offset word holding
/// `off + relocBit` (RELOCATING) still leads to the old body.
public let relocBit: UInt64 = 1 << 32

/// Reserve `relocBit + bytes` of address space and map one memory object of
/// `bytes` at its start and again at `+ relocBit`. Pages are zero-filled on
/// demand, as with the anonymous mmap this replaces.
private func mapTwice(_ bytes: Int) -> UnsafeMutableRawPointer {
    precondition(UInt64(bytes) < relocBit, "heap larger than the alias distance")
    let task = mach_task_self_
    var addr: mach_vm_address_t = 0
    let span = mach_vm_size_t(bytes)
    var kr = mach_vm_allocate(task, &addr, mach_vm_size_t(relocBit) + span, VM_FLAGS_ANYWHERE)
    if kr != KERN_SUCCESS { fatal("mach_vm_allocate: \(kr)") }
    var size = memory_object_size_t(span)
    var entry: mach_port_t = 0
    kr = mach_make_memory_entry_64(task, &size, 0, MAP_MEM_NAMED_CREATE | VM_PROT_READ | VM_PROT_WRITE, &entry,
                                   mach_port_t(MACH_PORT_NULL))
    if kr != KERN_SUCCESS || size < span { fatal("mach_make_memory_entry_64: \(kr)") }
    for at in [addr, addr + mach_vm_address_t(relocBit)] {
        var a = at
        kr = mach_vm_map(task, &a, span, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, entry, 0, 0,
                         VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE)
        if kr != KERN_SUCCESS || a != at { fatal("mach_vm_map: \(kr)") }
    }
    return UnsafeMutableRawPointer(bitPattern: UInt(addr)).unsafelyUnwrapped
}
