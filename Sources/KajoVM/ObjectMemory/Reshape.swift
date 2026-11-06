enum ReshapeError: Error, Equatable {
    case notRegistered
    case byteObject
    /// A pinned body cannot be replaced.
    case pinnedInstance
    /// A layout index is not below `namedSlots`, or an instance has fewer
    /// slots than `namedSlots`.
    case layoutOutOfRange
    /// A reshaped instance would pass the count field (module 10: no
    /// longer one block; a larger body takes a run).
    case tooLarge
    /// No room for the new bodies; nothing was changed. Collect and retry.
    case heapFull
    /// Module 8: an instance is read-only (ADR 0009 section 9).
    case readOnlyInstance
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
        var plan = try prepareReshape([ReshapeRequest(classIndex: classIndex, namedSlots: namedSlots, layout: layout)], fill: fill)
        defer { plan.free() }
        commitReshape(&plan)
        verifyAtPause("after reshape", phase: .idle)
        return plan.instances
    }

    /// Module 8e: the checks and the allocation of a reshape of several
    /// classes at once, nothing repointed yet: a class's instances and its
    /// subclasses' change together, and a change that cannot get every
    /// body changes nothing. `allowPinned` admits instances pinned for good
    /// (class objects, when a metaclass gains or loses class-side instance
    /// variables): their bodies move in the stop like any other, the pin
    /// stays in the header, and nothing holds a raw pointer into a class
    /// body (the interpreter's raw pointers are a method's bytecodes and
    /// literals). A frame pin is refused still. World stopped.
    func prepareReshape(_ requests: [ReshapeRequest], fill: Oop, allowPinned: Bool = false) throws(ReshapeError) -> ReshapePlan {
        var plan = ReshapePlan(fill: fill)
        for r in requests {
            guard isRegisteredClass(r.classIndex) else { throw .notRegistered }
            for j in r.layout { if let j, j < 0 || j >= r.namedSlots { throw .layoutOutOfRange } }
        }
        // Instances of every class first: a check that fails leaves the heap
        // untouched.
        var objects: [[Oop]] = []
        for r in requests {
            let objs = allInstances(of: r.classIndex)
            for o in objs {
                let h = header(o)
                if h.isBytes { throw .byteObject }
                if h.isFramePinned || h.isPinnedForGood && !allowPinned { throw .pinnedInstance }
                if h.isReadOnly { throw .readOnlyInstance }
                if h.count < UInt64(r.namedSlots) { throw .layoutOutOfRange }
                if UInt64(r.layout.count) &+ h.count &- UInt64(r.namedSlots) > UInt64(Header.maxLargeCount) { throw .tooLarge }
            }
            objects.append(objs)
        }
        if !prepareOldSpaceOperation(nil).isEmpty { throw .heapFull }
        retireAllContexts()
        guard let ctx = unsafe gc.pointee.collectorContext else { preconditionFailure("no collector context") }
        for (k, r) in requests.enumerated() {
            for o in objects[k] {
                let words = UInt64(r.layout.count) &+ header(o).count &- UInt64(r.namedSlots) &+ 1
                // Module 10: a body past a block takes a run (old is where
                // it goes anyway: the reshape runs after a promote-all).
                let large = words &<< 3 > UInt64(BlockHeap.blockBytes)
                guard let off = large ? takeRun(bytes: words &<< 3, reserve: true) : allocateBody(ctx, bytes: words &<< 3) else {
                    // The bodies taken so far name their entries but no entry
                    // names them: dead, and walkable, until the next sweep.
                    retire(ctx)
                    plan.free()
                    throw .heapFull
                }
                heap.setWord(atOffset: off, BackRef.make(entryIndex: o.entryIndex, words: words))
                plan.objects.append(o.raw)
                plan.bodies.append(off)
                plan.request.append(Int32(k))
            }
        }
        retire(ctx)
        plan.requests = requests
        plan.instances = objects.reduce(0) { $0 + $1.count }
        return plan
    }

    /// Repoint every instance the plan allocated for and set each class
    /// format's named-slot count. Cannot fail. World stopped; the caller
    /// verifies.
    func commitReshape(_ plan: inout ReshapePlan) {
        for k in 0..<plan.objects.count {
            let o = Oop(raw: plan.objects[k])
            let r = plan.requests[Int(plan.request[k])]
            let old = stateWord(o.raw)
            let new = plan.bodies[k]
            let h = header(o)
            let indexed = h.count &- UInt64(r.namedSlots)
            var j: UInt64 = 0
            for src in r.layout {
                let v = src.map { heap.word(atOffset: old &+ 8 &+ UInt64($0) &<< 3) } ?? plan.fill.raw
                heap.setWord(atOffset: new &+ 8 &+ j &<< 3, v)
                j &+= 1
            }
            for i in 0..<indexed {
                heap.setWord(atOffset: new &+ 8 &+ (j &+ i) &<< 3,
                             heap.word(atOffset: old &+ 8 &+ (UInt64(r.namedSlots) &+ i) &<< 3))
            }
            setHeader(o, Header(raw: h.raw & ~Header.countMask | (j &+ indexed) &<< Header.countShift))
            setStateWord(o.raw, new)
        }
        // Module 8: the class format's named-slot count follows (basicNew
        // reads it).
        for r in plan.requests {
            let f = classFormat(r.classIndex)
            if f.namedSlots == r.namedSlots && f.kind.isPointers && r.layout.count <= Int(ClassFormat.namedMask) {
                unsafe gc.pointee.classFormats[Int(r.classIndex)] = f.raw & ~ClassFormat.namedMask | UInt64(r.layout.count)
            }
        }
        unsafe gc.pointee.counters.reshapedObjects &+= UInt64(plan.objects.count)
    }
}

/// One class of a reshape: its instances' named slots now, and where each
/// new named slot comes from (an old slot, or nil for the fill).
struct ReshapeRequest {
    let classIndex: UInt64
    let namedSlots: Int
    let layout: [Int?]
}

/// What `prepareReshape` allocated: per instance its new body and its
/// request. Freed by the owner.
struct ReshapePlan {
    let fill: Oop
    var requests: [ReshapeRequest] = []
    var objects = RawArray<UInt64>()
    var bodies = RawArray<UInt64>()
    var request = RawArray<Int32>()
    var instances = 0

    init(fill: Oop) { self.fill = fill }

    mutating func free() {
        objects.free()
        bodies.free()
        request.free()
        objects = RawArray()
        bodies = RawArray()
        request = RawArray()
    }
}
