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

enum InstancePrimitives {
    static let table: [(number: Int, selector: String, argc: Int)] = [
        (167, "Smalltalk primAllInstancesOf:limit:", 2), (168, "Smalltalk primInstanceCountOf:", 1),
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
        inInstanceStop(m, keeping: [c.arg0]) { om, _ in n = om.walkInstances(of: classes) { _ in true } }
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
/// with the stop's roots; `work` does not run when the hook leaves anything
/// young. Outside a VM (a lone interpreter) with this interpreter's roots.
private func inInstanceStop(_ m: Machine, keeping: [Oop], _ work: (ObjectMemory, _ roots: () -> [Oop]) -> Void) {
    let om = m.om
    if let vm = unsafe workerOf(m.state).pointee.vm {
        unsafe stopWorld(vm, workerOf(m.state), retry: true, keeping: keeping) { stop in
            unsafe markStop(vm, .instances)
            guard om.prepareOldSpaceOperation(stop.roots()).isEmpty else { return }
            work(om) { stop.roots() }
        }
        unsafe workerOf(m.state).pointee.seenEpoch = vm.pointee.safepoint.pointee.epoch
    } else {
        let roots = m.rootsForPause() + keeping
        if om.prepareOldSpaceOperation(roots).isEmpty { work(om) { roots } }
    }
    m.flushCache()
}

/// Primitive 167's two walks and the allocation between them (see the
/// file's comment).
private func allInstances(_ m: Machine, classes: [Bool], limit: Int, keeping: [Oop]) -> Oop {
    var answer = Oop.none
    let ctx = unsafe m.state.pointee.context
    inInstanceStop(m, keeping: keeping) { om, roots in
        var n = 0
        if limit > 0 { om.walkInstances(of: classes) { _ in n &+= 1; return n < limit } }
        guard let a = om.allocate(ctx, classIndex: WellKnown.array, slots: n, fill: m.nilObject, extraRoots: roots()) else { return }
        var filled = 0
        if n > 0 {
            om.walkInstances(of: classes, skipping: a) { o in
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
