import Darwin
import Foundation

/// Snapshot format, version 3 (module 4 added the class formats, the
/// finalization queue and the nil object; module 8 the format word's kind,
/// sealed and behaviors fields and the immediates SmallFloat and Character
/// in slots; versions 1 and 2 are refused).
/// Little-endian 64-bit words, then raw heap and table bytes (the hosts are
/// little-endian):
///
///     word 0   magic "KAJOOM\0\0"
///     word 1   version
///     word 2   block size
///     word 3   block count B (last in-use block + 1)
///     word 4   entry high water mark H
///     word 5   class table length C (index 0 included, always 0)
///     word 6   root registry length R (0 = removed slot)
///     word 7   finalization queue length Q
///     word 8   the nil object weak slots become (0: none)
///     C words  class table
///     C words  class formats (`ClassFormat`)
///     R words  root registry
///     Q words  finalization queue
///     B words  used bytes per block (0 = free)
///     ...      the used bytes of every block, in block order
///     H x 16   entry table [0, H)
///
/// Oops are entry offsets, so a snapshot loads at any base with no
/// relocation (ADR 0003). The loader trusts nothing: it checks the
/// geometry, then every entry, block, slot and root invariant with the
/// heap verifier (nothing may be young: a snapshot follows a promote-all),
/// then rebuilds the free lists. Frame pins are dropped on
/// save; free entries' links are rebuilt on load.
enum SnapshotError: Error, Equatable, CustomStringConvertible {
    case badMagic
    case unsupportedVersion(UInt64)
    case malformed(String)
    case doesNotFit(String)
    case invariant([String])
    case io(String)

    var description: String {
        switch self {
        case .badMagic: "not a Kajo object memory snapshot (bad magic)"
        case .unsupportedVersion(let v): "unsupported snapshot version \(v)"
        case .malformed(let s): "malformed snapshot: \(s)"
        case .doesNotFit(let s): "snapshot does not fit the configuration: \(s)"
        case .invariant(let issues): "snapshot breaks invariants: " + issues.prefix(10).joined(separator: "; ")
        case .io(let s): "snapshot I/O: \(s)"
        }
    }
}

/// Where everything is in a snapshot, with the geometry checked. Reading it
/// touches only the bytes given, with bounds checks: no unsafe code.
struct SnapshotLayout {
    static let magic: UInt64 = 0x0000_4D4F_4F4A_414B // "KAJOOM\0\0"
    static let version: UInt64 = 3
    static let headerWords = 9

    let blockCount: Int
    let highWater: UInt64
    let classCount: Int
    let rootCount: Int
    let queueCount: Int
    let nilObject: UInt64
    let classTableAt: Int
    let formatsAt: Int
    let rootsAt: Int
    let queueAt: Int
    let usedAt: Int
    let used: [UInt64]
    /// File position of each block's bytes.
    let blockAt: [Int]
    let tableAt: Int

    static func word(_ b: [UInt8], _ at: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(b[at + k]) << (8 * UInt64(k)) }
        return v
    }

    init(parsing b: [UInt8]) throws(SnapshotError) {
        guard b.count >= SnapshotLayout.headerWords * 8 else { throw .malformed("length \(b.count) is shorter than the header") }
        let w = { (i: Int) in SnapshotLayout.word(b, i * 8) }
        guard w(0) == SnapshotLayout.magic else { throw .badMagic }
        guard w(1) == SnapshotLayout.version else { throw .unsupportedVersion(w(1)) }
        guard w(2) == UInt64(BlockHeap.blockBytes) else { throw .malformed("block size \(w(2))") }
        let words = UInt64(b.count / 8)
        // Every count is bounded by the length before it is used.
        guard w(3) <= words, w(5) <= words, w(6) <= words, w(7) <= words else {
            throw .malformed("a count exceeds the length \(b.count)")
        }
        guard w(4) >= 1, w(4) <= 1 << 32 else { throw .malformed("high water \(w(4))") }
        blockCount = Int(w(3))
        highWater = w(4)
        classCount = Int(w(5))
        rootCount = Int(w(6))
        queueCount = Int(w(7))
        nilObject = w(8)
        guard classCount >= 1 else { throw .malformed("class table length 0") }
        classTableAt = SnapshotLayout.headerWords * 8
        formatsAt = classTableAt + classCount * 8
        rootsAt = formatsAt + classCount * 8
        queueAt = rootsAt + rootCount * 8
        usedAt = queueAt + queueCount * 8
        let heapAt = usedAt + blockCount * 8
        guard heapAt <= b.count else { throw .malformed("length \(b.count) is shorter than the sections") }
        var used: [UInt64] = []
        var blockAt: [Int] = []
        var at = heapAt
        for i in 0..<blockCount {
            let u = SnapshotLayout.word(b, usedAt + i * 8)
            guard u <= UInt64(BlockHeap.blockBytes), u & 7 == 0 else { throw .malformed("block \(i) used \(u)") }
            used.append(u)
            blockAt.append(at)
            at += Int(u)
        }
        self.used = used
        self.blockAt = blockAt
        tableAt = at
        let expected = UInt64(at) + highWater * 16
        guard expected == UInt64(b.count) else { throw .malformed("length \(b.count), sections need \(expected)") }
    }

    /// File position of a heap offset inside a saved block.
    func heapAt(offset: UInt64) -> Int {
        let b = BlockHeap.block(ofOffset: offset)
        return blockAt[b] + Int(offset - BlockHeap.start(ofBlock: b))
    }
}

