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
        case .record: unsafe gc.pointee.failures.append(report)
        }
    }

    var verifierReports: [String] { unsafe gc.pointee.failures }

    /// A word that may sit in a slot or a root: a SmallInteger or a
    /// reference to a used entry below the high water mark.
    func isValidReferenceOrInteger(_ v: Oop, highWater hw: UInt64) -> Bool {
        if v.isSmallInteger { return true }
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

        var seen = RawArray<UInt8>(repeating: 0, count: Int(hw))
        defer { seen.free() }
        for b in 0..<h.blockCount {
            let used = h.usedBytes(b)
            if !h.isInUse(b) {
                if used != 0 { out.fail("free block \(b) has \(used) used bytes") }
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

        let marks = unsafe shared.pointee.marks
        var e: UInt64 = 1
        while e < hw {
            defer { e &+= 1 }
            let raw = e &<< 4
            let s = stateWord(raw)
            let hd = Header(raw: headerWord(raw))
            if unsafe marks[Int(e)] != 0 { out.fail("entry \(e) has its mark set outside a collection") }
            if EntryState.isFree(s) {
                if hd.raw != 0 { out.fail("free entry \(e) has header 0x\(String(hd.raw, radix: 16))") }
                continue
            }
            if s & EntryState.relocatingBit != 0 { out.fail("entry \(e) is RELOCATING"); continue }
            if s & 7 != 0 { out.fail("entry \(e): body offset \(s) is not aligned"); continue }
            if s >= heapBytes { out.fail("entry \(e): body offset \(s) is outside the heap"); continue }
            let b = BlockHeap.block(ofOffset: s)
            if !h.isInUse(b) { out.fail("entry \(e): body in block \(b), which is not in use"); continue }
            if hd.reservedBits != 0 { out.fail("entry \(e): header has reserved bits 0x\(String(hd.reservedBits, radix: 16))") }
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
        let pool = unsafe pools.pointee.freeBlocks.toArray()
        unlockPools()

        for (head, name) in heads { walk(head, name) }
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
            if v.isSmallInteger || v == .none { return }
            if !isValidReferenceOrInteger(v, highWater: hw) {
                out.fail("\(from) holds \(v), not a used entry")
                return
            }
            if reached[Int(v.entryIndex)] != 0 { return }
            reached[Int(v.entryIndex)] = 1
            stack.append(v.raw)
        }
        forEachRoot(extraRoots: extraRoots) { visit($0, from: "a root") }
        while let raw = stack.popLast() {
            let o = Oop(raw: raw)
            let hd = header(o)
            if hd.isBytes { continue }
            for i in 0..<Int(hd.count) { visit(load(o, i), from: "entry \(o.entryIndex) slot \(i)") }
        }
        let marks = unsafe shared.pointee.marks
        var e: UInt64 = 1
        while e < hw {
            let m = unsafe marks[Int(e)] != 0
            let r = reached[Int(e)] != 0
            if r && !m { out.fail("entry \(e) is reachable but not marked") }
            if m && !r { out.fail("entry \(e) is marked but not reachable") }
            e &+= 1
        }
        return out.list
    }
}
