// Processes, ready queues, Semaphores, the worker loops and the main-thread
// turn (SPEC.md "Process object", "Workers", "Scheduler", "Budget",
// "Hop to main"). Everything that links a Process into a list holds
// `schedLock`; nothing allocates or parks while holding it.

import Darwin
import Synchronization

// MARK: - locking

@inline(__always)
func schedLock(_ vm: VMRef) {
    if pthread_mutex_trylock(vm.pointee.schedLock) != 0 {
        let t0 = now()
        pthread_mutex_lock(vm.pointee.schedLock)
        vm.add(.schedContended, 1)
        vm.add(.schedWaitNs, now() &- t0)
    }
    vm.add(.schedLocks, 1)
}

@inline(__always)
func schedUnlock(_ vm: VMRef) {
    pthread_mutex_unlock(vm.pointee.schedLock)
}

// MARK: - small accessors

@inline(__always) private func intSlot(_ vm: VMRef, _ o: Oop, _ i: Int) -> Int {
    Int(intVal(vm.pointee.om.slot(o, i)))
}
@inline(__always) private func setInt(_ vm: VMRef, _ o: Oop, _ i: Int, _ v: Int) {
    vm.pointee.om.setSlot(o, i, mkInt(Int64(v)))
}
@inline(__always) private func rec(_ vm: VMRef, _ p: Oop) -> UnsafeMutablePointer<ProcRec> {
    vm.pointee.recs + intSlot(vm, p, pRec)
}
@inline(__always) private func isMainAffine(_ vm: VMRef, _ p: Oop) -> Bool { intSlot(vm, p, pAffinity) == 1 }

func currentPriority(_ vm: VMRef, _ w: WorkerRef) -> Int {
    w.pointee.current == 0 ? 1 : intSlot(vm, w.pointee.current, pPriority)
}

public func symbolName(_ vm: VMRef, _ sym: Oop) -> String {
    if isInt(sym) || sym == 0 { return "?" }
    let id = Int(intVal(vm.pointee.om.slot(sym, 0)))
    return id >= 0 && id < vm.pointee.symbolNames.count ? vm.pointee.symbolNames[id] : "?"
}

// MARK: - ready queues (schedLock held)

@inline(__always) private func qIndex(_ main: Bool, _ prio: Int) -> Int { (main ? priorities : 0) + prio }

private func appendLocked(_ vm: VMRef, _ headSlot: UnsafeMutablePointer<Oop>, _ tailSlot: UnsafeMutablePointer<Oop>, _ p: Oop) {
    let om = vm.pointee.om
    om.setSlot(p, pNext, vm.pointee.nilObj)
    if headSlot.pointee == 0 || headSlot.pointee == vm.pointee.nilObj {
        headSlot.pointee = p
    } else {
        om.setSlot(tailSlot.pointee, pNext, p)
    }
    tailSlot.pointee = p
}

/// Put `p` at the back of its ready queue. Answers true if the main worker
/// should be woken. Wakes an idle background worker for "any" Processes.
@discardableResult
private func makeReadyLocked(_ vm: VMRef, _ p: Oop, fromBlocked: Bool) -> Bool {
    let main = isMainAffine(vm, p)
    let q = qIndex(main, intSlot(vm, p, pPriority))
    setInt(vm, p, pState, Int(stReady))
    let r = rec(vm, p)
    if fromBlocked && r.pointee.runnableSince == 0 { r.pointee.runnableSince = ticks() }
    appendLocked(vm, vm.pointee.ready + q, vm.pointee.ready + 2 * priorities + q, p)
    if main { return true }
    if vm.pointee.sched.pointee.idleWorkers > 0 { pthread_cond_signal(vm.pointee.schedCond) }
    return false
}