extension ObjectMemory {
    // MARK: - save

    /// The whole object memory as snapshot bytes. World stopped.
    func snapshot() -> [UInt8] {
        prepareOldSpaceOperation(nil)
        retireAllContexts()
        verifyAtPause("before snapshot", phase: .idle)
        let h = heap
        let hw = highWater
        var blockCount = 0
        for b in 0..<h.blockCount where h.isInUse(b) { blockCount = b + 1 }
        let classes = unsafe gc.pointee.classTable.toArray()
        let formats = unsafe gc.pointee.classFormats.toArray()
        let roots = unsafe gc.pointee.roots.toArray()
        var queue: [UInt64] = []
        forEachFinalized { queue.append($0.raw) }
        var size = (SnapshotLayout.headerWords + 2 * classes.count + roots.count + queue.count + blockCount) * 8
        for b in 0..<blockCount { size += Int(h.usedBytes(b)) }
        size += Int(hw) * 16
        var out = [UInt8](repeating: 0, count: size)
        var at = 0
        func put(_ v: UInt64) {
            for k in 0..<8 { out[at + k] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(k))) }
            at += 8
        }
        for v in [SnapshotLayout.magic, SnapshotLayout.version, UInt64(BlockHeap.blockBytes), UInt64(blockCount),
                  hw, UInt64(classes.count), UInt64(roots.count), UInt64(queue.count), nilObject.raw] { put(v) }
        for v in classes { put(v) }
        for v in formats { put(v) }
        for v in roots { put(v) }
        for v in queue { put(v) }
        for b in 0..<blockCount { put(h.usedBytes(b)) }
        out.withUnsafeMutableBytes { dst in
            for b in 0..<blockCount {
                let n = Int(h.usedBytes(b))
                unsafe memcpy(dst.baseAddress.unsafelyUnwrapped + at,
                              heapBase + Int(BlockHeap.start(ofBlock: b)), n)
                at += n
            }
            unsafe memcpy(dst.baseAddress.unsafelyUnwrapped + at, table, Int(hw) * 16)
        }
        let tableAt = at
        var e: UInt64 = 1
        while e < hw {
            let hd = Header(raw: headerWord(e &<< 4))
            if !EntryState.isFree(stateWord(e &<< 4)) && hd.isFramePinned {
                var stripped = hd
                stripped.isFramePinned = false
                at = tableAt + Int(e) * 16 + 8
                put(stripped.raw)
            }
            e &+= 1
        }
        unsafe gc.pointee.counters.snapshotsSaved &+= 1
        return out
    }

    func snapshot(toFile path: String) throws(SnapshotError) {
        do {
            try Data(snapshot()).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw .io("\(error)")
        }
    }

    // MARK: - load

    static func load(contentsOfFile path: String, config: ObjectMemoryConfig = .init()) throws(SnapshotError) -> ObjectMemory {
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) } catch { throw .io("\(error)") }
        return try load(snapshot: [UInt8](data), config: config)
    }

    /// A new object memory from snapshot bytes, at a new base, with no
    /// relocation. Rejects any snapshot that breaks an invariant; this is
    /// the loader's fuzz entry point.
    static func load(snapshot b: [UInt8], config: ObjectMemoryConfig = .init()) throws(SnapshotError) -> ObjectMemory {
        let L = try SnapshotLayout(parsing: b)
        let c = config.effective
        guard L.blockCount * BlockHeap.blockBytes <= c.heapBytes + c.reserveBytes else {
            throw .doesNotFit("\(L.blockCount) blocks, heap of \((c.heapBytes + c.reserveBytes) / BlockHeap.blockBytes)")
        }
        guard L.highWater <= UInt64(c.entryCapacity) else {
            throw .doesNotFit("high water \(L.highWater), table of \(c.entryCapacity)")
        }
        guard L.classCount - 1 <= Int(Header.maxClassIndex) else { throw .malformed("class table length \(L.classCount)") }
        let om: ObjectMemory
        do { om = try ObjectMemory(config) } catch { throw .doesNotFit("\(error)") }
        do {
            try om.fill(from: b, L)
        } catch {
            om.destroy()
            throw error
        }
        return om
    }

    private func fill(from b: [UInt8], _ L: SnapshotLayout) throws(SnapshotError) {
        guard SnapshotLayout.word(b, L.classTableAt) == 0 else { throw .malformed("class 0 is set") }
        let g = unsafe gc
        guard SnapshotLayout.word(b, L.formatsAt) == 0 else { throw .malformed("class 0 has a format") }
        for i in 1..<L.classCount {
            unsafe g.pointee.classTable.append(SnapshotLayout.word(b, L.classTableAt + i * 8))
            let f = SnapshotLayout.word(b, L.formatsAt + i * 8)
            let format = ClassFormat(raw: f)
            guard format.isValid,
                  !format.isSpecial || L.nilObject != 0 else { throw .malformed("class \(i) has format 0x\(String(f, radix: 16))") }
            unsafe g.pointee.classFormats.append(f)
        }
        unsafe g.pointee.nilObject = Oop(raw: L.nilObject)
        for i in 0..<L.queueCount {
            unsafe shared.pointee.finalization.pointee.append(SnapshotLayout.word(b, L.queueAt + i * 8))
        }
        for i in 0..<L.rootCount {
            let v = SnapshotLayout.word(b, L.rootsAt + i * 8)
            unsafe g.pointee.roots.append(v)
            if v == 0 { unsafe g.pointee.freeRootSlots.append(Int32(i)) }
        }
        let h = heap
        lockPools()
        unsafe pools.pointee.highWater = L.highWater
        unlockPools()
        b.withUnsafeBytes { src in
            for i in 0..<L.blockCount where L.used[i] > 0 {
                unsafe memcpy(heapBase + Int(BlockHeap.start(ofBlock: i)), src.baseAddress.unsafelyUnwrapped + L.blockAt[i],
                              Int(L.used[i]))
                h.setUsed(i, L.used[i])
                h.setInUse(i, true)
            }
            unsafe memcpy(table, src.baseAddress.unsafelyUnwrapped + L.tableAt, Int(L.highWater) * 16)
        }
        guard stateWord(0) == 0, headerWord(0) == 0 else { throw .malformed("entry 0 is not empty") }
        var issues = Issues()
        var e: UInt64 = 1
        while e < L.highWater {
            if !EntryState.isFree(stateWord(e &<< 4)), Header(raw: headerWord(e &<< 4)).isFramePinned {
                issues.fail("entry \(e) carries a frame pin")
            }
            e &+= 1
        }
        rebuildOldMap()
        let all = issues.list + verifyHeap()
        guard all.isEmpty else { throw .invariant(all) }
        var runs = RunBuilder(chunk: UInt64(config.entryChunk))
        e = 1
        while e < L.highWater {
            if EntryState.isFree(stateWord(e &<< 4)) { runs.add(e &<< 4, self) }
            e &+= 1
        }
        lockPools()
        unsafe runs.finish(into: &pools.pointee.entryRuns)
        unlockPools()
        rebuildBlockPool()
    }
}
