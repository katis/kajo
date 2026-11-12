import Darwin
import Synchronization

// Allocation stalls (docs/modules/allocation-stalls.md): old space paced by
// the collector's progress. Part 1, the instrumentation: each cycle's record
// carries what the steady-state inequality needs (old space at the snapshot
// and at the end, what was promoted while the cycle ran, what it freed, the
// marker's time by phase and parked) and what waited on it.

/// Bytes promoted so far by every nursery, and by the main worker's alone:
/// module 4's scavenges (counters written in stops) and module 7's
/// collections (an atomic, and the young log under the safepoint mutex).
/// World stopped.
func promotedTotals(_ vm: VMPointer) -> (all: UInt64, main: UInt64) {
    var all: UInt64 = 0, main: UInt64 = 0
    if let n = unsafe vm.pointee.nursery {
        all &+= unsafe n.pointee.state.pointee.counters.promotedBytes
        main &+= unsafe n.pointee.state.pointee.counters.promotedMainBytes
    }
    if let y = unsafe vm.pointee.young {
        all &+= unsafe y.pointee.promotedBytes.pointee.load(ordering: .relaxed)
        main &+= unsafe y.pointee.log.pointee.promotedMainBytes
    }
    return (all, main)
}

/// Blocks module 6 has freed so far (by epoch and at pauses). World stopped.
private func relocationBlocksFreed(_ vm: VMPointer) -> UInt64 {
    guard let r = unsafe vm.pointee.relocation else { return 0 }
    let c = unsafe r.pointee.state.pointee.counters
    return c.freedByEpoch &+ c.freedAtPause
}

/// Allocations that waited for the collector so far (under the waits lock).
private func waitsSoFar(_ mk: MarkingPointer) -> UInt64 {
    unsafe pthread_mutex_lock(mk.pointee.waitsLock)
    defer { unsafe pthread_mutex_unlock(mk.pointee.waitsLock) }
    let w = unsafe mk.pointee.waits.pointee
    return w.count &+ w.sweepCount
}

/// A new cycle's record at its initial mark (world stopped).
func cycleRecordAtStart(_ vm: VMPointer, _ mk: MarkingPointer, _ r: inout CycleRecord) {
    let om = unsafe mk.pointee.om
    let p = unsafe promotedTotals(vm)
    r.blocksAtStart = om.blocksInUse
    r.promotedAtStart = p.all
    r.promotedMainAtStart = p.main
    r.relocFreedAtStart = unsafe relocationBlocksFreed(vm)
    r.waitsAtStart = unsafe waitsSoFar(mk)
    r.fallbacksAtStart = unsafe mk.pointee.log.pointee.counters.fallbacks
    let m = unsafe mk.pointee.marker
    unsafe m.pointee.parkMarkNs = 0
    unsafe m.pointee.parkRelocNs = 0
    unsafe m.pointee.parkSweepNs = 0
    unsafe m.pointee.relocWallNs = 0
    unsafe m.pointee.relocCpuNs = 0
}

/// The cycle's end (applied, or abandoned; world stopped).
func cycleRecordAtEnd(_ vm: VMPointer, _ mk: MarkingPointer, _ r: inout CycleRecord) {
    let om = unsafe mk.pointee.om
    let m = unsafe mk.pointee.marker
    let p = unsafe promotedTotals(vm)
    r.blocksAtEnd = om.blocksInUse
    r.oldEntriesAtEnd = unsafe mk.pointee.log.pointee.oldEntries
    r.promotedDuring = p.all &- r.promotedAtStart
    r.promotedMainDuring = p.main &- r.promotedMainAtStart
    r.relocBlocksFreed = unsafe relocationBlocksFreed(vm) &- r.relocFreedAtStart
    r.parkMarkNs = unsafe m.pointee.parkMarkNs
    r.parkRelocNs = unsafe m.pointee.parkRelocNs
    r.parkSweepNs = unsafe m.pointee.parkSweepNs
    r.relocWallNs = unsafe m.pointee.relocWallNs
    r.relocCpuNs = unsafe m.pointee.relocCpuNs
    r.waits = unsafe waitsSoFar(mk) &- r.waitsAtStart
    r.fallbacks = unsafe mk.pointee.log.pointee.counters.fallbacks &- r.fallbacksAtStart
}