/// Take the next ready Process and mark it running on `w` (state and
/// `runningOn` are guarded by schedLock, so they are set here).
private func dequeueLocked(_ vm: VMRef, main: Bool, minPriority: Int, for w: WorkerRef) -> Oop {
    let om = vm.pointee.om
    let nilObj = vm.pointee.nilObj
    var prio = priorities - 1
    while prio >= minPriority {
        let q = qIndex(main, prio)
        let head = vm.pointee.ready[q]
        if head != 0 && head != nilObj {
            let next = om.slot(head, pNext)
            vm.pointee.ready[q] = next == nilObj ? 0 : next
            if next == nilObj { vm.pointee.ready[2 * priorities + q] = 0 }
            om.setSlot(head, pNext, nilObj)
            setInt(vm, head, pState, Int(stRunning))
            rec(vm, head).pointee.runningOn = w.pointee.id
            return head
        }
        prio -= 1
    }
    return 0
}

private func anyReadyLocked(_ vm: VMRef, main: Bool) -> Bool {
    for prio in 0..<priorities where vm.pointee.ready[qIndex(main, prio)] != 0 { return true }
    return false
}

/// Unlink `p` from a singly linked list given by head/tail slots.
private func unlinkLocked(_ vm: VMRef, _ head: UnsafeMutablePointer<Oop>, _ tail: UnsafeMutablePointer<Oop>, _ p: Oop) -> Bool {
    let om = vm.pointee.om
    let nilObj = vm.pointee.nilObj
    var prev: Oop = 0
    var cur = head.pointee
    while cur != 0 && cur != nilObj {
        let next = om.slot(cur, pNext)
        if cur == p {
            if prev == 0 { head.pointee = next == nilObj ? 0 : next } else { om.setSlot(prev, pNext, next) }
            if tail.pointee == p { tail.pointee = prev }
            om.setSlot(p, pNext, nilObj)
            return true
        }
        prev = cur
        cur = next
    }
    return false
}

private func wake(_ vm: VMRef, _ w: WorkerRef?, _ needMain: Bool) {
    if needMain && !(w?.pointee.isMain ?? false), let h = vm.pointee.wakeMain { h(vm.pointee.hookCtx) }
}

// MARK: - process creation and termination

/// Allocate a Process running `recv sel` (with `arg` if the method takes
/// one) and make it ready. `recv`/`arg` must be rooted by the caller
/// (on a stack or in `vm.roots`): the allocation may collect.
func createProcess(_ vm: VMRef, _ w: WorkerRef, _ recv: Oop, _ sel: Oop, _ arg: Oop, priority: Int,
                   main: Bool, exitSem: Oop) -> Oop {
    let om = vm.pointee.om
    let method = lookup(vm, om.classIndexOf(recv), sel)
    if method == 0 || om.slot(method, mPrim) != mkInt(0) { fatal("fork: no method \(symbolName(vm, sel))") }
    let argc = Int(intVal(om.slot(method, mArgc)))
    if argc > 1 { fatal("fork: method takes more than one argument") }
    let p = alloc(vm, w, ciProcess, processSlots, false)
    let base = UnsafeMutablePointer<UInt64>.allocate(capacity: stackWords) // not initialised (SPEC.md)
    buildBottomFrame(vm, p, base, recv, method, argc == 1 ? [arg] : [])
    let prio = max(0, min(priorities - 1, priority))
    setInt(vm, p, pPriority, prio)
    setInt(vm, p, pAffinity, main ? 1 : 0)
    om.setSlot(p, pExitSem, exitSem)
    schedLock(vm)
    var idx = vm.pointee.sched.pointee.recFree
    if idx >= 0 {
        vm.pointee.sched.pointee.recFree = vm.pointee.recs[idx].nextFree
    } else {
        idx = vm.pointee.sched.pointee.recHwm
        if idx >= maxProcesses { fatal("too many Processes") }
        vm.pointee.sched.pointee.recHwm += 1
    }
    vm.pointee.recs[idx] = ProcRec(process: p, base: base, end: base + stackWords)
    setInt(vm, p, pRec, idx)
    let id = vm.pointee.sched.pointee.nextProcessId
    vm.pointee.sched.pointee.nextProcessId += 1
    om.setSlot(p, pId, mkInt(id))
    vm.pointee.sched.pointee.liveProcesses += 1
    let needMain = makeReadyLocked(vm, p, fromBlocked: true)
    schedUnlock(vm)
    vm.add(.forks, 1)
    wake(vm, w, needMain)
    return p
}

