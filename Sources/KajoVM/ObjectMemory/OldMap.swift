import Darwin
import Synchronization

// What the object memory keeps for module 5's concurrent marking
// (docs/modules/concurrent-marking.md "Layouts"):
//
// - the **old map**: one bit per entry beside the table, set exactly while
//   the entry holds an old object. A marking snapshot is a copy of its words
//   below the high water mark (O(table words), never O(entries)). Set when
//   an entry becomes old: an old allocation (`place`, one relaxed
//   `fetch_or`) and a promotion (module 4's entry sweep, one `fetch_or` per
//   word of promoted entries, outside the copy loop); cleared when an old
//   entry is freed: module 1's sweep rebuilds it, become-forward clears its
//   sources, the lazy sweep clears its dead entries (`fetch_and`, release).
//   Young entries are never in it, so neither the marker nor the barrier
//   needs a young header to decide membership.
// - **mark bytes as atomics**: module 1 marks with plain bytes at a stop;
//   the concurrent marker and the barrier read and write the same bytes
//   with relaxed atomics between stops. One map, one invariant: outside a
//   collection every byte is zero.
// - **pending runs**: free-entry runs a lazy sweep produced, free in the
//   table and owned by this list until the next pause publishes them.
// - **block stamps**: the cycle stamp of the last refill of each block, so
//   a lazy sweep frees only blocks no allocator took after its snapshot.
// - **pending dead**: while a lazy sweep is pending, the verifiers skip
//   used entries of its snapshot that are unmarked (dead, not yet freed:
//   their slots may name entries the sweep already freed).

/// The old map, the snapshot map's source. Words of 64 entries.
@safe struct EntryBitmap {
    let words: UnsafeMutablePointer<Atomic<UInt64>>
    let wordCount: Int

    /// A zero-filled reservation for `entries` bits.
    init(entries: UInt64, probe: ReservationProbe? = nil) throws(ObjectMemoryError) {
        wordCount = Int((entries &+ 63) &>> 6)
        let raw = try unsafe VirtualMemory.reserve(EntryBitmap.bytes(wordCount), probe: probe)
        unsafe words = raw.bindMemory(to: Atomic<UInt64>.self, capacity: wordCount)
    }

    static func bytes(_ words: Int) -> Int { (words &* 8 &+ 16383) & ~16383 }

    func release(probe: ReservationProbe? = nil) {
        unsafe VirtualMemory.release(UnsafeMutableRawPointer(words), EntryBitmap.bytes(wordCount), probe: probe)
    }

    @inline(__always)
    func word(_ w: Int) -> UInt64 { unsafe words[w].load(ordering: .relaxed) }

    @inline(__always)
    func setWord(_ w: Int, _ v: UInt64) { unsafe words[w].store(v, ordering: .relaxed) }

    @inline(__always)
    func contains(_ e: UInt64) -> Bool {
        unsafe words[Int(truncatingIfNeeded: e &>> 6)].load(ordering: .relaxed) & (1 &<< (e & 63)) != 0
    }

    @inline(__always)
    func insert(_ e: UInt64) {
        unsafe words[Int(truncatingIfNeeded: e &>> 6)].bitwiseOr(1 &<< (e & 63), ordering: .relaxed)
    }

    @inline(__always)
    func insert(word w: Int, bits: UInt64) {
        unsafe words[w].bitwiseOr(bits, ordering: .relaxed)
    }

    /// Release: an allocator that takes one of these entries after the
    /// pause that publishes it sees everything the sweep wrote before.
    @inline(__always)
    func remove(word w: Int, bits: UInt64) {
        unsafe words[w].bitwiseAnd(~bits, ordering: .releasing)
    }

    @inline(__always)
    func remove(_ e: UInt64) { remove(word: Int(truncatingIfNeeded: e &>> 6), bits: 1 &<< (e & 63)) }
}

extension ObjectMemory {
    var oldMap: EntryBitmap { unsafe shared.pointee.oldMap }

    /// Rebuild the old map from the table: used entries with an old header.
    /// World stopped.
    func rebuildOldMap() {
        let hw = highWater
        let map = oldMap
        let words = Int((hw &+ 63) &>> 6)
        for w in 0..<words {
            var bits: UInt64 = 0
            var e = UInt64(w) &<< 6
            let end = Swift.min(e &+ 64, hw)
            if e == 0 { e = 1 }
            while e < end {
                let raw = e &<< 4
                if !EntryState.isFree(stateWord(raw)) && headerWord(raw) & Header.youngBit == 0 { bits |= 1 &<< (e & 63) }
                e &+= 1
            }
            map.setWord(w, bits)
        }
    }

