import Foundation
import Testing
@testable import KajoVM

/// The walk graph of object-representation's snapshot kernel, scaled down:
/// `n` nodes (class 2: next, val), node i -> (1664525 i + 1013904223) mod n,
/// a full-period cycle in a scattered order, plus a byte object.
private func buildGraph(_ w: World, _ n: Int) -> RootHandle {
    let holder = w.new(4, n)
    let r = w.om.addRoot(holder)
    for i in 0..<n {
        let node = w.new(2, 2)
        w.om.store(node, 1, int(Int64(i)))
        w.om.store(w.om.root(r), i, node)
    }
    let h = w.om.root(r)
    for i in 0..<n {
        let j = (1_664_525 * i + 1_013_904_223) % n
        w.om.store(w.om.load(h, i), 0, w.om.load(h, j))
    }
    let b = w.bytes(100)
    for i in 0..<100 { w.om.storeByte(b, i, UInt8(i)) }
    w.om.store(w.om.load(h, 0), 1, b) // node 0's value is the byte object
    return r
}

/// Sum of val * hop over `hops` hops from node 1.
private func walk(_ om: ObjectMemory, _ r: RootHandle, hops: Int) -> Int64 {
    var p = om.load(om.root(r), 1), s: Int64 = 0
    for hop in 1...hops {
        let v = om.load(p, 1)
        s &+= (v.isSmallInteger ? v.smallIntegerValue : Int64(om.loadByte(v, 99))) &* Int64(hop)
        p = om.load(p, 0)
    }
    return s
}

private func config(heapBlocks: Int = 64, entries: Int = 1 << 16) -> ObjectMemoryConfig {
    var c = ObjectMemoryConfig()
    c.heapBytes = heapBlocks * BlockHeap.blockBytes
    c.entryCapacity = entries
    c.onVerifyFailure = .record
    return c
}

private func savedWorld() throws -> (ObjectMemory, World, RootHandle, [UInt8]) {
    let om = try ObjectMemory(config())
    let w = World(om)
    for _ in 0..<300 { _ = w.new(4, 10) }
    let r = buildGraph(w, 2048)
    om.collect()                            // free entries in the image
    for _ in 0..<300 { _ = w.new(4, 10) }  // and garbage
    return (om, w, r, om.snapshot())
}

/// Ported from object-representation (B): load at a new base, no word of
/// the heap or of a used entry changes, the graph walks the same.
@Test func snapshotRoundTripAtANewBase() throws {
    let (om, _, r, bytes) = try savedWorld()
    defer { om.destroy() }
    let before = walk(om, r, hops: 4096)
    let loaded = try ObjectMemory.load(snapshot: bytes, config: config())
    defer { loaded.destroy() }
    #expect(loaded.heapBase != om.heapBase)
    #expect(walk(loaded, r, hops: 4096) == before)
    var changed = 0
    for b in 0..<om.heap.blockCount where om.heap.isInUse(b) {
        #expect(loaded.heap.usedBytes(b) == om.heap.usedBytes(b))
        let start = BlockHeap.start(ofBlock: b)
        for i in stride(from: start, to: start + om.heap.usedBytes(b), by: 8)
        where loaded.heap.word(atOffset: i) != om.heap.word(atOffset: i) { changed += 1 }
    }
    #expect(changed == 0) // no relocation: oops are entry offsets
    #expect(loaded.highWater == om.highWater)
    for e in 1..<om.highWater where !EntryState.isFree(om.stateWord(e << 4)) {
        #expect(loaded.stateWord(e << 4) == om.stateWord(e << 4) && loaded.headerWord(e << 4) == om.headerWord(e << 4))
    }
    #expect(loaded.classCount == om.classCount && loaded.rootCount == om.rootCount)
    #expect(om.counters.snapshotsSaved == 1)
}

@Test func aLoadedMemoryAllocatesCollectsAndCompacts() throws {
    let (om, w, r, bytes) = try savedWorld()
    defer { om.destroy() }
    let before = walk(om, r, hops: 3000)
    let loaded = try ObjectMemory.load(snapshot: bytes, config: config())
    defer { loaded.destroy() }
    loaded.retireAllContexts()
    #expect(loaded.verifyHeap() == [] && loaded.verifyFreeLists() == [])
    let ctx = loaded.makeContext()
    for _ in 0..<1000 { _ = loaded.allocate(ctx, classIndex: 4, slots: 10, fill: w.nilObj) }
    loaded.collect()
    loaded.compact()
    #expect(walk(loaded, r, hops: 3000) == before)
    #expect(loaded.counters.verifierFailures == 0 && loaded.counters.objectsMoved > 0)
}