/// Terminate a Process that is not running (its registers are saved or it
/// was never started) or that just left `run` on `w`. Frees its stack and
/// record, signals its exit Semaphore.
private func finishLocked(_ vm: VMRef, _ p: Oop, _ result: Oop) -> (UnsafeMutablePointer<UInt64>?, Bool) {
    let om = vm.pointee.om
    let r = rec(vm, p)
    let base = r.pointee.base
    let id = Int(intVal(om.slot(p, pId)))
    if id < resultCapacity { vm.pointee.results[id] = result }
    om.setSlot(p, pResult, result)
    setInt(vm, p, pState, Int(stTerminated))
    // The record's stack is gone: point the saved sp below the base so no
    // stale reader scans it (records are only scanned while live anyway).
    let idx = intSlot(vm, p, pRec)
    vm.pointee.recs[idx] = ProcRec()
    vm.pointee.recs[idx].nextFree = vm.pointee.sched.pointee.recFree
    vm.pointee.sched.pointee.recFree = idx
    vm.pointee.sched.pointee.liveProcesses -= 1
    if vm.pointee.sched.pointee.liveProcesses == 0 { pthread_cond_broadcast(vm.pointee.doneCond) }
    var needMain = false
    let sem = om.slot(p, pExitSem)
    if sem != vm.pointee.nilObj && !isInt(sem) { needMain = signalLocked(vm, sem) }
    return (base, needMain)
}

func terminateStopped(_ vm: VMRef, _ w: WorkerRef?, _ p: Oop, _ result: Oop, detaching: Bool = false) {
    schedLock(vm)
    if detaching, let w { detach(vm, w) }
    let (base, needMain) = finishLocked(vm, p, result)
    schedUnlock(vm)
    base?.deallocate()
    vm.add(.terminations, 1)
    wake(vm, w, needMain)
}

// MARK: - suspension

/// Save the running Process's registers (the worker flushed them) and
/// detach it from the worker. After this the Process may be published to a
/// queue; the worker must not touch its stack again.
private func saveCurrent(_ vm: VMRef, _ w: WorkerRef, sp: UnsafeMutablePointer<UInt64>, pc: UInt) {
    let om = vm.pointee.om
    let p = w.pointee.current
    om.setSlot(p, pSp, tagAddr(UnsafePointer(sp)))
    om.setSlot(p, pPc, mkInt(Int64(Int(bitPattern: pc))))
    om.setSlot(p, pFp, tagAddr(UnsafePointer(w.pointee.fp)))
    om.setSlot(p, pHdr, tagAddr(UnsafePointer(w.pointee.hdr)))
    detach(vm, w)
}

private func detach(_ vm: VMRef, _ w: WorkerRef) {
    if w.pointee.rec >= 0 { vm.pointee.recs[w.pointee.rec].runningOn = -1 }
    w.pointee.current = 0
    w.pointee.rec = -1
    w.pointee.stack = w.pointee.dummy
    w.pointee.stackEnd = w.pointee.dummy + 16
    w.pointee.sp = w.pointee.dummy
}

/// A primitive completes and the Process suspends after the send: pop the
/// arguments, push `result`, save. Called with schedLock held.
private func suspendAfterPrim(_ vm: VMRef, _ w: WorkerRef, _ argc: Int, _ result: Oop) {
    let sp = w.pointee.sp - argc
    sp.pointee = result
    saveCurrent(vm, w, sp: sp, pc: w.pointee.pc)
    w.pointee.leave = Leave.blocked
}

