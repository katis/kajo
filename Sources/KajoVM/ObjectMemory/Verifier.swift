/// Verifiers: each redoes a piece of the collector's reasoning from
/// scratch and reports what disagrees. Checked builds run them at every
/// pause; release builds when `config.verify` is set. Each one has a test
/// that corrupts one thing and sees it fail (VerifierTests).
enum VerifyPhase {
    /// Outside a collection: marks clear, contexts retired.
    case idle
    /// Between mark and sweep.
    case marked(extraRoots: [Oop])
}

/// Collects issues, capped so a wrecked heap still reports quickly.
struct Issues {
    private(set) var list: [String] = []
    mutating func fail(_ s: @autoclosure () -> String) {
        if list.count < 100 { list.append(s()) }
    }
}

extension ObjectMemory {
    func verifyAtPause(_ when: String, phase: VerifyPhase) {
        guard config.verify else { return }
        switch phase {
        case .idle:
            record(when, verifyHeap() + verifyFreeLists())
        case .marked(let extraRoots):
            record(when, verifyMarks(extraRoots: extraRoots))
        }
    }

    /// Count a verifier run and its failures; trap or keep the report.
    func record(_ when: String, _ issues: [String]) {
        unsafe gc.pointee.counters.verifierRuns &+= 1
        if issues.isEmpty { return }
        unsafe gc.pointee.counters.verifierFailures &+= UInt64(issues.count)
        let report = "object memory verifier, \(when): " + issues.prefix(10).joined(separator: "; ")
        switch config.onVerifyFailure {
        case .trap: fatalError(report)
        case .record:
            // The first reports are kept (the count above has them all): a
            // long run with a failing verifier must not grow without bound.
            if unsafe gc.pointee.failures.count < 1000 { unsafe gc.pointee.failures.append(report) }
        }
    }

    var verifierReports: [String] { unsafe gc.pointee.failures }

    /// A word that may sit in a slot or a root: a valid immediate
    /// (SmallInteger, SmallFloat, Character holding a scalar; module 8) or a
    /// reference to a used entry below the high water mark. The spare
    /// patterns `1000` and `1100` are refused.
    func isValidReferenceOrInteger(_ v: Oop, highWater hw: UInt64) -> Bool {
        if v.isImmediate { return v.isValidImmediate }
        return v.isObject && v.entryIndex < hw && !EntryState.isFree(stateWord(v.raw)) && headerWord(v.raw) != 0
    }

    // MARK: - entries and blocks

