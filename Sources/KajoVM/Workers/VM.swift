import Darwin
import Synchronization

/// A VM over a loaded image: the main worker, the background workers and
/// the host worker, the scheduler, safepoints and external signals. The
/// host surface (tests, `kajo run`, later the shells). Every method may be
/// called from any thread: each enters the VM like a primitive does
/// (AGENTS.md: host code never reads the heap outside the VM). The image
/// is loaded before the VM is made and not loaded into afterwards.
@safe final class VM: @unchecked Sendable {
    let image: Image
    let state: VMPointer
    private var hostRoots: [Oop: RootHandle] = [:]  // under hostLock
    private var started = false

    init(image: Image, config: VMConfig = VMConfig()) {
        self.image = image
        var config = config
        if !config.stress.isEmpty { config.pollEvery = 1 }
        let om = image.om
        let workerCount = config.backgroundWorkers + 2
        // The safepoint flag and (word 2) module 5's barrier word, one line.
        let flag = unsafe makeFlagLine()
        let workers = UnsafeMutablePointer<WorkerPointer>.allocate(capacity: workerCount)
        precondition(MemoryLayout<WorkerShared>.size <= 128, "a worker's shared words fit one line")
        let shared = UnsafeMutableRawPointer.allocate(byteCount: 128 * workerCount, alignment: 128)
        for i in 0..<workerCount {
            unsafe (shared + 128 * i).bindMemory(to: WorkerShared.self, capacity: 1).initialize(to: WorkerShared())
        }
        let counters = UnsafeMutablePointer<Atomic<UInt64>>.allocate(capacity: Counter.allCases.count)
        for i in 0..<Counter.allCases.count { unsafe (counters + i).initialize(to: Atomic(0)) }
        let queues = UnsafeMutablePointer<UInt64>.allocate(capacity: 2 * Priority.count * Affinity.count)
        unsafe queues.initialize(repeating: 0, count: 2 * Priority.count * Affinity.count)
        let records = UnsafeMutablePointer<ProcessRecord>.allocate(capacity: config.recordCapacity)
        unsafe records.initialize(repeating: ProcessRecord(), count: config.recordCapacity)
        let pendingSlots = UnsafeMutablePointer<UInt64>.allocate(capacity: config.pendingCapacity)
        unsafe pendingSlots.initialize(repeating: 0, count: config.pendingCapacity)
        let pendingNext = UnsafeMutablePointer<Int>.allocate(capacity: config.pendingCapacity)
        unsafe pendingNext.initialize(repeating: -1, count: config.pendingCapacity)
        let stops = unsafe UnsafeMutablePointer<StopRecord>.allocate(capacity: SafepointState.stopLog)
        let raw = unsafe UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<VMState>.stride, alignment: 128)
        unsafe state = raw.bindMemory(to: VMState.self, capacity: 1)
        unsafe state.initialize(to: VMState(
            om: om, image: image, config: config, nilObject: image.nilObject, workers: workers, workerCount: workerCount,
            flag: flag, safepoint: boxed(SafepointState(stops: stops, parts: .allocate(capacity: workerCount))), safepointLock: makeMutex(), safepointCond: makeCond(),
            sched: boxed(SchedulerState()), queues: queues, records: records, schedLock: makeMutex(), schedCond: makeCond(),
            doneCond: makeCond(), externalHead: boxed(Atomic<UInt>(0)), pending: boxed(PendingState()),
            pendingSlots: pendingSlots, pendingNext: pendingNext, pendingLock: makeMutex(), hostLock: makeMutex(),
            workerShared: shared, errors: boxed(ErrorLog()), errorsLock: makeMutex(), counters: counters,
            finalization: boxed(FinalizationState())))
        let seed = config.perturb?.seed ?? 0x9E37_79B9_7F4A_7C15
        for i in 0..<workerCount {
            unsafe workers[i] = Worker.make(image: image, vm: state, index: i, isMain: i == 0, flag: flag,
                                            pollEvery: config.pollEvery, seed: seed &+ UInt64(i) &* 0x9E37_79B9)
        }
        unsafe NurseryShared.install(state)
        unsafe MarkingShared.install(state)
        unsafe RelocationShared.install(state)
    }

    var config: VMConfig { unsafe state.pointee.config }
    var ref: VMRef { unsafe VMRef(vm: state) }

    /// Set before `start` (no closure built in `@MainActor` context may run
    /// on a VM thread; these are C function pointers).
    var hooks: VMHooks {
        get { unsafe state.pointee.hooks }
        set {
            precondition(!started, "hooks are set before any worker starts")
            unsafe state.pointee.hooks = newValue
        }
    }

    /// Start the background workers' threads at user-initiated QoS.
    func start() {
        precondition(!started)
        started = true
        for i in 1...max(1, config.backgroundWorkers) where i <= config.backgroundWorkers {
            let w = unsafe state.worker(i)
            var attr = pthread_attr_t()
            unsafe pthread_attr_init(&attr)
            unsafe pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INITIATED, 0)
            var t: pthread_t? = nil
            let rc = unsafe pthread_create(&t, &attr, { arg in
                let w = unsafe arg.assumingMemoryBound(to: Worker.self)
                unsafe backgroundLoop(w.pointee.vm.unsafelyUnwrapped, w)
                return nil
            }, UnsafeMutableRawPointer(w))
            precondition(rc == 0, "pthread_create failed: \(rc)")
            unsafe w.pointee.thread = t
            unsafe pthread_attr_destroy(&attr)
        }
        unsafe startMarkerThread(state)
    }

    /// Stop and join the background workers (each finishes its slice).
    /// Processes stay as they are.
    func shutdown() {
        unsafe pthread_mutex_lock(state.pointee.schedLock)
        unsafe state.pointee.sched.pointee.shutdown = true
        unsafe pthread_cond_broadcast(state.pointee.schedCond)
        unsafe pthread_mutex_unlock(state.pointee.schedLock)
        for i in unsafe 0..<state.pointee.workerCount {
            if let t = unsafe state.worker(i).pointee.thread {
                unsafe pthread_join(t, nil)
                unsafe state.worker(i).pointee.thread = nil
            }
        }
        unsafe stopMarkerThread(state)
    }

    /// Release the VM (after `shutdown`). Stacks of live Processes are
    /// freed; the image is the caller's. Outstanding Delays must have fired.
    func destroy() {
        let s = unsafe state.pointee
        for i in unsafe 0..<s.sched.pointee.recordHighWater {
            unsafe s.records[i].base?.deallocate()
        }
        var node = unsafe s.externalHead.pointee.exchange(0, ordering: .acquiring)
        while node != 0 {
            let n = unsafe UnsafeMutablePointer<ExternalNode>(bitPattern: node).unsafelyUnwrapped
            node = unsafe n.pointee.next
            unsafe n.deallocate()
        }
        unsafe RelocationShared.uninstall(state)
        unsafe MarkingShared.uninstall(state)
        unsafe NurseryShared.uninstall(state)
        for i in unsafe 0..<s.workerCount { unsafe Worker.destroy(s.workers[i]) }
        unsafe s.workers.deallocate()
        for i in unsafe 0..<s.workerCount {
            unsafe (s.workerShared + 128 * i).assumingMemoryBound(to: WorkerShared.self).deinitialize(count: 1)
        }
        unsafe s.workerShared.deallocate()
        unsafe freeFlagLine(s.flag)
        unsafe s.safepoint.pointee.stops.deallocate()
        unsafe s.safepoint.pointee.parts.deallocate()
        unsafe unbox(s.safepoint)
        unsafe unbox(s.sched)
        unsafe unbox(s.externalHead)
        unsafe unbox(s.pending)
        unsafe unbox(s.errors)
        unsafe unbox(s.finalization)
        unsafe s.queues.deallocate()
        unsafe s.records.deallocate()
        unsafe s.pendingSlots.deallocate()
        unsafe s.pendingNext.deallocate()
        unsafe s.counters.deinitialize(count: Counter.allCases.count)
        unsafe s.counters.deallocate()
        for unsafe m in unsafe [s.safepointLock, s.schedLock, s.pendingLock, s.hostLock, s.errorsLock] { unsafe freeMutex(m) }
        for unsafe c in unsafe [s.safepointCond, s.schedCond, s.doneCond] { unsafe freeCond(c) }
        unsafe state.deinitialize(count: 1)
        unsafe UnsafeMutableRawPointer(state).deallocate()
    }

    // MARK: - host calls

    /// Run `body` on the host worker, inside the VM, one host thread at a
    /// time.
    func host<T>(_ body: (WorkerPointer) -> T) -> T {
        unsafe pthread_mutex_lock(state.pointee.hostLock)
        let w = unsafe state.hostWorker
        unsafe enterVM(state, w)
        let r = unsafe body(w)
        unsafe leaveVM(state, w)
        unsafe pthread_mutex_unlock(state.pointee.hostLock)
        return r
    }

    func machine(_ w: WorkerPointer) -> Machine { unsafe Machine(state: w.pointer(to: \Worker.interp)!) }

    /// Root `o` for the host (host lock held, inside the VM).
    private func keep(_ o: Oop) {
        if o.isObject && hostRoots[o] == nil { hostRoots[o] = image.om.addRoot(o) }
    }

    /// The host no longer needs `o` (a Process, Semaphore or Array it got).
    func release(_ o: Oop) {
        unsafe host { _ in
            if let h = hostRoots.removeValue(forKey: o) { image.om.removeRoot(h) }
        }
    }

    /// `receiver selector arguments...` (up to 16 arguments) as a new
    /// ready Process; rooted for the host unless `keep` is false. nil when
    /// no method takes the selector or the record table is full.
    func spawn(receiver: Oop, selector: String, arguments: [Oop] = [], priority: Int = Priority.normal,
               main: Bool = false, exit: Oop = .none, keep keepIt: Bool = true) -> Oop? {
        guard let sel = image.symbol(selector), arguments.count <= 16 else { return nil }
        let cls = receiver.isSmallInteger ? WellKnown.smallInteger : image.om.classIndex(of: receiver)
        guard let method = image.lookup(cls, sel),
              image.om.load(method, MethodLayout.argc).smallIntegerValue == Int64(arguments.count) else { return nil }
        return unsafe host { w in
            let temp = ([receiver, exit] + arguments).filter(\.isObject).map { image.om.addRoot($0) }
            let p = unsafe createProcess(state, w, receiver: receiver, method: method, args: arguments,
                                         priority: priority, main: main, exit: exit)
            for h in temp { image.om.removeRoot(h) }
            if p == .none { return nil }
            if keepIt { keep(p) }
            return p
        }
    }

    func state(of p: Oop) -> ProcessState {
        unsafe host { _ in
            unsafe schedLock(state)
            let v = image.om.load(p, ProcessLayout.state).smallIntegerValue
            unsafe schedUnlock(state)
            return ProcessState(rawValue: v)!
        }
    }

    /// What a terminated Process answered (nil if it failed or was
    /// terminated; then `error(of:)` may say why).
    func result(of p: Oop) -> Oop {
        unsafe host { _ in
            unsafe schedLock(state)
            let v = image.om.load(p, ProcessLayout.result)
            unsafe schedUnlock(state)
            return v
        }
    }

    /// The VMError that terminated `p`, if one did.
    func error(of p: Oop) -> VMError? {
        let id = unsafe host { _ in image.om.load(p, ProcessLayout.id).smallIntegerValue }
        unsafe pthread_mutex_lock(state.pointee.errorsLock)
        defer { unsafe pthread_mutex_unlock(state.pointee.errorsLock) }
        return unsafe state.pointee.errors.pointee.byProcess[id]
    }

    var liveProcessCount: Int { schedRead { $0.liveProcesses } }

    var liveRecordCount: Int {
        schedRead { s in
            (0..<s.recordHighWater).filter { unsafe state.pointee.records[$0].process != .none }.count
        }
    }

    var idleWorkerCount: Int { schedRead { $0.idleWorkers } }
    var hopLatencies: [UInt64] { schedRead { $0.hopLatencies } }

    private func schedRead<T>(_ body: (SchedulerState) -> T) -> T {
        unsafe pthread_mutex_lock(state.pointee.schedLock)
        defer { unsafe pthread_mutex_unlock(state.pointee.schedLock) }
        return unsafe body(state.pointee.sched.pointee)
    }

    var pendingRootCount: Int {
        unsafe pthread_mutex_lock(state.pointee.pendingLock)
        defer { unsafe pthread_mutex_unlock(state.pointee.pendingLock) }
        return unsafe state.pointee.pending.pointee.count
    }

    /// Block until no Process is alive (an untimed wait on a condition the
    /// last termination broadcasts).
    func waitUntilAllTerminated() {
        unsafe pthread_mutex_lock(state.pointee.schedLock)
        while unsafe state.pointee.sched.pointee.liveProcesses > 0 {
            unsafe pthread_cond_wait(state.pointee.doneCond, state.pointee.schedLock)
        }
        unsafe pthread_mutex_unlock(state.pointee.schedLock)
    }

    /// A new Semaphore with no signals, rooted for the host.
    func newSemaphore() -> Oop {
        unsafe host { w in
            let s = unsafe machine(w).allocate(WellKnown.semaphore, slots: SemaphoreLayout.size)
            precondition(s != .none, "heap full")
            image.om.store(s, SemaphoreLayout.excessSignals, Oop(smallInteger: 0))
            keep(s)
            return s
        }
    }

    /// A new Array of nils, rooted for the host.
    func newArray(_ n: Int) -> Oop {
        unsafe host { w in
            let a = unsafe machine(w).allocate(WellKnown.array, slots: n)
            precondition(a != .none, "heap full")
            keep(a)
            return a
        }
    }

    func excessSignals(_ sem: Oop) -> Int64 {
        unsafe host { _ in
            unsafe schedLock(state)
            defer { unsafe schedUnlock(state) }
            return image.om.load(sem, SemaphoreLayout.excessSignals).smallIntegerValue
        }
    }

    func waiterCount(_ sem: Oop) -> Int {
        unsafe host { _ in
            let om = image.om
            unsafe schedLock(state)
            defer { unsafe schedUnlock(state) }
            var n = 0
            var p = om.load(sem, SemaphoreLayout.firstWaiter)
            while p != image.nilObject {
                n += 1
                p = om.load(p, ProcessLayout.next)
            }
            return n
        }
    }

    func signal(_ sem: Oop) { unsafe host { w in unsafe signalSemaphore(state, w, sem) } }

    func terminate(_ p: Oop) { unsafe host { w in unsafe terminateProcess(state, w, p) } }

    /// Terminate every live Process (running ones at their next budget check).
    func terminateAll() {
        let live: [Oop] = schedRead { s in
            (0..<s.recordHighWater).map { unsafe state.pointee.records[$0].process }.filter { $0 != .none }
        }
        for p in live { terminate(p) }
    }

    // MARK: - world-stopped operations

    /// Run `body` with the world stopped.
    func withWorldStopped(_ body: () -> Void) {
        unsafe host { w in _ = unsafe stopWorld(state, w, retry: true) { _ in body() } }
    }

    /// Run `body` with the world stopped, given the object memory and (if
    /// asked) every root outside it.
    func withWorldStopped(roots: Bool, _ body: (ObjectMemory, [Oop]) -> Void) {
        unsafe host { w in _ = unsafe stopWorld(state, w, retry: true) { stop in body(image.om, roots ? stop.roots() : []) } }
    }

    /// Read the heap from the host: with the world stopped.
    func inspect<T>(_ body: (ObjectMemory) -> T) -> T {
        var r: T? = nil
        withWorldStopped { r = body(image.om) }
        return r!
    }

    func collect() { unsafe host { w in unsafe machine(w).collect() } }
    func compact() { unsafe host { w in unsafe machine(w).compact() } }
    func become(_ a: Oop, _ b: Oop) -> Bool { unsafe host { w in unsafe machine(w).become(a, b) } }

    func global(_ i: Int) -> Oop { inspect { $0.load(image.globals, i - 1) } }
    func setGlobal(_ i: Int, _ v: Oop) {
        unsafe host { w in
            _ = unsafe stopWorld(state, w, retry: true) { _ in unsafe barrierStore(w, image.globals, i - 1, v, .hostGlobal) }
        }
    }

    // MARK: - turns and steps

    /// One main-thread turn on the calling thread (the shell's main thread).
    func runMain(budgetNs: UInt64, minPriority: Int = 0) -> TurnStats {
        unsafe runMainTurn(state, budgetNs: budgetNs, minPriority: minPriority)
    }

    /// Report main-affine Processes runnable for longer than `limitNs`.
    func checkStuck(limitNs: UInt64) { unsafe checkStuckProcesses(state, limitNs: limitNs) }

    /// Test hook: run one ready Process on worker `worker` from this thread.
    func runOneSlice(worker: Int, budgetNs: UInt64 = .max) -> Bool {
        precondition(unsafe state.worker(worker).pointee.thread == nil, "worker \(worker) has a thread")
        return unsafe runOneSliceOn(state, state.worker(worker), budgetNs: budgetNs)
    }

    // MARK: - telemetry

    var counters: VMCounters {
        VMCounters((0..<Counter.allCases.count).map { unsafe state.pointee.counters[$0].load(ordering: .relaxed) })
    }

    /// The QoS class worker `i`'s thread got (0 before it started).
    func workerQoS(_ i: Int) -> qos_class_t {
        qos_class_t(rawValue: unsafe state.shared(i).pointee.qos.load(ordering: .relaxed))
    }

    /// CPU time of each worker's thread so far (0 for a worker without one).
    func workerCPUNanoseconds() -> [UInt64] {
        (unsafe 0..<state.pointee.workerCount).map { i in
            let port = unsafe state.shared(i).pointee.machThread.load(ordering: .relaxed)
            if port == 0 { return 0 }
            var info = thread_extended_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_extended_info>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                unsafe $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    unsafe thread_info(port, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &count)
                }
            }
            if kr != KERN_SUCCESS { return 0 }
            return info.pth_user_time &+ info.pth_system_time
        }
    }

    /// Every stop so far (the last 65 536): time to safepoint, pause, the
    /// slowest participant.
    var stops: [StopRecord] {
        unsafe pthread_mutex_lock(state.pointee.safepointLock)
        defer { unsafe pthread_mutex_unlock(state.pointee.safepointLock) }
        let n = unsafe min(state.pointee.safepoint.pointee.stopCount, SafepointState.stopLog)
        return (0..<n).map { unsafe state.pointee.safepoint.pointee.stops[$0] }
    }

    /// Per-worker wait and work counters, read after the workers stopped.
    func workerWaits(_ i: Int) -> (parkNs: UInt64, stopNs: UInt64, enterWaitNs: UInt64, leaveWaitNs: UInt64) {
        let w = unsafe state.worker(i)
        return unsafe (w.pointee.parkNs, w.pointee.stopNs, w.pointee.enterWaitNs, w.pointee.leaveWaitNs)
    }

    /// Module 2's counters summed over the workers, read after they stopped.
    var interpreterCounters: InterpreterCounters {
        var c = InterpreterCounters()
        for i in unsafe 0..<state.pointee.workerCount {
            let x = unsafe state.worker(i).pointee.interp.counters
            c.sends &+= x.sends; c.cacheMisses &+= x.cacheMisses; c.cacheFlushes &+= x.cacheFlushes
            c.primitiveCalls &+= x.primitiveCalls; c.primitiveFailures &+= x.primitiveFailures
            c.specialSendFallbacks &+= x.specialSendFallbacks; c.errors &+= x.errors
            c.safepointPolls &+= x.safepointPolls; c.collectionsTriggered &+= x.collectionsTriggered
        }
        return c
    }
}