@Test func snapshotThroughAFile() throws {
    let (om, _, r, _) = try savedWorld()
    defer { om.destroy() }
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("kajo-om-\(UUID()).image").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    try om.snapshot(toFile: path)
    let loaded = try ObjectMemory.load(contentsOfFile: path, config: config())
    defer { loaded.destroy() }
    #expect(walk(loaded, r, hops: 100) == walk(om, r, hops: 100))
}

@Test func snapshotDropsFramePinsAndKeepsPermanentOnes() throws {
    let (om, _, r, _) = try savedWorld()
    defer { om.destroy() }
    let a = om.load(om.root(r), 3), b = om.load(om.root(r), 4)
    om.pinForFrame(a)
    om.pinForGood(b)
    let loaded = try ObjectMemory.load(snapshot: om.snapshot(), config: config())
    defer { loaded.destroy() }
    #expect(!loaded.isPinned(a) && loaded.header(b).isPinnedForGood)
    #expect(om.header(a).isFramePinned) // the running memory keeps its pin
}

@Test func theLoaderRefusesASnapshotThatDoesNotFitTheConfiguration() throws {
    let (om, _, _, bytes) = try savedWorld()
    defer { om.destroy() }
    #expect { try ObjectMemory.load(snapshot: bytes, config: config(heapBlocks: 1)) } throws: { e in
        if case SnapshotError.doesNotFit = e { true } else { false }
    }
    #expect { try ObjectMemory.load(snapshot: bytes, config: config(entries: 100)) } throws: { e in
        if case SnapshotError.doesNotFit = e { true } else { false }
    }
}

// MARK: - the loader rejects every broken invariant

enum SnapshotCorruption: CaseIterable, Sendable {
    case badMagic, futureVersion, wrongBlockSize, truncated, trailingBytes, hugeRootCount
    case highWaterZero, usedNotAligned, usedBeyondBlock, entryZeroUsed, classZeroSet
    case misalignedOffset, offsetPastHeap, offsetInFreeBlock, relocatingState
    case backReferenceMismatch, sizeMismatch, reservedHeaderBit, framePin, unregisteredClass
    case danglingSlot, reservedTagInSlot, noneInSlot, danglingRoot, danglingClass
    case freeEntryWithHeader, twoEntriesOneBody, walkBreaks, offsetBeyondUsed, offsetIntoAnotherBody

    var needle: String {
        switch self {
        case .badMagic: "magic"
        case .futureVersion: "version"
        case .wrongBlockSize: "block size"
        case .truncated, .trailingBytes, .hugeRootCount: "length"
        case .highWaterZero: "high water"
        case .usedNotAligned, .usedBeyondBlock: "used"
        case .entryZeroUsed: "entry 0"
        case .classZeroSet: "class 0"
        case .misalignedOffset: "aligned"
        case .offsetPastHeap: "outside the heap"
        case .offsetInFreeBlock: "not in use"
        case .relocatingState: "RELOCATING"
        case .backReferenceMismatch, .twoEntriesOneBody: "back reference"
        case .sizeMismatch: "size"
        case .reservedHeaderBit: "reserved"
        case .framePin: "frame pin"
        case .unregisteredClass: "not registered"
        case .danglingSlot, .reservedTagInSlot, .noneInSlot: "slot"
        case .danglingRoot: "root"
        case .danglingClass: "class table"
        case .freeEntryWithHeader: "free entry"
        case .walkBreaks: "walk"
        case .offsetBeyondUsed: "used bytes"
        case .offsetIntoAnotherBody: "start of a body"
        }
    }
}

private func putWord(_ b: inout [UInt8], _ at: Int, _ v: UInt64) {
    for k in 0..<8 { b[at + k] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(k))) }
}

private func getWord(_ b: [UInt8], _ at: Int) -> UInt64 {
    (0..<8).reduce(0) { $0 | UInt64(b[at + $1]) << (8 * UInt64($1)) }
}