    /// Every used entry leads to an aligned body at the start of a body in
    /// the walk of an in-use block, inside its used bytes, whose back
    /// reference and size agree with the entry; headers use no reserved bit
    /// and name a registered class; every slot and root is a SmallInteger
    /// or a reference to a used entry; free entries have a zero header; no
    /// mark is set outside a collection; every in-use block walks exactly
    /// to its used bytes and every free block has none. Contexts retired.
    func verifyHeap() -> [String] {
        var out = Issues()
        let hw = highWater
        let h = heap
        let blockBytes = UInt64(BlockHeap.blockBytes)
        let heapBytes = UInt64(h.bytes)

        let ct = unsafe gc.pointee.classTable
        for i in 1..<ct.count where ct[i] != 0 && !isValidReferenceOrInteger(Oop(raw: ct[i]), highWater: hw) {
            out.fail("class table \(i) holds \(Oop(raw: ct[i]))")
        }
        let rs = unsafe gc.pointee.roots
        for i in 0..<rs.count where rs[i] != 0 && !isValidReferenceOrInteger(Oop(raw: rs[i]), highWater: hw) {
            out.fail("root \(i) holds \(Oop(raw: rs[i]))")
        }
        forEachFinalized { v in
            if !isValidReferenceOrInteger(v, highWater: hw) { out.fail("the finalization queue (a root) holds \(v)") }
        }
        let nilObj = unsafe gc.pointee.nilObject
        if nilObj != .none && !isValidReferenceOrInteger(nilObj, highWater: hw) { out.fail("the nil object (a root) is \(nilObj)") }
        let nursery = nurseryRegion

        var seen = RawArray<UInt8>(repeating: 0, count: Int(hw))
        defer { seen.free() }
        // Module 10: a run is walked as its one body (`verifyRun`); a
        // continuation outside a run, a free block with a kind, an entry
        // into a continuation are refused.
        let runBlind = isRunBlind(.verifier)
        var b = 0
        while b < h.blockCount {
            defer { b += 1 }
            let used = h.usedBytes(b)
            if !h.isInUse(b) {
                if used != 0 { out.fail("free block \(b) has \(used) used bytes") }
                if h.kind(b) != BlockKind.ordinary && !runBlind { out.fail("free block \(b) has kind \(h.kind(b))") }
                continue
            }
            if !runBlind && h.kind(b) != BlockKind.ordinary {
                if h.kind(b) != BlockKind.head {
                    out.fail("block \(b) is a continuation of no run")
                    continue
                }
                b += verifyRun(head: b, highWater: hw, seen: &seen, &out) - 1
                continue
            }
            if used > blockBytes || used & 7 != 0 {
                out.fail("block \(b) has an invalid used count \(used)")
                continue
            }
            let start = BlockHeap.start(ofBlock: b)
            let end = start &+ used
            var off = start
            while off < end {
                let w = h.word(atOffset: off)
                let words = BackRef.words(w)
                if words == 0 || words > (end &- off) &>> 3 {
                    out.fail("block \(b): walk breaks at offset \(off), body of \(words) words runs past used \(used)")
                    break
                }
                let idx = BackRef.entryIndex(w)
                if idx != 0, idx < hw, stateWord(idx &<< 4) == off { seen[Int(idx)] &+= 1 }
                off &+= words &<< 3
            }
        }

        // The old map (module 5's snapshot source): exactly the used
        // entries with an old header, nothing at or above the high water.
        let old = oldMap
        var e: UInt64 = 1
        while e < hw {
            let raw = e &<< 4
            let isOld = !EntryState.isFree(stateWord(raw)) && headerWord(raw) & Header.youngBit == 0
            if old.contains(e) != isOld { out.fail("entry \(e): old map says \(old.contains(e)), the entry is \(isOld ? "old" : "not old")") }
            e &+= 1
        }
        let hwWord = Int(truncatingIfNeeded: hw &>> 6)
        if hwWord < old.wordCount && old.word(hwWord) &>> (hw & 63) != 0 { out.fail("the old map has bits at or above the high water") }

        let marking = unsafe gc.pointee.markingActive
        e = 1
        while e < hw {
            defer { e &+= 1 }
            let raw = e &<< 4
            let s = stateWord(raw)
            let hd = Header(raw: headerWord(raw))
            if markByte(e) != 0 && !marking { out.fail("entry \(e) has its mark set outside a collection") }
            if EntryState.isFree(s) {
                if hd.raw != 0 { out.fail("free entry \(e) has header 0x\(String(hd.raw, radix: 16))") }
                continue
            }
            if s & EntryState.relocatingBit != 0 { out.fail("entry \(e) is RELOCATING"); continue }
            if s & 7 != 0 { out.fail("entry \(e): body offset \(s) is not aligned"); continue }
            if hd.reservedBits != 0 { out.fail("entry \(e): header has reserved bits 0x\(String(hd.reservedBits, radix: 16))") }
            if !hd.isYoung && hd.raw & Header.youngOnlyMask != 0 {
                out.fail("entry \(e): an old header with young-only bits 0x\(String(hd.raw & Header.youngOnlyMask, radix: 16))")
            }
            // Module 7: a deferred entry free is used and dead; its body
            // may be reused (every verifier skips it by the header bit).
            if hd.isDeferredFree {
                if !hd.isYoung { out.fail("entry \(e): a deferred entry free with an old header") }
                continue
            }
            if hd.isYoung {
                // Module 4's nursery verifier checks where in its nursery;
                // here only that a young body is in the nursery region and
                // is a well-formed body of this entry.
                if !nursery.contains(s) || !nursery.contains(s &+ hd.bodyBytes &- 1) {
                    out.fail("entry \(e): a young body at \(s) is outside the nursery region")
                    continue
                }
                if !isRegisteredClass(hd.classIndex) { out.fail("entry \(e): class index \(hd.classIndex) is not registered") }
                let br = h.word(atOffset: s)
                if BackRef.entryIndex(br) != e || BackRef.words(br) != hd.bodyWords {
                    out.fail("entry \(e): the young body's back reference or size disagrees")
                    continue
                }
                if !hd.isBytes {
                    for i in 0..<hd.count {
                        let v = Oop(raw: h.word(atOffset: s &+ 8 &+ i &<< 3))
                        if !isValidReferenceOrInteger(v, highWater: hw) { out.fail("entry \(e) slot \(i) holds \(v)") }
                    }
                }
                continue
            }
            // Module 6: a pending-dead entry's body may lie in a block the
            // relocator evacuated and freed (it moved only the live ones);
            // the lazy sweep frees the entry.
            if isPendingDead(e) { continue }
            if s >= heapBytes { out.fail("entry \(e): body offset \(s) is outside the heap"); continue }
            let b = BlockHeap.block(ofOffset: s)
            if !h.isInUse(b) { out.fail("entry \(e): body in block \(b), which is not in use"); continue }
            if !runBlind {
                // Module 10: a large body starts a run, an ordinary one an
                // ordinary block; nothing points into a continuation.
                if h.kind(b) == BlockKind.continuation {
                    out.fail("entry \(e): body at \(s) points into a continuation of a run (block \(b))")
                    continue
                }
                if hd.isLarge != (h.kind(b) == BlockKind.head) {
                    out.fail("entry \(e): a body of \(hd.bodyBytes) bytes in a block of kind \(h.kind(b))")
                    continue
                }
            }
            if !isRegisteredClass(hd.classIndex) { out.fail("entry \(e): class index \(hd.classIndex) is not registered") }
            if s &+ hd.bodyBytes > BlockHeap.start(ofBlock: b) &+ h.usedBytes(b) {
                out.fail("entry \(e): body at \(s) of \(hd.bodyBytes) bytes is outside block \(b)'s used bytes")
                continue
            }
            let br = h.word(atOffset: s)
            if BackRef.entryIndex(br) != e {
                out.fail("entry \(e): the body's back reference names entry \(BackRef.entryIndex(br))")
                continue
            }
            if BackRef.words(br) != hd.bodyWords {
                out.fail("entry \(e): body size \(BackRef.words(br)) words, header says \(hd.bodyWords)")
                continue
            }
            if seen[Int(e)] != 1 { out.fail("entry \(e): offset \(s) is not the start of a body in block \(b)'s walk") }
            if hd.isBytes { continue }
            for i in 0..<hd.count {
                let v = Oop(raw: h.word(atOffset: s &+ 8 &+ i &<< 3))
                if !isValidReferenceOrInteger(v, highWater: hw) { out.fail("entry \(e) slot \(i) holds \(v)") }
            }
        }
        return out.list
    }

