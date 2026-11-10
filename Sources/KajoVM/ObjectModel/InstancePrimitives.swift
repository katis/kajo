// The discoverability follow-up (docs/modules/discoverability.md): finding
// instances.
//
//   167  Smalltalk primAllInstancesOf: classes limit: n. An Array of every
//        object in the heap whose class is one of `classes` (a Behavior, or
//        an Array of Behaviors: `allSubInstances` passes the class and its
//        subclasses and walks once), at most n of them (0 to 16 777 215,
//        the count field's limit; anything else fails), in entry-table
//        order. Objects nothing reaches any more are included until a
//        collection frees them (Pharo's rule). The answer is never one of
//        its own elements.
//   168  Smalltalk primInstanceCountOf: classes. How many such objects
//        there are, allocating nothing.
//
// Both run in one stop of the world of their own kind (`instances`, on the
// run line's `stopsByKind`), and in it module 1's promote-all hook first,
// as every operation that assumes nothing young does: a marking cycle is
// abandoned or its sweep finished and applied, deferred entry frees are
// released, every young object is promoted. Then the walk reads old space
// only, through the old map (ObjectMemory/Instances.swift). If the hook
// leaves anything young (the promotion reserve's fallback: old space had
// no block for it) the primitive fails and the kernel says the heap is
// full, as a reshape refuses.
//
// 167 walks twice in the same stop: it counts (up to the limit), allocates
// the Array, then fills it. The Array is allocated in the stop directly in
// old space (`ObjectMemory.allocate` with the stop's roots, as a class
// definition's objects and a reshape's bodies are), never through the
// mutator's allocation path: that path may need a stop of its own (a
// scavenge, a full collection) or wait for the marker or the sweep, and a
// worker that is already the stopper cannot do either, which is why an
// allocation through it inside a stop is forbidden to every worker, the
// main one included. In the stop nothing is young and no cycle runs (the
// hook abandoned it), so the Array needs no barrier, no remembered word
// and no snapshot bit, and its stores need none either. It is rooted from
// the moment the primitive answers (the interpreter pushes it) and the
// worker passes no poll and no allocation between the stop's release and
// that push, so it is never "held only by the stop that allocated it" when
// its worker parks (module 10's lesson). An Array past 4095 slots is a
// large object, old at birth, which `allocate` makes as a run. If the
// allocation had to collect (old space full), garbage the count included
// may have been freed: the fill then finds fewer, and the answer is a
// second Array of exactly what was found.

//   169  Smalltalk primPointersTo: anObject limit: n (the `pointersTo:`
//        follow-up, docs/modules/pointers-to.md). An Array of every object
//        in the heap with at least one slot holding anObject (compared
//        raw, so an immediate works too), at most n of them (0 to
//        16 777 215), in entry-table order; a method whose literal frame
//        holds it stands for that frame. Garbage counts until a collection
//        frees it; Process stacks are not in the heap and are not read.
//        The answer is never one of its own elements; anObject itself is
//        listed when it holds itself.
//   170  Smalltalk primPointerCountTo: anObject. How many such objects
//        there are, allocating nothing.
//
// 169 and 170 run in the same stop kind and hook as 167 and 168, and 169
// allocates its Array in the stop as 167 does (the rule and the reason
// above hold word for word), but walks once: the holders go into a host
// buffer, the Array is allocated and filled from it, and only when that
// allocation collected is the Array filled by a second walk. The walk is ObjectMemory's
// `walkPointers`; the slots it compared are the stop record's `words`.

enum InstancePrimitives {
    static let table: [(number: Int, selector: String, argc: Int)] = [
        (167, "Smalltalk primAllInstancesOf:limit:", 2), (168, "Smalltalk primInstanceCountOf:", 1),
        (169, "Smalltalk primPointersTo:limit:", 2), (170, "Smalltalk primPointerCountTo:", 1),
    ]
    /// The largest `limit`: the count field's (an Array of more slots
    /// cannot be made).
    static let maxLimit: Int64 = Int64(Header.maxLargeCount)
}

@inline(never)
func instancePrimitive(_ n: Int, _ m: Machine, _ c: PrimitiveCall) -> Oop {
    switch n {
    case 167:
        guard c.argc == 2, c.arg1.isSmallInteger else { return .none }
        let limit = c.arg1.smallIntegerValue
        guard limit >= 0, limit <= InstancePrimitives.maxLimit, let classes = instanceClassFlags(m, c.arg0) else { return .none }
        return allInstances(m, classes: classes, limit: Int(limit), keeping: [c.arg0])
    case 168:
        guard c.argc == 1, let classes = instanceClassFlags(m, c.arg0) else { return .none }
        var n = -1
        inInstanceStop(m, keeping: [c.arg0]) { om, _, building in n = om.walkInstances(of: classes, building: building) { _ in true } }
        return n < 0 ? .none : Oop(smallInteger: Int64(n))
    case 169:
        guard c.argc == 2, c.arg1.isSmallInteger else { return .none }
        let limit = c.arg1.smallIntegerValue
        guard limit >= 0, limit <= InstancePrimitives.maxLimit else { return .none }
        return pointersTo(m, c.arg0, limit: Int(limit))
    case 170:
        guard c.argc == 1 else { return .none }
        var n = -1
        let target = c.arg0
        inInstanceStop(m, keeping: [target]) { om, _, building in
            var words: UInt64 = 0
            n = om.walkPointers(to: target.raw, building: building, words: &words) { _ in true }
            noteStopWords(m, words)
        }
        return n < 0 ? .none : Oop(smallInteger: Int64(n))
    default:
        return .none
    }
}

