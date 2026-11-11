enum BecomeError: Error, Equatable {
    case notAnObject
    case lengthMismatch
    case duplicateSource
    /// A source is also a target (a chain, or an object forwarded to
    /// itself): its references would end at a freed entry.
    case sourceIsATarget
    /// Old space could not take every young object (the promotion
    /// reserve's fallback kept some young): nothing was changed.
    case heapFull
}

extension ObjectMemory {
    /// Two-way become: swap the two entries (state and header) and the two
    /// bodies' back references. No slot anywhere changes (ADR 0003). Pins
    /// are header bits and follow their body. World stopped.
    func becomeExchange(_ a: Oop, _ b: Oop) throws(BecomeError) {
        guard isUsedReference(a), isUsedReference(b) else { throw .notAnObject }
        if a == b { return }
        if !prepareOldSpaceOperation(nil).isEmpty { throw .heapFull }
        retireAllContexts()
        let sa = stateWord(a.raw), ha = headerWord(a.raw)
        let sb = stateWord(b.raw), hb = headerWord(b.raw)
        // Each body keeps its size (large bytes: a long one's is only in its
        // back reference).
        let wa = bodyWords(entry: a.raw), wb = bodyWords(entry: b.raw)
        setStateWord(a.raw, sb)
        setHeaderWord(a.raw, hb)
        setStateWord(b.raw, sa)
        setHeaderWord(b.raw, ha)
        heap.setWord(atOffset: sa, BackRef.make(entryIndex: b.entryIndex, words: wa))
        heap.setWord(atOffset: sb, BackRef.make(entryIndex: a.entryIndex, words: wb))
        unsafe gc.pointee.counters.becomes &+= 1
        verifyAtPause("after become", phase: .idle)
    }

    func becomeForward(_ from: [Oop], to: [Oop]) throws(BecomeError) {
        var none: [Oop] = []
        try becomeForward(from, to: to, extraRoots: &none)
    }

    /// One-way bulk become: every reference to `from[i]`, in any slot, the
    /// root registry, the class table or `extraRoots`, becomes a reference
    /// to `to[i]`; the sources' entries are freed and their bodies are
    /// garbage. Chains (a source that is also a target) are refused, not
    /// followed. One scan of every used entry: copying an entry over another
    /// would make two oops for one body and break identity
    /// (experiments/object-representation SPEC, "Deviation"). World stopped.
    func becomeForward(_ from: [Oop], to: [Oop], extraRoots: inout [Oop]) throws(BecomeError) {
        guard from.count == to.count else { throw .lengthMismatch }
        for o in from + to where !isUsedReference(o) { throw .notAnObject }
        // A pair whose source is its target is skipped (as in the experiment).
        let pairs = zip(from, to).filter { $0.0 != $0.1 }
        let from = pairs.map(\.0), to = pairs.map(\.1)
        let hw = highWater
        var target = RawArray<UInt64>(repeating: 0, count: Int(hw))
        defer { target.free() }
        for (f, t) in zip(from, to) {
            if target[Int(f.entryIndex)] != 0 { throw .duplicateSource }
            target[Int(f.entryIndex)] = t.raw
        }
        for t in to where target[Int(t.entryIndex)] != 0 { throw .sourceIsATarget }
        if !prepareOldSpaceOperation(extraRoots).isEmpty { throw .heapFull }
        retireAllContexts()

        var rewritten: UInt64 = 0
        @inline(__always) func forward(_ raw: UInt64) -> UInt64? {
            guard Oop(raw: raw).isObject else { return nil }
            let t = target[Int(truncatingIfNeeded: raw &>> 4)]
            return t == 0 ? nil : t
        }
        var e: UInt64 = 1
        while e < hw {
            defer { e &+= 1 }
            let raw = e &<< 4
            let s = stateWord(raw)
            if EntryState.isFree(s) || target[Int(e)] != 0 { continue }
            let h = Header(raw: headerWord(raw))
            if h.isBytes { continue }
            var i: UInt64 = 0
            while i < h.count {
                let at = s &+ 8 &+ i &<< 3
                if let t = forward(heap.word(atOffset: at)) {
                    heap.setWord(atOffset: at, t)
                    rewritten &+= 1
                }
                i &+= 1
            }
        }
        let g = unsafe gc
        for i in unsafe 0..<g.pointee.roots.count {
            if let t = unsafe forward(g.pointee.roots[i]) { unsafe g.pointee.roots[i] = t; rewritten &+= 1 }
        }
        for i in unsafe 0..<g.pointee.classTable.count {
            if let t = unsafe forward(g.pointee.classTable[i]) { unsafe g.pointee.classTable[i] = t; rewritten &+= 1 }
        }
        for i in extraRoots.indices {
            if let t = forward(extraRoots[i].raw) { extraRoots[i] = Oop(raw: t); rewritten &+= 1 }
        }

        var runs = RunBuilder(chunk: UInt64(config.entryChunk))
        for f in from {
            // AOT 1: a freed method's native binding goes with its entry.
            unbindNative(f)
            setHeaderWord(f.raw, 0)
            runs.add(f.raw, self)
            oldMap.remove(f.entryIndex)
        }
        lockPools()
        unsafe runs.finish(into: &pools.pointee.entryRuns)
        unlockPools()
        unsafe gc.pointee.counters.forwardedObjects &+= UInt64(from.count)
        unsafe gc.pointee.counters.referencesForwarded &+= rewritten
        verifyAtPause("after becomeForward", phase: .idle)
    }
}