/// Called from the poll slow path every N polls (SPEC.md "Budget").
func budgetCheck(_ vm: VMRef, _ w: WorkerRef) -> Bool {
    if vm.pointee.extHead.pointee.load(ordering: .relaxed) != 0 { drainExternal(vm, w) }
    let kill = vm.pointee.interrupts[w.pointee.id].load(ordering: .acquiring)
    if kill != 0 {
        vm.pointee.interrupts[w.pointee.id].store(0, ordering: .relaxed)
        if kill - 1 == w.pointee.rec {
            w.pointee.leave = Leave.killed
            return true
        }
    }
    if ticks() < w.pointee.deadline { return false }
    // Preempt: back of its priority's queue.
    let p = w.pointee.current
    schedLock(vm)
    saveCurrent(vm, w, sp: w.pointee.sp, pc: w.pointee.pc)
    let needMain = makeReadyLocked(vm, p, fromBlocked: false)
    schedUnlock(vm)
    w.pointee.leave = Leave.preempted
    w.pointee.preemptions &+= 1
    vm.add(.preemptions, 1)
    wake(vm, w, needMain)
    return true
}

// MARK: - primitives

func primYield(_ vm: VMRef, _ w: WorkerRef, _ argc: Int) -> Oop {
    let p = w.pointee.current
    schedLock(vm)
    suspendAfterPrim(vm, w, argc, vm.pointee.nilObj)
    let needMain = makeReadyLocked(vm, p, fromBlocked: false)
    schedUnlock(vm)
    vm.add(.yields, 1)
    wake(vm, w, needMain)
    return vm.pointee.nilObj
}

func primWait(_ vm: VMRef, _ w: WorkerRef, _ sem: Oop, _ argc: Int) -> Oop {
    let om = vm.pointee.om
    schedLock(vm)
    let excess = intSlot(vm, sem, sExcess)
    if excess > 0 {
        setInt(vm, sem, sExcess, excess - 1)
        schedUnlock(vm)
        return sem
    }
    let p = w.pointee.current
    let r = rec(vm, p)
    r.pointee.runnableSince = 0
    suspendAfterPrim(vm, w, argc, sem)
    setInt(vm, p, pState, Int(stWaiting))
    om.setSlot(p, pWaitingOn, sem)
    let nilObj = vm.pointee.nilObj
    om.setSlot(p, pNext, nilObj)
    let last = om.slot(sem, sLast)
    if last == nilObj { om.setSlot(sem, sFirst, p) } else { om.setSlot(last, pNext, p) }
    om.setSlot(sem, sLast, p)
    schedUnlock(vm)
    vm.add(.waits, 1)
    return sem
}

/// Signal with schedLock held. Answers true if the main worker should wake.
private func signalLocked(_ vm: VMRef, _ sem: Oop) -> Bool {
    let om = vm.pointee.om
    let nilObj = vm.pointee.nilObj
    let first = om.slot(sem, sFirst)
    if first == nilObj {
        setInt(vm, sem, sExcess, intSlot(vm, sem, sExcess) + 1)
        return false
    }
    let next = om.slot(first, pNext)
    om.setSlot(sem, sFirst, next)
    if next == nilObj { om.setSlot(sem, sLast, nilObj) }
    om.setSlot(first, pNext, nilObj)
    om.setSlot(first, pWaitingOn, nilObj)
    return makeReadyLocked(vm, first, fromBlocked: true)
}

func semaphoreSignal(_ vm: VMRef, _ w: WorkerRef?, _ sem: Oop) {
    schedLock(vm)
    let needMain = signalLocked(vm, sem)
    schedUnlock(vm)
    vm.add(.signals, 1)
    wake(vm, w, needMain)
}