/// A flag per class index for the Behavior `o`, or for each Behavior of the
/// Array `o`; nil (the primitive fails) for anything else.
private func instanceClassFlags(_ m: Machine, _ o: Oop) -> [Bool]? {
    let om = m.om
    var flags = [Bool](repeating: false, count: om.classCount)
    func add(_ b: Oop) -> Bool {
        guard b.isObject, om.isBehavior(b), om.count(of: b) >= UInt64(ClassLayout.size) else { return false }
        let ci = om.load(b, ClassLayout.classIndex)
        guard ci.isSmallInteger, ci.smallIntegerValue > 0, ci.smallIntegerValue < Int64(om.classCount),
              om.classOop(UInt64(ci.smallIntegerValue)) == b else { return false }
        flags[Int(ci.smallIntegerValue)] = true
        return true
    }
    if o.isObject, !om.isBytes(o), m.classIndex(of: o) == WellKnown.array {
        let n = Int(om.count(of: o))
        guard n <= om.classCount else { return nil }
        for i in 0..<n {
            guard add(om.load(o, i)) else { return nil }
        }
        return flags
    }
    return add(o) ? flags : nil
}

/// Run `work` in a stop of kind `instances` after the promote-all hook,
/// with the stop's roots and the objects polled primitives are still
/// building (pending roots marked so, which no walk answers: the review
/// fixes, item 2); `work` does not run when the hook leaves anything
/// young. Outside a VM (a lone interpreter) with this interpreter's roots.
private func inInstanceStop(_ m: Machine, keeping: [Oop],
                            _ work: (ObjectMemory, _ roots: () -> [Oop], _ building: Set<UInt64>) -> Void) {
    let om = m.om
    if let vm = unsafe workerOf(m.state).pointee.vm {
        unsafe stopWorld(vm, workerOf(m.state), retry: true, keeping: keeping) { stop in
            unsafe markStop(vm, .instances)
            guard om.prepareOldSpaceOperation(stop.roots()).isEmpty else { return }
            let building = unsafe vm.pointee.config.testSwitches.walksSeeBuilding ? [] : pendingBuildingObjects(vm)
            work(om, { stop.roots() }, building)
        }
        unsafe workerOf(m.state).pointee.seenEpoch = vm.pointee.safepoint.pointee.epoch
    } else {
        let roots = m.rootsForPause() + keeping
        if om.prepareOldSpaceOperation(roots).isEmpty { work(om, { roots }, []) }
    }
    m.flushCache()
}

/// The slots a stop's walk compared, for its record (part 1a's words).
private func noteStopWords(_ m: Machine, _ words: UInt64) {
    if let vm = unsafe workerOf(m.state).pointee.vm { unsafe noteStopWork(vm, words: words) }
}

/// Primitive 169: 167's two walks and allocation with the slot scan.
private func pointersTo(_ m: Machine, _ target: Oop, limit: Int) -> Oop {
    var answer = Oop.none
    let ctx = unsafe m.state.pointee.context
    inInstanceStop(m, keeping: [target]) { om, roots, building in
        var words: UInt64 = 0
        defer { noteStopWords(m, words) }
        // One walk into a host buffer, then the Array filled from it: the
        // walk reads every slot of the heap, so a second one would double
        // the stop. If the allocation collected, what it freed may be in
        // the buffer, and the Array is filled by a second walk instead.
        var found: [UInt64] = []
        if limit > 0 {
            om.walkPointers(to: target.raw, building: building, words: &words) { o in found.append(o.raw); return found.count < limit }
        }
        let n = found.count
        let collections = om.counters.collections
        guard let a = om.allocate(ctx, classIndex: WellKnown.array, slots: n, fill: m.nilObject, extraRoots: roots()) else { return }
        if om.counters.collections == collections {
            for i in 0..<n { om.store(a, i, Oop(raw: found[i])) }
            answer = a
            return
        }
        var filled = 0
        if n > 0 {
            om.walkPointers(to: target.raw, skipping: a, building: building, words: &words) { o in
                om.store(a, filled, o)
                filled &+= 1
                return filled < n
            }
        }
        if filled == n {
            answer = a
            return
        }
        // The allocation collected: what it freed is not in the heap any more.
        guard let b = om.allocate(ctx, classIndex: WellKnown.array, slots: filled, fill: m.nilObject, extraRoots: roots() + [a]) else { return }
        for i in 0..<filled { om.store(b, i, om.load(a, i)) }
        answer = b
    }
    return answer
}

/// Primitive 167's two walks and the allocation between them (see the
/// file's comment).
private func allInstances(_ m: Machine, classes: [Bool], limit: Int, keeping: [Oop]) -> Oop {
    var answer = Oop.none
    let ctx = unsafe m.state.pointee.context
    inInstanceStop(m, keeping: keeping) { om, roots, building in
        var n = 0
        if limit > 0 { om.walkInstances(of: classes, building: building) { _ in n &+= 1; return n < limit } }
        guard let a = om.allocate(ctx, classIndex: WellKnown.array, slots: n, fill: m.nilObject, extraRoots: roots()) else { return }
        var filled = 0
        if n > 0 {
            om.walkInstances(of: classes, skipping: a, building: building) { o in
                om.store(a, filled, o)
                filled &+= 1
                return filled < n
            }
        }
        if filled == n {
            answer = a
            return
        }
        // The allocation collected: what it freed is not in the heap any more.
        guard let b = om.allocate(ctx, classIndex: WellKnown.array, slots: filled, fill: m.nilObject, extraRoots: roots() + [a]) else { return }
        for i in 0..<filled { om.store(b, i, om.load(a, i)) }
        answer = b
    }
    return answer
}
