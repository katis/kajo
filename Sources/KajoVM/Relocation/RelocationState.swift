import Darwin
import Synchronization

// Concurrent relocation's state (docs/modules/relocation.md "Layouts").
// One allocation per writer, each in its own lines (AGENTS.md): the global
// epoch and the count of held hazard slots (atomics every thread reads),
// the relocator's state (the marker participant inside the VM, the stopper
// with the world stopped). Per worker, the hazard slots and the epoch word
// are in module 3's shared line (`WorkerShared`), the counters in the
// worker (`RelocationMutatorCounters`).

/// An epoch word's value while its worker is outside the VM.
let quiescentEpoch = UInt64.max

/// One relocation cycle (docs/modules/relocation.md "Counters"). ns.
struct RelocationCycleRecord: Sendable {
    var cycle: UInt64 = 0
    /// Selection at the final mark.
    var candidates: UInt64 = 0
    var blocksSelected: UInt64 = 0
    var capped: UInt64 = 0
    var bytesToMove: UInt64 = 0
    var expectedReclaimBytes: UInt64 = 0
    var selectNs: UInt64 = 0
    var framePins: UInt64 = 0
    /// The pass.
    var objectsMoved: UInt64 = 0
    var bytesMoved: UInt64 = 0
    var skippedPinned: UInt64 = 0
    var skippedHazard: UInt64 = 0
    var blocksEvacuated: UInt64 = 0
    var noSpace = false
    var aborted = false
    var passWallNs: UInt64 = 0
    var passCpuNs: UInt64 = 0
    /// Evacuated blocks freed, by epoch and at pauses (counted until the
    /// apply ends the cycle).
    var freedByEpoch: UInt64 = 0
    var freedAtPause: UInt64 = 0
    var completed = false
}

/// Counters of every cycle so far.
struct RelocationCounters: Sendable {
    var cyclesPlanned: UInt64 = 0
    var cyclesSelected: UInt64 = 0
    var candidates: UInt64 = 0
    var blocksSelected: UInt64 = 0
    var capped: UInt64 = 0
    var bytesToMove: UInt64 = 0
    var expectedReclaimBytes: UInt64 = 0
    var objectsMoved: UInt64 = 0
    var bytesMoved: UInt64 = 0
    var skippedPinned: UInt64 = 0
    var skippedHazard: UInt64 = 0
    var casFailures: UInt64 = 0
    var noSpace: UInt64 = 0
    var blocksEvacuated: UInt64 = 0
    var passesAborted: UInt64 = 0
    var framePins: UInt64 = 0
    var freedByEpoch: UInt64 = 0
    var freedAtPause: UInt64 = 0
    /// From an evacuated block's switch (its addition to the pending list)
    /// to its free.
    var freeDelayNs: UInt64 = 0
    var freeDelayMaxNs: UInt64 = 0
    var pendingMax: UInt64 = 0
    var passWallNs: UInt64 = 0
    var passCpuNs: UInt64 = 0
    /// Parks of the relocator between a CAS and its switch or revert: the
    /// model's deadlock. Always 0 (checked builds trap).
    var parksWhileRelocating: UInt64 = 0
    /// Perturbation points reached inside an object's copy (yields only).
    var perturbedCopies: UInt64 = 0
    var verifierRuns: UInt64 = 0
    var verifierFailures: UInt64 = 0
    /// Most blocks in use seen at a pause, and at the last one.
    var peakBlocksInUse: UInt64 = 0
    /// Summed over the workers on read.
    var storesRedone: UInt64 = 0
    var spinEpisodes: UInt64 = 0
    var spinNs: UInt64 = 0
    var spinMaxNs: UInt64 = 0
    var mainSpinEpisodes: UInt64 = 0
    var mainSpinNs: UInt64 = 0
    var mainSpinMaxNs: UInt64 = 0
    var hazardsTaken: UInt64 = 0
    var hazardWaits: UInt64 = 0
}