func primTerminate(_ vm: VMRef, _ w: WorkerRef, _ p: Oop, _ argc: Int) -> Oop {
    let om = vm.pointee.om
    if p == w.pointee.current {
        w.pointee.leave = Leave.terminated
        w.pointee.result = vm.pointee.nilObj
        return p
    }
    schedLock(vm)
    let state = Int64(intSlot(vm, p, pState))
    if state == stTerminated { schedUnlock(vm); return p }
    let r = rec(vm, p)
    if r.pointee.runningOn >= 0 {
        vm.pointee.interrupts[r.pointee.runningOn].store(intSlot(vm, p, pRec) + 1, ordering: .releasing)
        schedUnlock(vm)
        return p
    }
    if state == stWaiting {
        let sem = om.slot(p, pWaitingOn)
        let head = UnsafeMutablePointer<Oop>.allocate(capacity: 2)
        head[0] = om.slot(sem, sFirst); head[1] = om.slot(sem, sLast)
        _ = unlinkLocked(vm, head, head + 1, p)
        om.setSlot(sem, sFirst, head[0] == 0 ? vm.pointee.nilObj : head[0])
        om.setSlot(sem, sLast, head[1] == 0 ? vm.pointee.nilObj : head[1])
        head.deallocate()
    } else {
        let q = qIndex(isMainAffine(vm, p), intSlot(vm, p, pPriority))
        _ = unlinkLocked(vm, vm.pointee.ready + q, vm.pointee.ready + 2 * priorities + q, p)
    }
    let (base, needMain) = finishLocked(vm, p, vm.pointee.nilObj)
    schedUnlock(vm)
    base?.deallocate()
    vm.add(.terminations, 1)
    vm.add(.kills, 1)
    wake(vm, w, needMain)
    return p
}

/// UI primitive: on main call the shell; off main hop (SPEC.md "Hop to main").
func primUI(_ vm: VMRef, _ w: WorkerRef, _ kind: Int, _ value: Oop, _ argc: Int) -> Oop {
    if w.pointee.isMain {
        vm.add(.uiPrims, 1)
        if kind == 0 && w.pointee.currentEventTicks != 0 {
            vm.pointee.eventLatency.pointee.add(ticksToNs(ticks() &- w.pointee.currentEventTicks))
            w.pointee.currentEventTicks = 0
        }
        guard let h = vm.pointee.uiHook else { return isInt(value) ? value : mkInt(0) }
        return mkInt(h(vm.pointee.hookCtx, kind, isInt(value) ? intVal(value) : 0))
    }
    // Off main: retry the send on the main worker.
    let p = w.pointee.current
    schedLock(vm)
    let r = rec(vm, p)
    r.pointee.hopStart = ticks()
    r.pointee.runnableSince = r.pointee.hopStart
    saveCurrent(vm, w, sp: w.pointee.sp, pc: w.pointee.pc &- 3) // pc at the send
    setInt(vm, p, pAffinity, 1)
    _ = makeReadyLocked(vm, p, fromBlocked: false)
    schedUnlock(vm)
    w.pointee.leave = Leave.blocked
    vm.add(.hops, 1)
    wake(vm, w, true)
    return vm.pointee.nilObj
}

func primDetach(_ vm: VMRef, _ w: WorkerRef, _ argc: Int) -> Oop {
    let p = w.pointee.current
    schedLock(vm)
    rec(vm, p).pointee.runnableSince = 0
    suspendAfterPrim(vm, w, argc, vm.pointee.nilObj)
    setInt(vm, p, pAffinity, 0)
    _ = makeReadyLocked(vm, p, fromBlocked: false)
    schedUnlock(vm)
    vm.add(.detaches, 1)
    return vm.pointee.nilObj
}

func primNextEvent(_ vm: VMRef, _ w: WorkerRef) -> Oop {
    pthread_mutex_lock(vm.pointee.eventLock)
    if vm.pointee.evq.pointee.head == vm.pointee.evq.pointee.tail {
        pthread_mutex_unlock(vm.pointee.eventLock)
        return vm.pointee.nilObj
    }
    let e = vm.pointee.events[vm.pointee.evq.pointee.head & (eventCapacity - 1)]
    vm.pointee.evq.pointee.head &+= 1
    pthread_mutex_unlock(vm.pointee.eventLock)
    w.pointee.currentEventTicks = e.ticks
    return mkInt((e.kind << 32) | (e.value & 0xFFFF_FFFF))
}

