enum ReshapeError: Error, Equatable {
    case notRegistered
    case byteObject
    /// A pinned body cannot be replaced.
    case pinnedInstance
    /// A layout index is not below `namedSlots`, or an instance has fewer
    /// slots than `namedSlots`.
    case layoutOutOfRange
    /// A reshaped instance would not fit in a block.
    case tooLarge
    /// No room for the new bodies; nothing was changed. Collect and retry.
    case heapFull
}

extension ObjectMemory {
    /// Every used entry of class `classIndex`, in table order. Includes
    /// unreachable instances unless a collection ran first. World stopped.
    func allInstances(of classIndex: UInt64) -> [Oop] {
        var out: [Oop] = []
        let hw = highWater
        var e: UInt64 = 1
        while e < hw {
            let raw = e &<< 4
            if !EntryState.isFree(stateWord(raw)), Header(raw: headerWord(raw)).classIndex == classIndex {
                out.append(Oop(raw: raw))
            }
            e &+= 1
        }
        return out
    }

    /// Give every instance of a class a new body with a new layout and keep
    /// its oop (ADR 0003). `layout[j]` is the old named slot copied into new
    /// slot j, or nil for `fill`. Slots beyond `namedSlots` (the indexed
    /// part) follow the new named slots unchanged. All or nothing: every new
    /// body is allocated before any entry is repointed. Answers the number
    /// of instances reshaped. World stopped.
    @discardableResult
    func reshape(classIndex: UInt64, namedSlots: Int, layout: [Int?], fill: Oop) throws(ReshapeError) -> Int {
        guard isRegisteredClass(classIndex) else { throw .notRegistered }
        for j in layout { if let j, j < 0 || j >= namedSlots { throw .layoutOutOfRange } }
        let objs = allInstances(of: classIndex)
        for o in objs {
            let h = header(o)
            if h.isBytes { throw .byteObject }
            if h.isPinned { throw .pinnedInstance }
            if h.count < UInt64(namedSlots) { throw .layoutOutOfRange }
            if UInt64(layout.count) &+ h.count &- UInt64(namedSlots) > UInt64(Header.maxSlots) { throw .tooLarge }
        }
        retireAllContexts()
        guard let ctx = unsafe gc.pointee.collectorContext else { preconditionFailure("no collector context") }
        var bodies = RawArray<UInt64>()
        defer { bodies.free() }
        for o in objs {
            let words = UInt64(layout.count) &+ header(o).count &- UInt64(namedSlots) &+ 1
            guard let off = allocateBody(ctx, bytes: words &<< 3) else {
                // The bodies taken so far name their entries but no entry
                // names them: dead, and walkable, until the next sweep.
                retire(ctx)
                throw .heapFull
            }
            heap.setWord(atOffset: off, BackRef.make(entryIndex: o.entryIndex, words: words))
            bodies.append(off)
        }
        retire(ctx)
        for (k, o) in objs.enumerated() {
            let old = stateWord(o.raw)
            let new = bodies[k]
            let h = header(o)
            let indexed = h.count &- UInt64(namedSlots)
            var j: UInt64 = 0
            for src in layout {
                let v = src.map { heap.word(atOffset: old &+ 8 &+ UInt64($0) &<< 3) } ?? fill.raw
                heap.setWord(atOffset: new &+ 8 &+ j &<< 3, v)
                j &+= 1
            }
            for i in 0..<indexed {
                heap.setWord(atOffset: new &+ 8 &+ (j &+ i) &<< 3,
                             heap.word(atOffset: old &+ 8 &+ (UInt64(namedSlots) &+ i) &<< 3))
            }
            setHeader(o, Header(raw: h.raw & ~Header.countMask | (j &+ indexed) &<< Header.countShift))
            setStateWord(o.raw, new)
        }
        unsafe gc.pointee.counters.reshapedObjects &+= UInt64(objs.count)
        verifyAtPause("after reshape", phase: .idle)
        return objs.count
    }
}