/// The relocator's state: written by the marker participant inside the VM
/// (between objects it may park; a stopper then reads and writes it with
/// the world stopped), and by stoppers.
@unsafe struct RelocatorState {
    /// Live bytes per block, counted by the marker while a relocation is
    /// planned (module 5's `MarkerState.blockLive` points here then).
    let blockLive: UnsafeMutablePointer<UInt32>
    let blockCount: Int
    /// The cycle a relocation was planned for at its initial mark (0: none).
    var plannedCycle: UInt64 = 0
    /// The selected blocks, in block order, and the next one to evacuate.
    var selected = RawArray<UInt32>()
    var cursor = 0
    /// The cycle whose pass ran to its end (or stopped for space).
    var relocatedCycle: UInt64 = 0
    /// Evacuated blocks waiting for every worker's epoch: block, the epoch
    /// recorded, the time.
    var pendingBlocks = RawArray<UInt32>()
    var pendingEpochs = RawArray<UInt64>()
    var pendingTimes = RawArray<UInt64>()
    /// Objects frame-pinned at the final mark, cleared by the pause that
    /// applies or aborts the cycle.
    var framePins = RawArray<UInt64>()
    /// To-space: the relocator's own allocation context (fresh blocks under
    /// the soft limit).
    let context: AllocContext
    var counters = RelocationCounters()
    /// Finished cycles' records (appended at the cycle's end, with the
    /// world stopped), and the current cycle's (a plain value: the pass
    /// never touches a Swift array).
    var records: [RelocationCycleRecord] = []
    var current = RelocationCycleRecord()
    var hasCurrent = false
    /// The verifier is due at the next pause: the relocator selected a
    /// set, moved or reverted an object, or freed a block since the last
    /// pause that verified.
    var verifyDue = false
    /// Density at the last final mark: marked bytes over in-use bytes.
    var lastDensity = 0.0
    var haveDensity = false
}

/// The VM's relocation state.
@unsafe struct RelocationShared {
    let config: RelocationConfig
    let om: ObjectMemory
    let workerCount: Int
    /// The global epoch E: incremented (seq_cst) when a block is evacuated.
    /// The VM's (module 7's young collections share it).
    let epoch: UnsafeMutablePointer<Atomic<UInt64>>
    /// Hazard slots held in every worker (amendment 16): the relocator
    /// scans the slots only when one is held. The VM's.
    let hazardsHeld: UnsafeMutablePointer<Atomic<Int>>
    let state: UnsafeMutablePointer<RelocatorState>
    /// Test hook: called by `enterVM` between its load of the epoch and its
    /// store of it (where a worker's own loads may overtake that store).
    /// The VM's.
    let enterWindow: UnsafeMutablePointer<EnterWindowHook>
}

/// A C function and its context (tests only).
@unsafe struct EnterWindowHook {
    var hook: (@convention(c) (UnsafeMutableRawPointer?, Int) -> Void)? = nil
    var context: UnsafeMutableRawPointer? = nil
}

typealias RelocationPointer = UnsafeMutablePointer<RelocationShared>

/// A value in its own 128-byte aligned allocation.
func linedValue<T>(_ v: T) -> UnsafeMutablePointer<T> {
    let raw = UnsafeMutableRawPointer.allocate(byteCount: (MemoryLayout<T>.stride + 127) & ~127, alignment: 128)
    let p = unsafe raw.bindMemory(to: T.self, capacity: 1)
    unsafe p.initialize(to: v)
    return unsafe p
}

func unlinedValue<T>(_ p: UnsafeMutablePointer<T>) {
    unsafe p.deinitialize(count: 1)
    unsafe UnsafeMutableRawPointer(p).deallocate()
}

extension RelocationShared {
    /// Give `vm` concurrent relocation (after marking: the marker relocates).
    /// No-op when off or without marking.
    static func install(_ vm: VMPointer) {
        let config = unsafe vm.pointee.config.relocation
        // The interpreter's two cached pointers are into the image's
        // methods: an image that did not pin them cannot be relocated.
        guard config.enabled, unsafe vm.pointee.marking != nil, unsafe vm.pointee.image.pinsForGood else { return }
        let om = unsafe vm.pointee.om
        let blocks = om.heap.blockCount
        let live = UnsafeMutablePointer<UInt32>.allocate(capacity: blocks)
        unsafe live.initialize(repeating: 0, count: blocks)
        let st = unsafe linedValue(RelocatorState(blockLive: live, blockCount: blocks, context: om.makeContext()))
        let r = unsafe linedValue(RelocationShared(
            config: config, om: om, workerCount: vm.pointee.workerCount, epoch: vm.pointee.epoch,
            hazardsHeld: vm.pointee.hazardsHeld, state: st, enterWindow: vm.pointee.enterWindow))
        unsafe vm.pointee.relocation = r
    }

    static func uninstall(_ vm: VMPointer) {
        guard let r = unsafe vm.pointee.relocation else { return }
        let s = unsafe r.pointee
        let st = unsafe s.state
        unsafe st.pointee.blockLive.deallocate()
        unsafe st.pointee.selected.free()
        unsafe st.pointee.pendingBlocks.free()
        unsafe st.pointee.pendingEpochs.free()
        unsafe st.pointee.pendingTimes.free()
        unsafe st.pointee.framePins.free()
        unsafe s.om.destroyContext(st.pointee.context)
        unsafe unlinedValue(st)
        unsafe unlinedValue(r)
        unsafe vm.pointee.relocation = nil
    }
}