// MARK: - running Processes on a worker

/// Run `p` on `w` until it leaves. Handles termination.
private func runSlice(_ vm: VMRef, _ w: WorkerRef, _ p: Oop) {
    let om = vm.pointee.om
    let ri = intSlot(vm, p, pRec)
    let r = vm.pointee.recs + ri
    w.pointee.current = p
    w.pointee.rec = ri
    w.pointee.stack = r.pointee.base.unsafelyUnwrapped
    w.pointee.stackEnd = r.pointee.end.unsafelyUnwrapped
    w.pointee.sp = untagPtr(om.slot(p, pSp), UInt64.self)
    w.pointee.leave = Leave.none
    w.pointee.countdown = w.pointee.pollEvery
    w.pointee.slices &+= 1
    resumeCurrent(vm, w)
    switch w.pointee.leave {
    case Leave.terminated, Leave.overflow, Leave.killed:
        let reason = w.pointee.leave
        if reason == Leave.overflow {
            let n = vm.metric(.overflows)
            vm.add(.overflows, 1)
            if n < 3 { FileHandleStderr.write("kajo: stack overflow, Process \(intVal(om.slot(p, pId))) terminated\n") }
        }
        let result = reason == Leave.terminated ? w.pointee.result : vm.pointee.nilObj
        terminateStopped(vm, w, p, result, detaching: true)
    default:
        break // saved and queued by whoever suspended it
    }
}

/// Background worker thread body: run "any" Processes until shutdown.
public func backgroundLoop(_ vm: VMRef, _ w: WorkerRef) {
    enterVM(vm, w)
    while true {
        if vm.pointee.gcRequested.load(ordering: .relaxed) { safepoint(vm, w) }
        if vm.pointee.extHead.pointee.load(ordering: .relaxed) != 0 { drainExternal(vm, w) }
        schedLock(vm)
        let p = dequeueLocked(vm, main: false, minPriority: 0, for: w)
        if p != 0 {
            schedUnlock(vm)
            w.pointee.deadline = vm.pointee.sliceNs == 0 ? .max : ticks() &+ nsToTicks(vm.pointee.sliceNs)
            runSlice(vm, w, p)
            continue
        }
        if vm.pointee.sched.pointee.shutdown { schedUnlock(vm); break }
        vm.pointee.sched.pointee.idleWorkers += 1
        schedUnlock(vm)
        leaveVM(vm, w)
        let t0 = now()
        schedLock(vm)
        while !vm.pointee.sched.pointee.shutdown && !anyReadyLocked(vm, main: false)
                && vm.pointee.extHead.pointee.load(ordering: .relaxed) == 0 {
            vm.add(.idleWaits, 1)
            pthread_cond_wait(vm.pointee.schedCond, vm.pointee.schedLock)
        }
        vm.pointee.sched.pointee.idleWorkers -= 1
        schedUnlock(vm)
        let dt = now() &- t0
        w.pointee.idleNs &+= dt
        vm.add(.idleNs, dt)
        enterVM(vm, w)
    }
    leaveVM(vm, w)
}

public struct TurnStats {
    public var ns: UInt64 = 0
    public var enterWaitNs: UInt64 = 0
    public var parkedNs: UInt64 = 0
    public var slices = 0
    public var preempted = false
}

