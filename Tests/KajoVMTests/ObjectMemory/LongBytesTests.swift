// Large bytes, part 1 (docs/modules/large-bytes.md): a byte object of
// 2^24 - 8 bytes or more keeps a sentinel in its header's count field and
// its length in its back reference; the bounds check stays `i < count`,
// with the true length asked only when it fails; every byte primitive over
// such an object polls between chunks of 256 KiB; the snapshot carries it
// and the loader refuses a length that does not fit its run. Each rule's
// broken variant (a test switch) fails its test.

import Testing
@testable import KajoVM

private func longMemory(blocks: Int, switches: TestSwitches = TestSwitches()) throws -> ObjectMemory {
    var c = ObjectMemoryConfig()
    c.heapBytes = blocks * BlockHeap.blockBytes
    c.entryCapacity = 1 << 16
    c.entryChunk = 256
    c.onVerifyFailure = .record
    c.testSwitches = switches
    return try ObjectMemory(c)
}

private let S = Int(Header.longBytesFrom)

@Test func aByteObjectPastTheCountFieldKeepsItsLengthInItsBackReference() throws {
    for n in [S - 1, S, S + 1, S + 7, S + 8, S + 9, 20_000_003] {
        let om = try longMemory(blocks: 1024)
        defer { om.destroy() }
        let w = World(om)
        let b = w.bytes(n)
        let h = om.header(b)
        #expect(om.count(of: b) == UInt64(n), "\(n)")
        #expect(h.isLongBytes == (n >= S), "\(n)")
        #expect(h.count == (n >= S ? Header.longBytesFrom | UInt64(n) & 7 : UInt64(n)), "\(n)")
        // The field is never more than the length: the fast check `i <
        // count` admits no index out of bounds.
        #expect(h.count <= UInt64(n))
        #expect(om.loadByte(b, 0) == 0 && om.loadByte(b, n - 1) == 0)
        om.storeByte(b, n - 1, 200)
        #expect(om.loadByte(b, n - 1) == 200)
        om.retireAllContexts()
        #expect(om.verifyHeap().isEmpty)
    }
}

@Test func theLimitIsTheByteObjectsOwnAndPointersKeepTheirs() throws {
    #expect(Header.maxByteLength == (1 << 31) - 1)
    #expect(Header.maxLargeCount == (1 << 24) - 1)
    #expect(Header.longBytesFrom == UInt64(Header.maxLargeCount) & ~7)
    // A body of the limit's length fits a head's `used` and a back
    // reference's words.
    let words = ObjectMemory.bodyBytes(count: Header.maxByteLength, isBytes: true) / 8
    #expect(words < 1 << 32 && words * 8 < UInt64(UInt32.max))
}

// MARK: - snapshots

private func snapshotWithALongByteArray() throws -> (snap: [UInt8], root: RootHandle, n: Int) {
    let om = try longMemory(blocks: 1024)
    defer { om.destroy() }
    let w = World(om)
    let n = S + 1003
    let b = w.bytes(n)
    om.storeByte(b, n - 1, 77)
    om.storeByte(b, S + 1, 66)
    let r = om.addRoot(b)
    // a short one beside it, for the sentinel-on-a-short-body corruption
    let small = w.bytes(100)
    #expect(om.addRoot(small).index == r.index + 1)
    return (om.snapshot(), r, n)
}

private func loadConfig(_ switches: TestSwitches = TestSwitches()) -> ObjectMemoryConfig {
    var c = ObjectMemoryConfig()
    c.heapBytes = 1024 * BlockHeap.blockBytes
    c.entryCapacity = 1 << 16
    c.onVerifyFailure = .record
    c.testSwitches = switches
    return c
}

@Test func aSnapshotCarriesALongByteObject() throws {
    let (snap, r, n) = try snapshotWithALongByteArray()
    let loaded = try ObjectMemory.load(snapshot: snap, config: loadConfig())
    defer { loaded.destroy() }
    let b = loaded.root(r)
    #expect(loaded.count(of: b) == UInt64(n))
    #expect(loaded.loadByte(b, n - 1) == 77 && loaded.loadByte(b, S + 1) == 66)
    #expect(loaded.verifyHeap().isEmpty && loaded.verifyFreeLists().isEmpty)
}

private func putWord(_ b: inout [UInt8], _ at: Int, _ v: UInt64) {
    for k in 0..<8 { b[at + k] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(k))) }
}

private func word(_ b: [UInt8], _ at: Int) -> UInt64 {
    (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[at + $1]) << (8 * UInt64($1)) }
}

/// Where an entry's words and a body's back reference sit in a snapshot.
private func offsets(_ snap: [UInt8], root: Int) throws -> (entry: Int, body: Int, L: SnapshotLayout) {
    // root: the registry index (RootHandle.index)
    let L = try SnapshotLayout(parsing: snap)
    let o = Oop(raw: word(snap, L.rootsAt + 8 * root))
    let entry = L.tableAt + Int(o.entryIndex) * 16
    let body = L.heapAt(offset: word(snap, entry))
    return (entry, body, L)
}

enum LongBytesCorruption: CaseIterable, Sendable {
    /// The back reference claims more words than the run holds.
    case lengthPastItsRun
    /// A short ByteArray's header holds the sentinel.
    case sentinelOnAShortBody
}

private func corrupted(_ c: LongBytesCorruption) throws -> (snap: [UInt8], root: RootHandle) {
    var (snap, r, _) = try snapshotWithALongByteArray()
    switch c {
    case .lengthPastItsRun:
        let (_, body, _) = try offsets(snap, root: r.index)
        let br = word(snap, body)
        putWord(&snap, body, br &+ (UInt64(4096) << 32))  // 32 KiB more than its used
    case .sentinelOnAShortBody:
        let (entry, _, _) = try offsets(snap, root: r.index + 1)
        let h = word(snap, entry + 8)
        putWord(&snap, entry + 8, h & ~Header.countMask | Header.longBytesFrom << Header.countShift)
    }
    return (snap, r)
}

@Test(arguments: LongBytesCorruption.allCases)
func theLoaderRefusesALengthThatDoesNotFit(_ c: LongBytesCorruption) throws {
    let (snap, _) = try corrupted(c)
    do {
        let m = try ObjectMemory.load(snapshot: snap, config: loadConfig())
        m.destroy()
        Issue.record("\(c) loaded")
    } catch {
        print("long bytes corruption \(c): \(error)")
    }
}

/// The broken variant: a loader that trusts a long object's length (no
/// check of the back reference against its run) loads the image, and the
/// object's length then passes the end of its run.
@Test func aLoaderThatTrustsTheLengthLetsItPassTheRun() throws {
    let (snap, r) = try corrupted(.lengthPastItsRun)
    var sw = TestSwitches()
    sw.trustLongLength = true
    let m = try ObjectMemory.load(snapshot: snap, config: loadConfig(sw))
    defer { m.destroy() }
    let b = m.root(r)
    let runBytes = UInt64(m.heap.runLength(head: m.blockIndex(of: b)) * BlockHeap.blockBytes)
    #expect(m.count(of: b) + 8 > runBytes)
}
