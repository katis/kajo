import Darwin
import Synchronization

/// Where a body lies (tests and reports).
enum NurserySpace: Equatable, Sendable {
    case old
    case eden(Int)
    case survivorFrom(Int)
    /// Not an object, a free entry, or a young body outside its spaces.
    case other

    var isSurvivor: Bool { if case .survivorFrom = self { true } else { false } }
}

// The host's view of the nursery (tests, `kajo run`): every call enters
// the VM on the host worker like any host call; reads of the heap happen
// with the world stopped.
extension VM {
    var hasNursery: Bool { unsafe state.pointee.nursery != nil }

    /// A scavenge in a stop of its own.
    func scavenge() { unsafe host { w in unsafe scavengeNow(state, w) } }

    /// Module 4's full collection (the soft limit's), in a stop of its own.
    func runFullCollection() {
        unsafe host { w in _ = unsafe stopWorld(state, w, retry: true) { stop in unsafe fullCollection(state, stop) } }
    }

    /// Module 1's snapshot, in a stop: everything is promoted first, so
    /// nothing in an image is young.
    func snapshot() -> [UInt8] {
        var bytes: [UInt8] = []
        withWorldStopped { bytes = image.om.snapshot() }
        return bytes
    }

    /// Run `body` on the host worker inside the VM (not stopped): tests that
    /// allocate as a worker would, or store without the barrier.
    func onHostWorker(_ body: (Machine) -> Void) {
        unsafe host { w in body(unsafe machine(w)) }
    }

    var nurseryCounters: NurseryCounters {
        guard let n = unsafe state.pointee.nursery else { return NurseryCounters() }
        return inspect { _ in
            var c = unsafe n.pointee.state.pointee.counters
            for k in unsafe 0..<n.pointee.count {
                let a = unsafe n.alloc(k).pointee
                c.youngAllocations &+= unsafe a.youngAllocations &+ UInt64(a.stash.next)
                c.youngAllocatedBytes &+= unsafe a.youngBytes &+ (a.top &- a.edenStart)
                c.largeAllocations &+= unsafe a.largeAllocations
                c.barrierSlowCalls &+= unsafe a.barrierSlowCalls
                c.barrierYoungHolders &+= unsafe a.barrierYoungHolders
                c.stashRefills &+= unsafe a.stashRefills
            }
            return c
        }
    }

    /// Every scavenge so far.
    var scavengeLog: [ScavengeRecord] {
        guard let n = unsafe state.pointee.nursery else { return [] }
        return inspect { _ in unsafe n.pointee.state.pointee.records }
    }

    /// The remembered marker of `o` is set.
    func isRemembered(_ o: Oop) -> Bool {
        guard let n = unsafe state.pointee.nursery else { return false }
        return inspect { _ in unsafe n.remMarker(o.raw).pointee.load(ordering: .relaxed) & 0xFFFF != 0 }
    }

    /// Holders in worker `i`'s remembered buffers (every nursery's).
    func rememberedBufferCount(worker i: Int) -> Int {
        guard let n = unsafe state.pointee.nursery else { return 0 }
        return inspect { _ in (0..<(unsafe n.pointee.count)).reduce(0) { unsafe $0 + n.remBuffer(i, $1).pointee.count } }
    }

    /// The remembered word of `o` (bit n: in nursery n's set; bit 16 + n:
    /// pending).
    func rememberedWord(_ o: Oop) -> UInt32 {
        guard let n = unsafe state.pointee.nursery else { return 0 }
        return inspect { _ in unsafe n.remMarker(o.raw).pointee.load(ordering: .relaxed) }
    }

    func space(of o: Oop) -> NurserySpace {
        inspect { om in
            guard om.isUsedReference(o) else { return .other }
            let h = om.header(o)
            let s = om.bodyOffset(o)
            if !h.isYoung { return s < UInt64(om.heap.bytes) ? .old : .other }
            guard let n = unsafe state.pointee.nursery, unsafe h.nurseryIndex < n.pointee.count else { return .other }
            let a = unsafe n.alloc(h.nurseryIndex).pointee
            let v = unsafe n.survivors(h.nurseryIndex).pointee
            if unsafe s >= a.edenStart && s < a.top { return .eden(h.nurseryIndex) }
            if unsafe s >= v.survFromStart && s < v.survFromTop { return .survivorFrom(h.nurseryIndex) }
            return .other
        }
    }
}