/// One main-thread turn (SPEC.md "Shell turns"). Call on the main worker's
/// thread only.
public func runMain(_ vm: VMRef, budgetNs: UInt64, minPriority: Int = 0) -> TurnStats {
    let w = worker(vm, 0)
    var st = TurnStats()
    let t0 = now()
    st.enterWaitNs = enterVM(vm, w)
    if st.enterWaitNs > 0 { vm.pointee.mainEnterWait.pointee.add(st.enterWaitNs) }
    vm.add(.mainEnters, 1)
    vm.add(.mainEnterWaitNs, st.enterWaitNs)
    let parked0 = w.pointee.parkedNs
    if vm.pointee.extHead.pointee.load(ordering: .relaxed) != 0 { drainExternal(vm, w) }
    w.pointee.deadline = vm.pointee.mainBudgetEnabled ? ticks() &+ nsToTicks(budgetNs) : .max
    w.pointee.minPriority = minPriority
    while ticks() < w.pointee.deadline {
        if vm.pointee.gcRequested.load(ordering: .relaxed) { safepoint(vm, w) }
        schedLock(vm)
        let p = dequeueLocked(vm, main: true, minPriority: minPriority, for: w)
        schedUnlock(vm)
        if p == 0 { break }
        let r = rec(vm, p)
        let start = ticks()
        let hopped = r.pointee.hopStart != 0
        if hopped {
            vm.pointee.hopLatency.pointee.add(ticksToNs(start &- r.pointee.hopStart))
            r.pointee.hopStart = 0
        }
        vm.pointee.mainBusyRec.store(intSlot(vm, p, pRec), ordering: .relaxed)
        vm.pointee.mainBusyId.store(intVal(vm.pointee.om.slot(p, pId)), ordering: .relaxed)
        vm.pointee.mainBusySince.store(start, ordering: .releasing)
        runSlice(vm, w, p)
        vm.pointee.mainBusySince.store(0, ordering: .releasing)
        if hopped { vm.pointee.mainPerHop.pointee.add(ticksToNs(ticks() &- start)) }
        st.slices += 1
        if w.pointee.leave == Leave.preempted { st.preempted = true; break }
    }
    st.parkedNs = w.pointee.parkedNs &- parked0
    leaveVM(vm, w)
    st.ns = now() &- t0
    return st
}

/// Any main-affine Process runnable for longer than `limitNs` gets one
/// report through `stuckHook` (SPEC.md "Stuck report"). Main thread, outside
/// a turn.
public func checkStuck(_ vm: VMRef, limitNs: UInt64) {
    let now = ticks()
    let limit = nsToTicks(limitNs)
    var reports: [(Int64, String, Double)] = []
    let om = vm.pointee.om
    schedLock(vm)
    for prio in 0..<priorities {
        var p = vm.pointee.ready[qIndex(true, prio)]
        while p != 0 && p != vm.pointee.nilObj {
            let r = rec(vm, p)
            if r.pointee.runnableSince != 0 && !r.pointee.stuckReported && now &- r.pointee.runnableSince > limit {
                r.pointee.stuckReported = true
                let hdr = untagPtr(om.slot(p, pHdr), UInt64.self)
                reports.append((intVal(om.slot(p, pId)), symbolName(vm, om.slot(hdr[0], mSelector)),
                                Double(ticksToNs(now &- r.pointee.runnableSince)) / 1e6))
            }
            p = om.slot(p, pNext)
        }
    }
    schedUnlock(vm)
    for (id, sel, ms) in reports {
        vm.add(.stuckReports, 1)
        if let h = vm.pointee.stuckHook { sel.withCString { h(vm.pointee.hookCtx, id, $0, ms) } }
    }
}

/// Off-main watchdog view (S7): ms the main worker has been inside one
/// Process slice, 0 if none.
public func mainBusyMs(_ vm: VMRef) -> Double {
    let since = vm.pointee.mainBusySince.load(ordering: .acquiring)
    return since == 0 ? 0 : Double(ticksToNs(ticks() &- since)) / 1e6
}

/// Ask the main worker to terminate the Process it is running (watchdog).
public func interruptMain(_ vm: VMRef) {
    let r = vm.pointee.mainBusyRec.load(ordering: .relaxed)
    if r >= 0 { vm.pointee.interrupts[0].store(r + 1, ordering: .releasing) }
}

// MARK: - host API

