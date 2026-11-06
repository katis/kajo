import Darwin
import Foundation

/// Snapshot format, version 5 (module 4 added the class formats, the
/// finalization queue and the nil object; module 8 the format word's kind,
/// sealed and behaviors fields and the immediates SmallFloat and Character
/// in slots; module 10 the block kinds of large objects' runs; large bytes
/// the long byte objects, whose header's count from 2^24 - 8 on is a
/// sentinel and whose length is their back reference's words; versions 1
/// to 4 are refused: a version 4 byte object of 16 777 208 to 16 777 215
/// bytes would read as a long one).
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
///     B words  per block: bits 0..55 used bytes (0 = free, or a
///              continuation), bits 56..63 the block's kind (module 10:
///              0 ordinary, 1 the head of a run, 2 a continuation); a
///              head's used bytes are its large body's, past the block
///     ...      the used bytes of every block, in block order (a head's
///              are the whole run's body, contiguous in the heap)
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
        case .unsupportedVersion(let v): "unsupported snapshot version \(v)" + (v < SnapshotLayout.version ? " (made before the large-bytes follow-up's long byte objects)" : "")
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
    static let version: UInt64 = 5
    /// Module 10: where a block's kind sits in its used word.
    static let kindShift: UInt64 = 56
    static let usedMask: UInt64 = (1 << 56) - 1
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
    /// Module 10: each block's kind (`BlockKind`).
    let kinds: [UInt8]
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
        var kinds: [UInt8] = []
        var blockAt: [Int] = []
        var at = heapAt
        // Module 10: a head's run of continuations, counted down.
        var continuations = 0
        for i in 0..<blockCount {
            let w = SnapshotLayout.word(b, usedAt + i * 8)
            let u = w & SnapshotLayout.usedMask
            let kind = w &>> SnapshotLayout.kindShift
            guard u & 7 == 0 else { throw .malformed("block \(i) used \(u)") }
            switch kind {
            case UInt64(BlockKind.ordinary):
                guard continuations == 0 else { throw .malformed("block \(i) is not a continuation of the run before it") }
                guard u <= UInt64(BlockHeap.blockBytes) else { throw .malformed("block \(i) used \(u)") }
            case UInt64(BlockKind.head):
                guard continuations == 0 else { throw .malformed("block \(i) is not a continuation of the run before it") }
                let k = UInt64(blockCount - i)
                guard u > UInt64(BlockHeap.blockBytes), u <= k &* UInt64(BlockHeap.blockBytes),
                      u <= UInt64(b.count) else { throw .malformed("run at block \(i) used \(u)") }
                continuations = BlockHeap.runBlocks(bytes: u) - 1
            case UInt64(BlockKind.continuation):
                guard continuations > 0, u == 0 else { throw .malformed("block \(i) is a continuation of no run") }
                continuations -= 1
            default:
                throw .malformed("block \(i) has kind \(kind)")
            }
            used.append(u)
            kinds.append(UInt8(kind))
            blockAt.append(at)
            at += Int(u)
            guard at <= b.count else { throw .malformed("length \(b.count) is shorter than block \(i)'s bytes") }
        }
        guard continuations == 0 else { throw .malformed("the last run is cut short") }
        self.used = used
        self.kinds = kinds
        self.blockAt = blockAt
        tableAt = at
        let expected = UInt64(at) + highWater * 16
        guard expected == UInt64(b.count) else { throw .malformed("length \(b.count), sections need \(expected)") }
    }

    /// File position of a heap offset inside a saved block (module 10: an
    /// offset in a continuation is in its head's bytes).
    func heapAt(offset: UInt64) -> Int {
        var b = BlockHeap.block(ofOffset: offset)
        while b > 0 && kinds[b] == BlockKind.continuation { b -= 1 }
        return blockAt[b] + Int(offset - BlockHeap.start(ofBlock: b))
    }
}

extension ObjectMemory {
    // MARK: - save

    /// The whole object memory as snapshot bytes. World stopped. A host
    /// caller: old space must be able to take every young object.
    func snapshot() -> [UInt8] {
        guard let s = trySnapshot() else {
            preconditionFailure("kajo: snapshot: old space cannot take every young object (the heap is full of live data)")
        }
        return s
    }

    /// As `snapshot`, or nil when young objects are left that old space
    /// could not take (the promotion reserve's fallback kept them): an
    /// image holds no young object.
    func trySnapshot() -> [UInt8]? {
        if !prepareOldSpaceOperation(nil).isEmpty { return nil }
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
        let kinds = !isRunBlind(.snapshot)
        for b in 0..<blockCount { put(h.usedBytes(b) | (kinds ? UInt64(h.kind(b)) &<< SnapshotLayout.kindShift : 0)) }
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
        guard L.highWater <= UInt64(c.entryCapacity) else {
            throw .doesNotFit("high water \(L.highWater), table of \(c.entryCapacity)")
        }
        guard L.classCount - 1 <= Int(Header.maxClassIndex) else { throw .malformed("class table length \(L.classCount)") }
        let om: ObjectMemory
        do { om = try ObjectMemory(config) } catch { throw .doesNotFit("\(error)") }
        // Module 10: the reservation's blocks, the final collection's
        // growth included (an image saved after the VM's end may use it).
        guard L.blockCount <= om.heap.blockCount else {
            om.destroy()
            throw .doesNotFit("\(L.blockCount) blocks, heap of \(om.heap.blockCount)")
        }
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
        // Module 8b: the nil object is a root (the image boot registers it);
        // one no root holds would be swept by the next collection while
        // the memory still names it (the snapshot fuzzer's third crash).
        if L.nilObject != 0 && !(0..<L.rootCount).contains(where: { SnapshotLayout.word(b, L.rootsAt + $0 * 8) == L.nilObject }) {
            throw .malformed("the nil object is not a root")
        }
        let h = heap
        lockPools()
        unsafe pools.pointee.highWater = L.highWater
        unlockPools()
        b.withUnsafeBytes { src in
            for i in 0..<L.blockCount where L.used[i] > 0 || L.kinds[i] != BlockKind.ordinary {
                // A head's bytes are its whole run (the layout checked that
                // the run's blocks follow it inside the snapshot's blocks).
                unsafe memcpy(heapBase + Int(BlockHeap.start(ofBlock: i)), src.baseAddress.unsafelyUnwrapped + L.blockAt[i],
                              Int(L.used[i]))
                h.setUsed(i, L.used[i])
                h.setInUse(i, true)
                h.setKind(i, L.kinds[i])
            }
            unsafe memcpy(table, src.baseAddress.unsafelyUnwrapped + L.tableAt, Int(L.highWater) * 16)
        }
        guard stateWord(0) == 0, headerWord(0) == 0 else { throw .malformed("entry 0 is not empty") }
        var issues = Issues()
        var e: UInt64 = 1
        while e < L.highWater {
            if !EntryState.isFree(stateWord(e &<< 4)) {
                let hd = Header(raw: headerWord(e &<< 4))
                if hd.isFramePinned { issues.fail("entry \(e) carries a frame pin") }
                // A snapshot follows a promote-all: no young header, no
                // deferred entry free. The heap verifier skips a deferred
                // free's body (it may be reused), so one here would hide a
                // body offset outside the heap from it and the marker would
                // read it (the snapshot fuzzer found that with one bit).
                if hd.isYoung || hd.isDeferredFree {
                    issues.fail("entry \(e) is young or a deferred free (header 0x\(String(hd.raw, radix: 16)))")
                }
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
