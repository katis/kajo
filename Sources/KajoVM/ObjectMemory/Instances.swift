// The discoverability follow-up (docs/modules/discoverability.md): the
// walk behind `allInstances` and `instanceCount` (primitives 167 and 168,
// ObjectModel/InstancePrimitives.swift).
//
// World stopped, after module 1's promote-all hook
// (`prepareOldSpaceOperation`) answered no young object: a marking cycle
// was abandoned or its sweep finished and applied (no swept-but-pending
// run is left), every deferred entry free was released, and every live
// young object promoted. So the old map holds exactly the used entries
// (sweep-stop.md's one-owner table: a pending run's entries are free with
// the old-map bit clear, a deferred free is a young entry and none is
// left, a stash's entries are free), and the walk reads the old map's
// words, skipping 64 free entries per zero word, and the header of each
// entry whose bit is set. A large object is one entry (its continuation
// blocks are not entries), so it counts once.

extension ObjectMemory {
    /// Visit every old entry whose class index is in `classes` (a table of
    /// flags by class index), in table order, until `visit` answers false.
    /// Answers the entries visited. World stopped, nothing young.
    @discardableResult
    func walkInstances(of classes: [Bool], skipping skip: Oop = .none, _ visit: (Oop) -> Bool) -> Int {
        let hw = highWater
        let map = oldMap
        let words = Int((hw &+ 63) &>> 6)
        var found = 0
        for w in 0..<words {
            var bits = map.word(w)
            while bits != 0 {
                let b = UInt64(bits.trailingZeroBitCount)
                bits &= bits &- 1
                let e = UInt64(w) &<< 6 | b
                if e == 0 || e >= hw { continue }
                let raw = e &<< 4
                // Belt and braces: the old map's bit is set exactly while the
                // entry holds an old object, so a free one is never here.
                if EntryState.isFree(stateWord(raw)) { continue }
                let ci = Header(raw: headerWord(raw)).classIndex
                guard ci < UInt64(classes.count), classes[Int(ci)], raw != skip.raw else { continue }
                found &+= 1
                if !visit(Oop(raw: raw)) { return found }
            }
        }
        return found
    }
}

// The `pointersTo:` follow-up (docs/modules/pointers-to.md): the walk behind
// `pointersTo:` and `pointerCountTo:` (primitives 169 and 170). The same
// stop, hook and old-map walk as above, with a scan of every slot of each
// pointer object in place of the class check. Every slot is compared raw
// with the target's oop, so an immediate target (`3 pointersTo`) works
// and nothing is dereferenced:
//
// - A pointer object's slots are its header's count, named and indexable
//   alike. A weak object's weak slots and an ephemeron's slots count as
//   any others (open question 1). Byte objects (the header's bytes bit,
//   long ones included) have no slots and are skipped by the bit alone.
// - A large object (module 10) is one entry whose body is its run of
//   contiguous blocks, so its slots are indexed from its body offset
//   exactly as the marker's `traceChunk` indexes them; no chunking is
//   needed in a stop.
// - The class is in the header, not a slot, and never counts.
// - A CompiledMethod's literal frame is an Array of its own (slot
//   `MethodLayout.literals`). Pharo's literal frame is the method's own
//   slots, and the developer asks which method uses the object, so a
//   method whose literal frame holds the target is the holder, and that
//   literal frame Array is not listed for it (a first pass over the
//   methods notes those frames, because a frame's entry may come before
//   its method's). A block method is held in its outer method's frame,
//   so the outer method is listed for the block method too.
// - Process stacks are not heap objects (module 3) and are not read; a
//   saved Process's stack chunks (module 8c, Arrays of verbatim words)
//   are, so a saved frame's reference is found as a slot of its chunk.
//
// World stopped and nothing young, so the loads are the marker's relaxed
// loads with no hazard slot or pin: no relocation runs (the hook
// abandoned the cycle) and no mutator stores.

extension ObjectMemory {
    /// Visit every old object with a slot holding `target`, in table order,
    /// until `visit` answers false; `skip` (the answer Array) is never
    /// visited. Answers the objects visited; `words` grows by the slots
    /// compared. World stopped, nothing young.
    @discardableResult
    func walkPointers(to target: UInt64, skipping skip: Oop = .none, words: inout UInt64, _ visit: (Oop) -> Bool) -> Int {
        let hw = highWater
        let map = oldMap
        let mapWords = Int((hw &+ 63) &>> 6)
        let frames = literalFramesHolding(target, words: &words)
        var scanned: UInt64 = 0
        var found = 0
        for w in 0..<mapWords {
            var bits = map.word(w)
            while bits != 0 {
                let b = UInt64(bits.trailingZeroBitCount)
                bits &= bits &- 1
                let e = UInt64(w) &<< 6 | b
                if e == 0 || e >= hw { continue }
                let raw = e &<< 4
                let s = stateWord(raw)
                if raw == skip.raw || EntryState.isFree(s) { continue }
                let h = headerWord(raw)
                if h & Header.bytesBit != 0 { continue }
                let n = Int(truncatingIfNeeded: (h & Header.countMask) &>> Header.countShift)
                var i = 0
                while i < n && loadAtomic(bodyOffset: s, i) != target { i &+= 1 }
                scanned &+= UInt64(i < n ? i &+ 1 : n)
                var hit = i < n
                if !frames.isEmpty {
                    let ci = h & Header.classMask
                    if hit && ci == WellKnown.array && frames.contains(raw) {
                        hit = false
                    } else if !hit && ci == WellKnown.method && n > MethodLayout.literals {
                        hit = frames.contains(loadAtomic(bodyOffset: s, MethodLayout.literals))
                    }
                }
                if !hit { continue }
                found &+= 1
                if !visit(Oop(raw: raw)) {
                    words &+= scanned
                    return found
                }
            }
        }
        words &+= scanned
        return found
    }

    /// The literal frames (Arrays) of old methods with a slot holding
    /// `target`: the frames `walkPointers` lists as their methods.
    private func literalFramesHolding(_ target: UInt64, words: inout UInt64) -> Set<UInt64> {
        var frames = Set<UInt64>()
        walkInstances(of: methodClassFlags) { m in
            guard header(m).count > UInt64(MethodLayout.literals) else { return true }
            let lf = load(m, MethodLayout.literals)
            guard lf.isObject, isUsedReference(lf), !isBytes(lf), classIndex(of: lf) == WellKnown.array else { return true }
            let s = stateWord(lf.raw)
            let n = Int(header(lf).count)
            var i = 0
            while i < n && loadAtomic(bodyOffset: s, i) != target { i &+= 1 }
            words &+= UInt64(i < n ? i &+ 1 : n)
            if i < n { frames.insert(lf.raw) }
            return true
        }
        return frames
    }

    private var methodClassFlags: [Bool] {
        var f = [Bool](repeating: false, count: Int(WellKnown.method) + 1)
        f[Int(WellKnown.method)] = true
        return f
    }
}