    // MARK: - the mark map as atomics

    /// A mark byte, as the concurrent marker and the barrier read it.
    @inline(__always)
    func markAtomic(_ index: UInt64) -> UnsafeMutablePointer<Atomic<UInt8>> {
        unsafe UnsafeMutableRawPointer(shared.pointee.marks).advanced(by: Int(truncatingIfNeeded: index))
            .assumingMemoryBound(to: Atomic<UInt8>.self)
    }

    /// A mark byte read with a relaxed atomic load (module 5's marker and
    /// barrier, between stops).
    @inline(__always)
    func markRelaxed(_ index: UInt64) -> UInt8 { unsafe markAtomic(index).pointee.load(ordering: .relaxed) }

    /// A mark byte written with a relaxed atomic store (one marker
    /// participant at a time writes marks).
    @inline(__always)
    func setMarkRelaxed(_ index: UInt64, _ v: UInt8) { unsafe markAtomic(index).pointee.store(v, ordering: .relaxed) }

    // MARK: - pending runs and block stamps (module 5's lazy sweep)

    /// A run of free entries (state words already free and linked) that a
    /// lazy sweep produced: owned by the pending list until `publishPendingRuns`.
    func addPendingRun(_ head: UInt64) {
        lockPools()
        unsafe pools.pointee.pendingRuns.append(head)
        unlockPools()
    }

    /// Hand every pending run to the allocators. A pause.
    func publishPendingRuns() -> Int {
        lockPools()
        defer { unlockPools() }
        let n = unsafe pools.pointee.pendingRuns.count
        for i in 0..<n { unsafe pools.pointee.entryRuns.append(pools.pointee.pendingRuns[i]) }
        unsafe pools.pointee.pendingRuns.removeAll()
        return n
    }

    /// Stamp every block refilled from now on with `stamp` (a cycle's
    /// snapshot). World stopped.
    func setBlockStamp(_ stamp: UInt32) {
        lockPools()
        unsafe pools.pointee.stampNow = stamp
        unlockPools()
    }

    /// A concurrent marking cycle owns the mark map from its initial mark to
    /// its apply (or abort): marks may be set between stops. World stopped.
    func setMarkingActive(_ on: Bool) { unsafe gc.pointee.markingActive = on }

    /// Clear the mark bytes of every entry below the high water mark (an
    /// abandoned cycle). World stopped.
    func clearMarks() { unsafe memset(shared.pointee.marks, 0, Int(highWater)) }

    /// Free every in-use block with no live body (`live[b] == 0`) that no
    /// allocator took after the snapshot stamped `stamp`. Contexts retired;
    /// `rebuildBlockPool` after. World stopped. Answers the blocks freed.
    /// Module 10: a run goes with its head (`live` counts a body in the
    /// block it starts in), never a continuation alone; a run taken after
    /// the snapshot carries the stamp in every block.
    func freeDeadBlocks(live: RawArray<UInt8>, stamp: UInt32) -> Int {
        let h = heap
        let blind = isRunBlind(.lazySweep)
        var runs: UInt64 = 0
        lockPools()
        var freed = 0
        for b in 0..<Swift.min(h.blockCount, live.count) where h.isInUse(b) && live[b] == 0 {
            if unsafe pools.pointee.blockStamps[b] == stamp { continue }
            freed &+= freeBlockWithoutLiveBody(b, blind: blind, runs: &runs)
        }
        unsafe pools.pointee.runsFreed &+= runs
        unlockPools()
        return freed
    }

    /// Queue `e` for finalization: fired (strong from now on), appended to
    /// the queue, the Semaphore due a signal. World stopped.
    func queueForFinalization(_ e: Oop) {
        var h = header(e)
        h.isFiredEphemeron = true
        setHeader(e, h)
        lockPools()
        unsafe shared.pointee.finalization.pointee.append(e.raw)
        unlockPools()
        unsafe gc.pointee.finalizationSignal = true
    }

    /// While a lazy sweep is pending the verifiers skip its pending-dead
    /// entries: used, in `snapshot`, mark byte clear. nil when none is.
    /// World stopped.
    func setPendingDead(_ snapshot: EntryBitmap?) {
        unsafe gc.pointee.pendingDead = snapshot
    }

    /// A used entry a pending lazy sweep will free (its slots may name
    /// entries already freed). World stopped.
    func isPendingDead(_ e: UInt64) -> Bool {
        guard let s = unsafe gc.pointee.pendingDead else { return false }
        return s.contains(e) && markByte(e) == 0
    }
}
