import Darwin
import Foundation
import Synchronization

// Module 8c: Processes saved in the image (docs/modules/image-processes.md).
//
// The save. A Process sends `snapshot:` (primitive 142), or a test's VM
// reaches the n-th slow poll (`VMConfig.snapshotAtPoll`). The saver holds
// the scheduler: no worker dequeues a Process, and every poll reaches its
// slow path (the flag's bit 0 is kept set, as module 4 keeps it for a due
// full collection), where a running Process leaves its worker as a
// preemption does: at the back of its ready queue with module 3's saved-pc
// conventions, so its registers in its Process object are exact. The saver
// waits, servicing rounds and parking in other stops (module 7's
// `waitServicing`), until no other worker that runs Processes is inside the
// VM, then stops the world. In the stop (module 8a's method-install stop is
// the model: every other worker parked, each holding no Process) it checks
// that no record but its own runs, drains the external signals, collects
// (module 1's promote-all first), copies every live Process's stack words
// `[0, sp]` into Arrays of at most one block, fills the scheduler state
// (special object 8: `SavedScheduler`), writes the saver's Process as
// ready (after the primitive with `true` pushed, or at its poll rewound as
// a preemption), every saved Process's record slot as -1, takes module 1's
// snapshot, puts every slot it changed back, releases the hold and lets
// the world go. The running system answers false.
//
// The load. `verifyImage` checks the saved Processes all or nothing
// (`SavedProcessRules.swift`); a VM over such an image installs them before
// any worker starts (`installSavedProcesses`): a record and a malloc'ed
// stack each (large enough for every frame on it), the words copied back,
// the ready queues and the finalization Semaphore from the scheduler
// state, the next id; special object 8 is set back to nil.

/// How the Process that saves resumes in the image.
enum SaverForm {
    /// After the primitive's send: its receiver and `argc` arguments
    /// replaced by `true`.
    case primitive(argc: Int)
    /// At the poll it is in, as a preemption (the pc rewound by `rewind`).
    case poll(rewind: Int)
}

/// Images a VM saved for its host (a `snapshot: nil`, a poll trigger): the
/// last few, taken by the host (tests, measurements).
final class SavedImages: Sendable {
    private let images = Mutex<[[UInt8]]>([])
    static let kept = 8

    func add(_ b: [UInt8]) {
        images.withLock { list in
            list.append(b)
            if list.count > SavedImages.kept { list.removeFirst() }
        }
    }

    func take() -> [[UInt8]] { images.withLock { list in defer { list = [] }; return list } }
}

// MARK: - the save

/// Save the image with every Process in it, from worker `w` (its Process
/// running, its registers saved, at a primitive or a poll). Answers the
/// bytes, or nil when another save holds the scheduler or the heap cannot
/// hold the saved stacks. The running system continues as it was.
func saveImageWithProcesses(_ vm: VMPointer, _ w: WorkerPointer, _ form: SaverForm) -> [UInt8]? {
    unsafe schedLock(vm)
    if unsafe vm.pointee.sched.pointee.saveHold {
        unsafe schedUnlock(vm)
        unsafe vm.count(.snapshotsRefused)
        return nil
    }
    unsafe vm.pointee.sched.pointee.saveHold = true
    unsafe vm.pointee.saveHold.pointee.store(true, ordering: .relaxed)
    unsafe schedUnlock(vm)
    // Every poll takes its slow path while the hold lasts (module 4 keeps
    // the bit for a due full collection the same way); the stop that ends
    // the hold clears it.
    unsafe vm.pointee.flag.pointee.bitwiseOr(1, ordering: .relaxed)
    var bytes: [UInt8]? = nil
    var finished = false
    while !finished {
        // Until no other worker that runs Processes is inside the VM: each
        // leaves once its Process left at a poll and nothing is dequeued.
        unsafe pthread_mutex_lock(vm.pointee.safepointLock)
        unsafe waitServicing(vm, w) { unsafe otherRunnersInside(vm, w) }
        unsafe pthread_mutex_unlock(vm.pointee.safepointLock)
        unsafe stopWorld(vm, w, retry: true) { stop in
            // Entering workers hold no Process (nothing is dequeued), so this
            // holds once they are out; checked here, in the stop, all the same.
            if unsafe anotherProcessRuns(vm, w) {
                unsafe vm.count(.snapshotRetries)
                return
            }
            let t0 = nanoseconds()
            bytes = unsafe saveInStop(vm, w, stop, form)
            unsafe vm.count(.snapshotNs, nanoseconds() &- t0)
            unsafe schedLock(vm)
            unsafe vm.pointee.sched.pointee.saveHold = false
            unsafe vm.pointee.saveHold.pointee.store(false, ordering: .relaxed)
            unsafe schedUnlock(vm)
            finished = true
        }
    }
    // Idle workers wait untimed for ready Processes: the release is a
    // transition they wait on, signalled under the scheduler lock.
    unsafe schedLock(vm)
    unsafe pthread_cond_broadcast(vm.pointee.schedCond)
    let main = unsafe anyReadyLocked(vm, main: true)
    unsafe schedUnlock(vm)
    unsafe wake(vm, w, main)
    unsafe vm.count(bytes == nil ? .snapshotsRefused : .snapshots)
    return bytes
}