@Test(arguments: SnapshotCorruption.allCases)
func theLoaderRejects(_ c: SnapshotCorruption) throws {
    let (om, _, r, good) = try savedWorld()
    defer { om.destroy() }
    let L = try SnapshotLayout(parsing: good)
    var b = good
    let node = om.load(om.root(r), 5), other = om.load(om.root(r), 6)
    let entry = { (o: Oop) in L.tableAt + Int(o.entryIndex) * 16 }
    let body = { (o: Oop) in L.heapAt(offset: om.bodyOffset(o)) }
    let freeEntry = (1..<om.highWater).first { EntryState.isFree(om.stateWord($0 << 4)) }!
    let freeBlock = L.blockCount // not in use in the loaded heap
    switch c {
    case .badMagic: b[0] ^= 1
    case .futureVersion: putWord(&b, 8, 99)
    case .wrongBlockSize: putWord(&b, 16, 4096)
    case .truncated: b.removeLast(8)
    case .trailingBytes: b.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
    case .hugeRootCount: putWord(&b, 6 * 8, UInt64.max / 2)
    case .highWaterZero: putWord(&b, 4 * 8, 0)
    case .usedNotAligned: putWord(&b, L.usedAt, getWord(b, L.usedAt) + 1)
    case .usedBeyondBlock: putWord(&b, L.usedAt, 1 << 20)
    case .entryZeroUsed: putWord(&b, L.tableAt, 64)
    case .classZeroSet: putWord(&b, L.classTableAt, node.raw)
    case .misalignedOffset: putWord(&b, entry(node), om.bodyOffset(node) + 4)
    case .offsetPastHeap: putWord(&b, entry(node), 1 << 31)
    case .offsetInFreeBlock: putWord(&b, entry(node), BlockHeap.start(ofBlock: freeBlock))
    case .relocatingState: putWord(&b, entry(node), om.bodyOffset(node) | EntryState.relocatingBit)
    case .backReferenceMismatch: putWord(&b, body(node), BackRef.make(entryIndex: other.entryIndex, words: 3))
    case .sizeMismatch: putWord(&b, entry(node) + 8, Header(classIndex: 2, count: 1, isBytes: false).raw)
    case .reservedHeaderBit: putWord(&b, entry(node) + 8, om.headerWord(node.raw) | Header.youngBit)
    case .framePin: putWord(&b, entry(node) + 8, om.headerWord(node.raw) | Header.framePinBit)
    case .unregisteredClass: putWord(&b, entry(node) + 8, Header(classIndex: 3000, count: 2, isBytes: false).raw)
    case .danglingSlot: putWord(&b, body(node) + 8, Oop(entryIndex: om.highWater + 1).raw)
    case .reservedTagInSlot: putWord(&b, body(node) + 8, 0x104)
    case .noneInSlot: putWord(&b, body(node) + 8, 0)
    case .danglingRoot: putWord(&b, L.rootsAt, Oop(entryIndex: freeEntry).raw)
    case .danglingClass: putWord(&b, L.classTableAt + 16, Oop(entryIndex: freeEntry).raw)
    case .freeEntryWithHeader: putWord(&b, L.tableAt + Int(freeEntry) * 16 + 8, 1)
    case .twoEntriesOneBody:
        putWord(&b, entry(other), om.bodyOffset(node))
    case .walkBreaks: putWord(&b, body(node), BackRef.make(entryIndex: node.entryIndex, words: 0))
    case .offsetBeyondUsed:
        let blk = om.blockIndex(of: node)
        putWord(&b, entry(node), BlockHeap.start(ofBlock: blk) + L.used[blk])
    case .offsetIntoAnotherBody:
        // A fake body for `other` inside the byte object's data.
        let bytes = om.load(om.load(om.root(r), 0), 1)
        let fake = om.bodyOffset(bytes) + 16
        putWord(&b, L.heapAt(offset: fake), BackRef.make(entryIndex: other.entryIndex, words: 3))
        putWord(&b, L.heapAt(offset: fake + 8), int(1).raw)
        putWord(&b, L.heapAt(offset: fake + 16), int(2).raw)
        putWord(&b, entry(other), fake)
    }
    #expect(b != good)
    #expect { try ObjectMemory.load(snapshot: b, config: config()) } throws: { e in
        guard let e = e as? SnapshotError else { return false }
        let text = "\(e)"
        if !text.contains(c.needle) { Issue.record("\(c): \(text.prefix(400))") }
        return true
    }
}

/// The precursor of the loader's fuzz target (module 2 adds libFuzzer):
/// seeded random mutations of a valid snapshot either load into a memory
/// that verifies clean or are rejected, and never crash.
@Test func mutatedSnapshotsLoadCleanOrAreRejected() throws {
    let om = try ObjectMemory(config(heapBlocks: 8, entries: 4096))
    defer { om.destroy() }
    let w = World(om)
    _ = buildGraph(w, 64)
    let good = om.snapshot()
    var rng = SplitMix(seed: 42)
    var loaded = 0, rejected = 0
    for _ in 0..<3000 {
        var b = good
        for _ in 0..<(1 + Int(rng.next() % 4)) {
            let i = Int(rng.next() % UInt64(b.count))
            b[i] ^= UInt8(truncatingIfNeeded: 1 << (rng.next() % 8))
        }
        do {
            let m = try ObjectMemory.load(snapshot: b, config: config(heapBlocks: 8, entries: 4096))
            m.retireAllContexts()
            #expect(m.verifyHeap() == [] && m.verifyFreeLists() == [])
            m.collect()
            m.destroy()
            loaded += 1
        } catch {
            rejected += 1
        }
    }
    #expect(rejected > 1000 && loaded > 100)
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