    /// Module 10: the run whose head is `b`: its `used` a large body's
    /// bytes, each later block of it in use, a continuation with `used` 0,
    /// inside the heap; one body exactly as long as `used`, starting at the
    /// head. Answers the run's blocks (1 when it is too broken to walk).
    private func verifyRun(head b: Int, highWater hw: UInt64, seen: inout RawArray<UInt8>, _ out: inout Issues) -> Int {
        let h = heap
        let used = h.usedBytes(b)
        if used <= UInt64(BlockHeap.blockBytes) || used & 7 != 0 {
            out.fail("run at block \(b) has an invalid used count \(used)")
            return 1
        }
        let k = h.runLength(head: b)
        if b &+ k > h.blockCount {
            out.fail("run at block \(b) of \(k) blocks runs past the heap")
            return 1
        }
        for r in (b &+ 1)..<(b &+ k) {
            if !h.isInUse(r) || h.kind(r) != BlockKind.continuation || h.usedBytes(r) != 0 {
                out.fail("run at block \(b): block \(r) is not a continuation in use with no used bytes")
                return 1
            }
        }
        if b &+ k < h.blockCount && h.isInUse(b &+ k) && h.kind(b &+ k) == BlockKind.continuation {
            out.fail("run at block \(b): block \(b &+ k) continues past the run's \(k) blocks")
        }
        let start = BlockHeap.start(ofBlock: b)
        let w = h.word(atOffset: start)
        if BackRef.words(w) &<< 3 != used {
            out.fail("run at block \(b): its body of \(BackRef.words(w)) words is not its used \(used)")
            return k
        }
        let idx = BackRef.entryIndex(w)
        if idx != 0, idx < hw, stateWord(idx &<< 4) == start { seen[Int(idx)] &+= 1 }
        return k
    }

    // MARK: - free lists and the block pool