/// Test hook: on the calling thread, run one "any" Process on worker `w`
/// (which must have no thread of its own) for at most `budgetNs`. Answers
/// false if nothing was ready.
public func runOneSlice(_ vm: VMRef, _ w: WorkerRef, budgetNs: UInt64 = .max) -> Bool {
    enterVM(vm, w)
    if vm.pointee.extHead.pointee.load(ordering: .relaxed) != 0 { drainExternal(vm, w) }
    schedLock(vm)
    let p = dequeueLocked(vm, main: false, minPriority: 0, for: w)
    schedUnlock(vm)
    if p != 0 {
        w.pointee.deadline = budgetNs == .max ? .max : ticks() &+ nsToTicks(budgetNs)
        runSlice(vm, w, p)
    }
    leaveVM(vm, w)
    return p != 0
}

/// Terminate a Process from the host (kills it at its next budget check if
/// it is running).
public func hostTerminate(_ vm: VMRef, _ p: Oop) {
    let w = hostWorker(vm)
    enterVM(vm, w)
    _ = primTerminate(vm, w, p, 0)
    leaveVM(vm, w)
}

public func processState(_ vm: VMRef, _ p: Oop) -> Int64 {
    schedLock(vm)
    defer { schedUnlock(vm) }
    return intVal(vm.pointee.om.slot(p, pState))
}

/// The host's worker (last registered); use it only from the host thread.
private func hostWorker(_ vm: VMRef) -> WorkerRef { worker(vm, vm.pointee.workerCount - 1) }

/// Fork from the host: enters the VM on the host worker.
@discardableResult
public func spawn(_ vm: VMRef, _ recv: Oop, _ sel: Oop, _ arg: Oop, priority: Int = 1, main: Bool = false,
                  exitSem: Oop = 0) -> Oop {
    let w = hostWorker(vm)
    enterVM(vm, w)
    vm.pointee.hostRoots[0] = recv
    vm.pointee.hostRoots[1] = arg
    vm.pointee.hostRoots[2] = exitSem
    let p = createProcess(vm, w, recv, sel, arg, priority: priority, main: main,
                          exitSem: exitSem == 0 ? vm.pointee.nilObj : exitSem)
    vm.pointee.hostRoots.update(repeating: 0, count: 3)
    leaveVM(vm, w)
    return p
}

/// Allocate from the host (a Semaphore, an Array...). Store the result in a
/// global or another root before the next allocation.
public func hostNewSemaphore(_ vm: VMRef) -> Oop {
    let w = hostWorker(vm)
    enterVM(vm, w)
    let s = alloc(vm, w, ciSemaphore, semaphoreSlots, false)
    vm.pointee.om.setSlot(s, sExcess, mkInt(0))
    leaveVM(vm, w)
    return s
}

/// Host-side signal (enters the VM on the host worker).
public func hostSignal(_ vm: VMRef, _ sem: Oop) {
    let w = hostWorker(vm)
    enterVM(vm, w)
    semaphoreSignal(vm, nil, sem)
    leaveVM(vm, w)
    if vm.pointee.wakeMain != nil { vm.pointee.wakeMain!(vm.pointee.hookCtx) }
}

/// Block the host thread until no Process is alive.
public func waitAllTerminated(_ vm: VMRef) {
    pthread_mutex_lock(vm.pointee.schedLock)
    while vm.pointee.sched.pointee.liveProcesses > 0 {
        pthread_cond_wait(vm.pointee.doneCond, vm.pointee.schedLock)
    }
    pthread_mutex_unlock(vm.pointee.schedLock)
}

public func liveProcessCount(_ vm: VMRef) -> Int {
    pthread_mutex_lock(vm.pointee.schedLock)
    defer { pthread_mutex_unlock(vm.pointee.schedLock) }
    return vm.pointee.sched.pointee.liveProcesses
}

/// Stop background workers (they finish their current slice first).
public func shutdownWorkers(_ vm: VMRef) {
    pthread_mutex_lock(vm.pointee.schedLock)
    vm.pointee.sched.pointee.shutdown = true
    pthread_cond_broadcast(vm.pointee.schedCond)
    pthread_mutex_unlock(vm.pointee.schedLock)
}