/// Safepoint mutex held: a worker other than `w` that runs Processes (the
/// main and background workers; the host worker never does) is inside.
func otherRunnersInside(_ vm: VMPointer, _ w: WorkerPointer) -> Bool {
    let me = unsafe w.pointee.index
    for i in unsafe 0..<(vm.pointee.workerCount - 1) where i != me {
        if unsafe vm.pointee.safepoint.pointee.inside[i] { return true }
    }
    return false
}

/// World stopped: a record other than `w`'s runs on a worker.
private func anotherProcessRuns(_ vm: VMPointer, _ w: WorkerPointer) -> Bool {
    unsafe schedLock(vm)
    defer { unsafe schedUnlock(vm) }
    let mine = unsafe w.pointee.record
    for i in unsafe 0..<vm.pointee.sched.pointee.recordHighWater where i != mine {
        let r = unsafe records(vm, i)
        if unsafe r.pointee.process != .none && r.pointee.runningOn >= 0 { return true }
    }
    return false
}

/// One live Process as the stop found it.
private struct LiveProcess {
    let process: Oop
    let record: Int
    /// Words `[0, top]` are saved.
    let top: Int
    /// The saver's own Process (running on `w`).
    let isSaver: Bool
}

/// The save itself, world stopped, no other Process running.
private func saveInStop(_ vm: VMPointer, _ w: WorkerPointer, _ stop: StopContext, _ form: SaverForm) -> [UInt8]? {
    let om = unsafe vm.pointee.om
    let image = unsafe vm.pointee.image
    let nilObj = unsafe vm.pointee.nilObject
    let special = image.specialObjects
    guard om.count(of: special) > UInt64(SpecialObjects.scheduler) else { return nil }  // a version 1 image
    // Signals land before the save, in both systems.
    if unsafe externalPending(vm) { unsafe drainExternal(vm, w) }
    // Garbage stays out of the image; the snapshot needs nothing young
    // (module 1's collection promotes everything first). After it no cycle
    // runs and nothing is young until the world goes: the stores below are
    // plain.
    om.collect(extraRoots: stop.roots())
    let roots = stop.roots()
    let me = unsafe w.pointee.current
    let regs = unsafe w.pointee.interp.regs
    var live: [LiveProcess] = []
    var queueWords = [Oop](repeating: nilObj, count: 2 * Priority.count * Affinity.count)
    unsafe schedLock(vm)
    for i in unsafe 0..<vm.pointee.sched.pointee.recordHighWater {
        let r = unsafe records(vm, i)
        let p = unsafe r.pointee.process
        if p == .none { continue }
        if p == me {
            let top: Int
            switch form {
            case .primitive(let argc): top = regs.sp - argc
            case .poll: top = regs.sp
            }
            live.append(LiveProcess(process: p, record: i, top: top, isSaver: true))
        } else {
            live.append(LiveProcess(process: p, record: i, top: intSlot(om, p, ProcessLayout.sp), isSaver: false))
        }
    }
    for q in 0..<queueWords.count {
        let v = unsafe vm.pointee.queues[q]
        if v != 0 { queueWords[q] = Oop(raw: v) }
    }
    let nextId = unsafe vm.pointee.sched.pointee.nextId
    unsafe schedUnlock(vm)
    unsafe pthread_mutex_lock(vm.pointee.pendingLock)
    let finalization = unsafe vm.pointee.finalization.pointee.semaphore
    unsafe pthread_mutex_unlock(vm.pointee.pendingLock)

    // The scheduler state, hung from special object 8 at once (a root), so
    // a collection an allocation below runs keeps everything built so far.
    let ctx = unsafe w.pointee.interp.context
    func array(_ n: Int) -> Oop? { om.allocate(ctx, classIndex: WellKnown.array, slots: n, fill: nilObj, extraRoots: roots) }
    guard let state = array(SavedScheduler.size) else { return nil }
    om.store(special, SpecialObjects.scheduler, state)
    defer { om.store(special, SpecialObjects.scheduler, nilObj) }
    guard let queues = array(queueWords.count) else { return nil }
    om.store(state, SavedScheduler.queues, queues)
    om.store(state, SavedScheduler.finalization, finalization == .none ? nilObj : finalization)
    om.store(state, SavedScheduler.nextId, Oop(smallInteger: nextId))
    let chunks = (live.count + SavedScheduler.pairsPerChunk - 1) / SavedScheduler.pairsPerChunk
    guard chunks <= Header.maxSlots, let list = array(chunks) else { return nil }
    om.store(state, SavedScheduler.processes, list)
    let trueObj = image.trueObject
    for c in 0..<chunks {
        let pairs = min(SavedScheduler.pairsPerChunk, live.count - c * SavedScheduler.pairsPerChunk)
        guard let lc = array(2 * pairs) else { return nil }
        om.store(list, c, lc)
        for k in 0..<pairs {
            let lp = live[c * SavedScheduler.pairsPerChunk + k]
            // The world is stopped and no Process runs: the stack is still.
            let base = unsafe records(vm, lp.record).pointee.base.unsafelyUnwrapped
            let n = lp.top + 1
            let stackChunks = (n + SavedScheduler.chunkWords - 1) / SavedScheduler.chunkWords
            guard stackChunks <= Header.maxSlots, let stack = array(stackChunks) else { return nil }
            om.store(lc, 2 * k, lp.process)
            om.store(lc, 2 * k + 1, stack)
            for j in 0..<stackChunks {
                let from = j * SavedScheduler.chunkWords
                let count = min(SavedScheduler.chunkWords, n - from)
                guard let ch = array(count) else { return nil }
                om.store(stack, j, ch)
                for i in 0..<count { om.store(ch, i, Oop(raw: unsafe base[from + i])) }
            }
            if lp.isSaver, case .primitive = form {
                // The primitive's answer in the image: true.
                let last = om.load(stack, stackChunks - 1)
                om.store(last, Int(om.count(of: last)) - 1, trueObj)
            }
        }
    }

    // The slots the image sees differently, set now and put back after the
    // snapshot: every saved Process's record is -1; the saver is ready, its
    // registers the resume point, at the back of its ready queue.
    var restore: [(Oop, Int, Oop)] = []
    func patch(_ o: Oop, _ i: Int, _ v: Oop) {
        restore.append((o, i, om.load(o, i)))
        om.store(o, i, v)
    }
    for lp in live { patch(lp.process, ProcessLayout.record, Oop(smallInteger: -1)) }
    if me != .none, let lp = live.first(where: { $0.isSaver }) {
        let pc: Int
        switch form {
        case .primitive: pc = regs.pc
        case .poll(let rewind): pc = regs.pc &- rewind
        }
        if regs.hdr == 0 {
            // At the bottom of the Process: no frame (see the loader's rule).
            patch(me, ProcessLayout.pc, Oop(smallInteger: 0))
        } else {
            patch(me, ProcessLayout.pc, Oop(smallInteger: Int64(pc)))
        }
        patch(me, ProcessLayout.sp, Oop(smallInteger: Int64(lp.top)))
        patch(me, ProcessLayout.fp, Oop(smallInteger: Int64(regs.fp)))
        patch(me, ProcessLayout.hdr, Oop(smallInteger: Int64(regs.hdr)))
        patch(me, ProcessLayout.state, Oop(smallInteger: ProcessState.ready.rawValue))
        let q = queueIndex(main: intSlot(om, me, ProcessLayout.affinity) == Affinity.main,
                           priority: intSlot(om, me, ProcessLayout.priority))
        let tailAt = Priority.count * Affinity.count + q
        if queueWords[q] == nilObj {
            queueWords[q] = me
        } else {
            patch(queueWords[tailAt], ProcessLayout.next, me)
        }
        queueWords[tailAt] = me
        if case .primitive = form { om.store(state, SavedScheduler.saver, me) }
    }
    for (i, v) in queueWords.enumerated() { om.store(queues, i, v) }
    let snap = om.snapshot()
    for (o, i, v) in restore.reversed() { om.store(o, i, v) }
    return image.encodedImage(snapshot: snap)
}

