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

/// A thread that keeps an epoch word: a worker of the table, or module 7's
/// young collector thread (it reads young and old bodies between its
/// polls). Module 5's marker worker is not one: it is the relocator, the
/// one freeing, and reads no young body.
@inline(__always)
func isEpochParticipant(_ vm: VMPointer, _ w: WorkerPointer) -> Bool {
    let i = unsafe w.pointee.index
    let n = unsafe vm.pointee.workerCount
    return i < n || i == n &+ 1
}

/// Worker `w`'s epoch word, nil for a thread that keeps none, or when no
/// epoch is kept (neither relocation nor young collection is installed).
@inline(__always)
private func epochWord(_ vm: VMPointer, _ w: WorkerPointer) -> UnsafeMutablePointer<WorkerShared>? {
    guard unsafe vm.pointee.epochsOn, unsafe isEpochParticipant(vm, w) else { return nil }
    return unsafe vm.shared(w.pointee.index)
}

/// A poll slow path or a park: the worker holds no body pointer (the
/// interpreter's two cached pointers are into objects pinned for good).
/// E (acquire), then the word (release).
@inline(__always)
func epochAdvance(_ vm: VMPointer, _ w: WorkerPointer) {
    guard let line = unsafe epochWord(vm, w) else { return }
    let e = unsafe vm.pointee.epoch.pointee.load(ordering: .acquiring)
    unsafe line.pointee.epoch.store(e, ordering: .releasing)
}

/// `leaveVM`, and module 7's waits, before the worker blocks: quiescent
/// (release).
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
    guard let line = unsafe epochWord(vm, w) else { return }
    if unsafe vm.pointee.relocation?.pointee.config.testSwitches.enterZero ?? true {
        unsafe line.pointee.epoch.store(0, ordering: .sequentiallyConsistent)
    }
    let e = unsafe vm.pointee.epoch.pointee.load(ordering: .sequentiallyConsistent)
    let hook = unsafe vm.pointee.enterWindow.pointee
    if let h = unsafe hook.hook { unsafe h(hook.context, w.pointee.index) }
    unsafe line.pointee.epoch.store(e, ordering: .releasing)
}

/// Module 7: the wake from a quiescent wait (`waitServicing`), the same
/// three steps as `enterVM` (docs/models/young-collection.md, finding 3: an
/// unlock is only a release, so a later relaxed offset load could be
/// satisfied before a plain epoch store is visible while a collector's
/// scan still reads quiescent). `zero` off is the test switch's broken
/// variant: E, then the word.
func epochWake(_ vm: VMPointer, _ w: WorkerPointer, zero: Bool) {
    guard let line = unsafe epochWord(vm, w) else { return }
    if zero { unsafe line.pointee.epoch.store(0, ordering: .sequentiallyConsistent) }
    let e = unsafe vm.pointee.epoch.pointee.load(ordering: .sequentiallyConsistent)
    let hook = unsafe vm.pointee.enterWindow.pointee
    if let h = unsafe hook.hook { unsafe h(hook.context, w.pointee.index) }
    unsafe line.pointee.epoch.store(e, ordering: .releasing)
}

/// The smallest epoch word of every participant (seq_cst loads: the
/// relocation model's finding 2): the workers, and module 7's young
/// collector when there is one.
func minParticipantEpoch(_ vm: VMPointer) -> UInt64 {
    var m = quiescentEpoch
    for i in unsafe 0..<vm.pointee.workerCount {
        m = unsafe Swift.min(m, vm.shared(i).pointee.epoch.load(ordering: .sequentiallyConsistent))
    }
    if unsafe vm.pointee.young != nil {
        m = unsafe Swift.min(m, vm.shared(vm.pointee.workerCount &+ 1).pointee.epoch.load(ordering: .sequentiallyConsistent))
    }
    return m
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
    if !atPause && rule { minEpoch = unsafe minParticipantEpoch(vm) }
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
