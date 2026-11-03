import Darwin
import Synchronization

// Freeing evacuated blocks by epoch (docs/modules/relocation.md "Epochs";
// docs/models/relocation.md, steps `M poll`, `M leaveVM`, `M enterVM`,
// `R addPending`, `R tryFreePending`). A global epoch E; each worker's
// epoch word in its shared line holds the E it last saw at a point where
// it held no body pointer: every poll slow path and every park store it,
// `leaveVM` stores quiescent, `enterVM` first 0 and then E. The relocator
// records an evacuated block with s = E and increments E; the block is
// freed when every worker's word is past s. Every pause frees every
// pending block: the world stopped is every worker at such a point.

/// Worker `w`'s epoch word, nil for a worker outside the table (the marker,
/// which is the one freeing) or without relocation.
@inline(__always)
private func epochWord(_ vm: VMPointer, _ w: WorkerPointer) -> UnsafeMutablePointer<WorkerShared>? {
    guard unsafe vm.pointee.relocation != nil, unsafe w.pointee.index < vm.pointee.workerCount else { return nil }
    return unsafe vm.shared(w.pointee.index)
}

/// A poll slow path or a park: the worker holds no body pointer (the
/// interpreter's two cached pointers are into objects pinned for good).
/// E (acquire), then the word (release).
@inline(__always)
func epochAdvance(_ vm: VMPointer, _ w: WorkerPointer) {
    guard let line = unsafe epochWord(vm, w), let r = unsafe vm.pointee.relocation else { return }
    let e = unsafe r.pointee.epoch.pointee.load(ordering: .acquiring)
    unsafe line.pointee.epoch.store(e, ordering: .releasing)
}

/// `leaveVM`, before the worker leaves: quiescent (release).
@inline(__always)
func epochQuiesce(_ vm: VMPointer, _ w: WorkerPointer) {
    guard let line = unsafe epochWord(vm, w) else { return }
    unsafe line.pointee.epoch.store(quiescentEpoch, ordering: .releasing)
}

/// `enterVM`, after the worker counts as active and before it touches the
/// heap: 0 (seq_cst), then E (seq_cst), then the word := E (release).
/// Without the 0 a relocator that reads the word as still quiescent can
/// free a block under an offset this worker loaded before its store of E
/// became visible (docs/models/relocation.md, finding 1); the seq_cst scan
/// in `tryFreePending` makes the argument hold under C++ rules (finding 2).
func epochEnter(_ vm: VMPointer, _ w: WorkerPointer) {
    guard let line = unsafe epochWord(vm, w), let r = unsafe vm.pointee.relocation else { return }
    if unsafe r.pointee.config.testSwitches.enterZero {
        unsafe line.pointee.epoch.store(0, ordering: .sequentiallyConsistent)
    }
    let e = unsafe r.pointee.epoch.pointee.load(ordering: .sequentiallyConsistent)
    let hook = unsafe r.pointee.enterWindow.pointee
    if let h = unsafe hook.hook { unsafe h(hook.context, w.pointee.index) }
    unsafe line.pointee.epoch.store(e, ordering: .releasing)
}

/// The relocator: block `b` is evacuated, every switch of its objects
/// before this. Record it with s = E and increment E (seq_cst).
func addPending(_ r: RelocationPointer, _ b: Int) {
    let st = unsafe r.pointee.state
    let s = unsafe r.pointee.epoch.pointee.wrappingAdd(1, ordering: .sequentiallyConsistent).oldValue
    unsafe st.pointee.pendingBlocks.append(UInt32(b))
    unsafe st.pointee.pendingEpochs.append(s)
    unsafe st.pointee.pendingTimes.append(nanoseconds())
    let n = unsafe UInt64(st.pointee.pendingBlocks.count)
    if unsafe n > st.pointee.counters.pendingMax { unsafe st.pointee.counters.pendingMax = n }
}

/// Free every pending block whose epoch every worker has passed (all of
/// them at a pause). The relocator inside the VM, or a stopper with the
/// world stopped. The epoch words are read with seq_cst loads (the model's
/// finding 2). Answers the blocks freed.
@discardableResult
func tryFreePending(_ vm: VMPointer, _ r: RelocationPointer, atPause: Bool) -> Int {
    let st = unsafe r.pointee.state
    let n = unsafe st.pointee.pendingBlocks.count
    if n == 0 { return 0 }
    let rule = unsafe r.pointee.config.testSwitches.epochRule
    var minEpoch = quiescentEpoch
    if !atPause && rule {
        for i in unsafe 0..<vm.pointee.workerCount {
            minEpoch = unsafe Swift.min(minEpoch, vm.shared(i).pointee.epoch.load(ordering: .sequentiallyConsistent))
        }
    }
    let om = unsafe r.pointee.om
    let now = nanoseconds()
    var kept = 0, freed = 0
    var byEpoch: UInt64 = 0, byPause: UInt64 = 0
    for i in 0..<n {
        let b = unsafe Int(st.pointee.pendingBlocks[i])
        let s = unsafe st.pointee.pendingEpochs[i]
        let t = unsafe st.pointee.pendingTimes[i]
        if atPause || !rule || minEpoch > s {
            om.releaseEvacuatedBlock(b)
            freed += 1
            if atPause { byPause &+= 1 } else { byEpoch &+= 1 }
            let d = now &- t
            unsafe st.pointee.counters.freeDelayNs &+= d
            if unsafe d > st.pointee.counters.freeDelayMaxNs { unsafe st.pointee.counters.freeDelayMaxNs = d }
        } else {
            unsafe st.pointee.pendingBlocks[kept] = UInt32(b)
            unsafe st.pointee.pendingEpochs[kept] = s
            unsafe st.pointee.pendingTimes[kept] = t
            kept += 1
        }
    }
    unsafe st.pointee.pendingBlocks.truncate(kept)
    unsafe st.pointee.pendingEpochs.truncate(kept)
    unsafe st.pointee.pendingTimes.truncate(kept)
    unsafe st.pointee.counters.freedByEpoch &+= byEpoch
    unsafe st.pointee.counters.freedAtPause &+= byPause
    if freed > 0 { unsafe st.pointee.verifyDue = true }
    if unsafe st.pointee.hasCurrent {
        unsafe st.pointee.current.freedByEpoch &+= byEpoch
        unsafe st.pointee.current.freedAtPause &+= byPause
    }
    return freed
}