// MARK: - primitive 142

/// `Smalltalk primSnapshot: aStringOrNil` (primitive 142): save the image
/// with every Process in it, to the file the String names, or, for nil, to
/// the VM's host (`VM.takeSavedImages`). Answers false here; the image
/// resumes this Process after the send with true. Fails outside a VM, when
/// another save is in progress, when the stacks do not fit the heap, or
/// when the file cannot be written.
func savePrimitive(_ m: Machine, _ c: PrimitiveCall) -> Oop {
    let w = unsafe workerOf(m.state)
    guard let vm = unsafe w.pointee.vm, unsafe w.pointee.current != .none, c.argc == 1 else { return .none }
    var path: String? = nil
    if c.arg0 != m.nilObject {
        guard c.arg0.isObject, m.om.isBytes(c.arg0),
              m.classIndex(of: c.arg0) == WellKnown.string || m.classIndex(of: c.arg0) == WellKnown.symbol,
              let s = String(validating: m.om.bytes(of: c.arg0), as: UTF8.self), !s.isEmpty else { return .none }
        path = s
    }
    guard let bytes = unsafe saveImageWithProcesses(vm, w, .primitive(argc: c.argc)) else { return .none }
    if let path {
        // A long write touches no heap object: a blocking region for module
        // 7's rounds.
        unsafe blockingBegin(vm, w)
        let ok = (try? Data(bytes).write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
        unsafe blockingEnd(vm, w)
        if !ok { return .none }
    } else {
        unsafe vm.pointee.savedImages.add(bytes)
    }
    return m.falseObject
}

// MARK: - the poll trigger (tests, `kajo run --snapshot-at`)

/// At a slow poll with `VMConfig.snapshotAtPoll` set: the n-th one (VM
/// wide) saves, its Process saved as preempted at this poll. Registers saved.
/// Out of line: the save's Swift arrays stay out of `pollSlow` (ARC).
@inline(never)
func snapshotAtPoll(_ vm: VMPointer, _ w: WorkerPointer, rewind: Int) {
    let n = unsafe vm.pointee.slowPolls.pointee.wrappingAdd(1, ordering: .relaxed).newValue
    guard unsafe n == vm.pointee.config.snapshotAtPoll else { return }
    if let b = unsafe saveImageWithProcesses(vm, w, .poll(rewind: rewind)) { unsafe vm.pointee.savedImages.add(b) }
}

// MARK: - the resume

/// The number of saved Processes in a verified image.
func savedProcessCount(_ image: Image) -> Int {
    let om = image.om
    let state = image.savedScheduler
    if state == image.nilObject { return 0 }
    let list = om.load(state, SavedScheduler.processes)
    return (0..<Int(om.count(of: list))).reduce(0) { $0 + Int(om.count(of: om.load(list, $1))) / 2 }
}

/// Install a verified image's saved Processes into a VM no worker runs
/// yet, from the host worker `w` inside the VM: records, stacks, ready
/// queues, the finalization Semaphore, the next id. Answers the Processes
/// (in list order) and the saver (nil if none).
func installSavedProcesses(_ vm: VMPointer, _ w: WorkerPointer) -> (processes: [Oop], saver: Oop) {
    let image = unsafe vm.pointee.image
    let om = image.om
    let nilObj = image.nilObject
    let state = image.savedScheduler
    if state == nilObj { return ([], nilObj) }
    var installed: [Oop] = []
    let list = om.load(state, SavedScheduler.processes)
    unsafe schedLock(vm)
    for c in 0..<Int(om.count(of: list)) {
        let lc = om.load(list, c)
        for k in 0..<Int(om.count(of: lc) / 2) {
            let p = om.load(lc, 2 * k), stack = om.load(lc, 2 * k + 1)
            let sp = intSlot(om, p, ProcessLayout.sp)
            let n = sp + 1
            func word(_ i: Int) -> Oop {
                om.load(om.load(stack, i / SavedScheduler.chunkWords), i % SavedScheduler.chunkWords)
            }
            var words = unsafe vm.pointee.config.stackWords
            let needed = requiredStackWords(om, p, sp: sp, word)
            while words < needed { words *= 2 }
            let base = UnsafeMutablePointer<UInt64>.allocate(capacity: words)  // only [0, sp] is ever read
            for i in 0..<n { unsafe base[i] = word(i).raw }
            var ri = unsafe vm.pointee.sched.pointee.recordFree
            if ri >= 0 {
                unsafe vm.pointee.sched.pointee.recordFree = records(vm, ri).pointee.nextFree
            } else {
                ri = unsafe vm.pointee.sched.pointee.recordHighWater
                precondition(unsafe ri < vm.pointee.config.recordCapacity, "installSavedProcesses: no record left")
                unsafe vm.pointee.sched.pointee.recordHighWater += 1
            }
            unsafe records(vm, ri).pointee = ProcessRecord(process: p, base: base, end: base + words)
            if intSlot(om, p, ProcessLayout.state) == Int(ProcessState.ready.rawValue) {
                unsafe records(vm, ri).pointee.runnableSince = ticks()
            }
            unsafe youngNewRecordLocked(vm, ri)
            unsafe setIntSlot(w, p, ProcessLayout.record, ri)
            unsafe vm.pointee.sched.pointee.liveProcesses += 1
            installed.append(p)
        }
    }
    let queues = om.load(state, SavedScheduler.queues)
    for q in 0..<(2 * Priority.count * Affinity.count) {
        let v = om.load(queues, q)
        unsafe vm.pointee.queues[q] = v == nilObj ? 0 : v.raw
    }
    unsafe vm.pointee.sched.pointee.nextId = max(unsafe vm.pointee.sched.pointee.nextId,
                                                 om.load(state, SavedScheduler.nextId).smallIntegerValue)
    unsafe schedUnlock(vm)
    let saver = om.load(state, SavedScheduler.saver)
    let fin = om.load(state, SavedScheduler.finalization)
    if fin != nilObj {
        let h = unsafe registerPending(vm, fin)
        precondition(h >= 0, "installSavedProcesses: the pending-root table is full")
        unsafe pthread_mutex_lock(vm.pointee.pendingLock)
        unsafe vm.pointee.finalization.pointee = FinalizationState(semaphore: fin, handle: h)
        unsafe pthread_mutex_unlock(vm.pointee.pendingLock)
        // Ephemerons queued before the save: their signal was not saved.
        if om.finalizationQueueCount > 0 { unsafe VMRef(vm: vm).signalFromOutside(fin, handle: nil) }
    }
    // The chunks are garbage from here on.
    unsafe clearingStore(w, image.specialObjects, SpecialObjects.scheduler, nilObj)
    unsafe vm.count(.processesResumed, UInt64(installed.count))
    return (installed, saver)
}

/// Words a resumed stack needs: past sp, and past every frame's deepest
/// operand (module 2's activation check: a frame's method may push
/// `maxStack` words and a doesNotUnderstand: one more), with module 3's
/// headroom. The frames are verified.
private func requiredStackWords(_ om: ObjectMemory, _ p: Oop, sp: Int, _ word: (Int) -> Oop) -> Int {
    var need = sp + 64
    func extent(_ m: Oop, hdr: Int) -> Int {
        hdr + Frame.headerWords + Int(om.load(m, MethodLayout.maxStack).smallIntegerValue) + 8
    }
    let pc = intSlot(om, p, ProcessLayout.pc), hdr = intSlot(om, p, ProcessLayout.hdr)
    if pc < 0 {
        let m = word(0)
        need = max(need, sp + Int(om.load(m, MethodLayout.temps).smallIntegerValue) + extent(m, hdr: 0))
        return need
    }
    var h = hdr
    while h > 0 {
        need = max(need, extent(word(h + Frame.method), hdr: h))
        if word(h + Frame.callerFP) == Oop(smallInteger: 0) { break }
        h = Int(word(h + Frame.callerHdr).smallIntegerValue)
    }
    return need
}