    /// Every free entry is in exactly one free list (a pool run or a
    /// context's private list) and every list holds only free entries: an
    /// entry has exactly one owner, the lesson of concurrent-young's
    /// deferred frees. Every free block is in the pool once; an in-use
    /// block is in the pool only with a usable tail.
    func verifyFreeLists() -> [String] {
        var out = Issues()
        let hw = highWater
        let h = heap
        var visited = RawArray<UInt8>(repeating: 0, count: Int(hw))
        defer { visited.free() }

        func walk(_ head: UInt64, _ name: String) {
            var e = head
            while e != 0 {
                let idx = e &>> 4
                if e & 15 != 0 || idx == 0 || idx >= hw {
                    out.fail("\(name): next \(e) is outside the table's used range")
                    return
                }
                if visited[Int(idx)] != 0 {
                    out.fail("entry \(idx) is twice in the free lists (\(name))")
                    return
                }
                visited[Int(idx)] = 1
                let s = stateWord(e)
                if !EntryState.isFree(s) {
                    out.fail("used entry \(idx) is in a free list (\(name))")
                    return
                }
                e = s & EntryState.nextMask
            }
        }

        lockPools()
        let runs = unsafe pools.pointee.entryRuns
        var heads: [(UInt64, String)] = []
        for i in 0..<runs.count { heads.append((runs[i], "run \(i)")) }
        let contexts = unsafe pools.pointee.contexts
        for i in unsafe 0..<contexts.count { unsafe heads.append((contexts[i].pointee.freeEntry, "context \(i)")) }
        var stashed: [(UInt64, String)] = []
        let stashes = unsafe pools.pointee.stashes
        for i in unsafe 0..<stashes.count {
            let st = unsafe stashes[i].pointee
            for k in unsafe st.next..<st.count { unsafe stashed.append((UInt64(st.base.unsafelyUnwrapped[k]), "stash \(i)")) }
        }
        let pending = unsafe pools.pointee.pendingRuns
        for i in 0..<pending.count { heads.append((pending[i], "pending run \(i)")) }
        let pool = unsafe pools.pointee.freeBlocks.toArray()
        unlockPools()

        for (head, name) in heads { walk(head, name) }
        for (idx, name) in stashed {
            if idx == 0 || idx >= hw { out.fail("\(name) holds entry \(idx), outside the table's used range"); continue }
            if visited[Int(idx)] != 0 { out.fail("entry \(idx) is twice in the free lists (\(name))"); continue }
            visited[Int(idx)] = 1
            if !EntryState.isFree(stateWord(idx &<< 4)) { out.fail("used entry \(idx) is in a free list (\(name))") }
        }
        var e: UInt64 = 1
        while e < hw {
            if EntryState.isFree(stateWord(e &<< 4)) && visited[Int(e)] == 0 {
                out.fail("free entry \(e) is in no free list")
            }
            e &+= 1
        }

        var inPool = RawArray<UInt8>(repeating: 0, count: h.blockCount)
        defer { inPool.free() }
        for b32 in pool {
            let b = Int(b32)
            if b >= h.blockCount { out.fail("pool holds block \(b) beyond the heap"); continue }
            if inPool[b] != 0 { out.fail("block \(b) is twice in the pool") }
            inPool[b] = 1
            if h.isRun(b) {
                out.fail("block \(b) of a run is in the pool")
                continue
            }
            if h.isInUse(b) && UInt64(BlockHeap.blockBytes) &- h.usedBytes(b) < ObjectMemory.minimumTail {
                out.fail("block \(b) is in the pool, in use with no tail")
            }
        }
        for b in 0..<h.blockCount where !h.isInUse(b) && inPool[b] == 0 {
            out.fail("free block \(b) is not in the pool")
        }
        return out.list
    }

    // MARK: - marks

    /// Reachability from scratch against the collector's mark map: every
    /// reachable entry is marked and every marked entry is reachable.
    func verifyMarks(extraRoots: [Oop]) -> [String] {
        var out = Issues()
        let hw = highWater
        var reached = RawArray<UInt8>(repeating: 0, count: Int(hw))
        var stack = RawArray<UInt64>()
        defer { reached.free(); stack.free() }
        func visit(_ v: Oop, from: String) {
            if v.isImmediate && v.isValidImmediate || v == .none { return }
            if !isValidReferenceOrInteger(v, highWater: hw) {
                out.fail("\(from) holds \(v), not a used entry")
                return
            }
            if reached[Int(v.entryIndex)] != 0 { return }
            reached[Int(v.entryIndex)] = 1
            stack.append(v.raw)
        }
        forEachRoot(extraRoots: extraRoots) { visit($0, from: "a root") }
        // Weak slots are not edges; an unfired ephemeron's slots are edges
        // only once its key is reached (ADR 0009 section 1).
        var pending: [Oop] = []
        while true {
            while let raw = stack.popLast() {
                let o = Oop(raw: raw)
                let hd = header(o)
                if hd.isBytes { continue }
                let f = classFormat(hd.classIndex)
                var n = Int(hd.count)
                if f.isWeak { n = Swift.min(n, f.namedSlots) }
                if f.isEphemeron && !hd.isFiredEphemeron && n > 0 {
                    let key = load(o, 0)
                    if key.isObject && isValidReferenceOrInteger(key, highWater: hw) && reached[Int(key.entryIndex)] == 0 {
                        pending.append(o)
                        continue
                    }
                }
                for i in 0..<n { visit(load(o, i), from: "entry \(o.entryIndex) slot \(i)") }
            }
            let ready = pending.filter { reached[Int(load($0, 0).entryIndex)] != 0 }
            if ready.isEmpty { break }
            pending.removeAll { reached[Int(load($0, 0).entryIndex)] != 0 }
            for o in ready { for i in 0..<Int(header(o).count) { visit(load(o, i), from: "entry \(o.entryIndex) slot \(i)") } }
        }
        var e: UInt64 = 1
        while e < hw {
            let m = markByte(e) != 0
            let r = reached[Int(e)] != 0
            if r && !m { out.fail("entry \(e) is reachable but not marked") }
            if m && !r { out.fail("entry \(e) is marked but not reachable") }
            e &+= 1
        }
        return out.list
    }
}
