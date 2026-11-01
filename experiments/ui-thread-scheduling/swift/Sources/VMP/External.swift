// External signals: the lock-free MPSC queue of Semaphore oops, the
// pending-root table, the IO primitives and native events (SPEC.md
// "External signals"). Completion handlers run on GCD threads, never touch
// the heap and never take the scheduler lock except to wake an idle worker.

import Darwin
import Dispatch
import Synchronization

// MARK: - pending roots

/// Register `sem` as a GC root until its operation completes. VM thread.
func registerPending(_ vm: VMRef, _ sem: Oop) -> Int {
    pthread_mutex_lock(vm.pointee.pendingLock)
    var h = vm.pointee.pend.pointee.free
    if h >= 0 {
        vm.pointee.pend.pointee.free = vm.pointee.pendingNext[h]
    } else {
        h = vm.pointee.pend.pointee.hwm
        if h >= 1 << 16 { fatal("too many pending operations") }
        vm.pointee.pend.pointee.hwm += 1
    }
    vm.pointee.pending[h] = sem
    vm.pointee.pend.pointee.count += 1
    pthread_mutex_unlock(vm.pointee.pendingLock)
    return h
}

private func unregisterPending(_ vm: VMRef, _ h: Int) {
    if h < 0 { return }
    pthread_mutex_lock(vm.pointee.pendingLock)
    vm.pointee.pending[h] = 0
    vm.pointee.pendingNext[h] = vm.pointee.pend.pointee.free
    vm.pointee.pend.pointee.free = h
    vm.pointee.pend.pointee.count -= 1
    pthread_mutex_unlock(vm.pointee.pendingLock)
}

// MARK: - the queue

/// Callable from any thread. `handle` is the pending-root handle to free
/// when drained (-1: the Semaphore is a permanent root). `wake`: also wake
/// an idle background worker and the main worker, so somebody drains it;
/// a caller that drains right away itself (the shell posting an event and
/// then taking a turn) passes false.
public func signalFromOutside(_ vm: VMRef, _ sem: Oop, handle: Int, wake: Bool = true) {
    let node = UnsafeMutablePointer<ExtNode>.allocate(capacity: 1)
    node.initialize(to: ExtNode(sem: sem, handle: handle, next: 0))
    let head = vm.pointee.extHead
    var old = head.pointee.load(ordering: .relaxed)
    while true {
        node.pointee.next = old
        let (done, cur) = head.pointee.compareExchange(expected: old, desired: UInt(bitPattern: node),
                                                       successOrdering: .releasing, failureOrdering: .relaxed)
        if done { break }
        old = cur
    }
    if !wake { return }
    pthread_mutex_lock(vm.pointee.schedLock)
    let idle = vm.pointee.sched.pointee.idleWorkers > 0
    if idle { pthread_cond_signal(vm.pointee.schedCond) }
    pthread_mutex_unlock(vm.pointee.schedLock)
    if !idle, vm.pointee.workerCount <= 2, let h = vm.pointee.wakeMain { h(vm.pointee.hookCtx) }
}

/// Take every pending signal and signal its Semaphore. VM worker inside the VM.
func drainExternal(_ vm: VMRef, _ w: WorkerRef) {
    var list = vm.pointee.extHead.pointee.exchange(0, ordering: .acquiring)
    if list == 0 { return }
    // Reverse to FIFO.
    var fifo: UInt = 0
    while list != 0 {
        let n = UnsafeMutablePointer<ExtNode>(bitPattern: list).unsafelyUnwrapped
        list = n.pointee.next
        n.pointee.next = fifo
        fifo = UInt(bitPattern: n)
    }
    var count: UInt64 = 0
    while fifo != 0 {
        let n = UnsafeMutablePointer<ExtNode>(bitPattern: fifo).unsafelyUnwrapped
        fifo = n.pointee.next
        semaphoreSignal(vm, w, n.pointee.sem)
        unregisterPending(vm, n.pointee.handle)
        n.deallocate()
        count &+= 1
    }
    vm.add(.extSignals, count)
    vm.add(.extDrains, 1)
}

// MARK: - IO primitives

/// `nil delay: ms signal: sem` — a GCD timer signals `sem` after `ms`.
func primDelay(_ vm: VMRef, _ w: WorkerRef, _ ms: Oop, _ sem: Oop) -> Oop {
    if !isInt(ms) { fatal("delay: not an integer") }
    let h = registerPending(vm, sem)
    let bits = UInt(bitPattern: vm)
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(intVal(ms)))) {
        signalFromOutside(UnsafeMutablePointer(bitPattern: bits)!, sem, handle: h)
    }
    return vm.pointee.nilObj
}

/// `nil readFile: #path signal: sem` — DispatchIO reads the file into a
/// native buffer; answers a handle for `ioResult:`.
func primReadFile(_ vm: VMRef, _ w: WorkerRef, _ path: Oop, _ sem: Oop) -> Oop {
    let name = symbolName(vm, path)
    pthread_mutex_lock(vm.pointee.ioLock)
    let io = vm.pointee.io.pointee.nextHandle
    vm.pointee.io.pointee.nextHandle += 1
    pthread_mutex_unlock(vm.pointee.ioLock)
    let h = registerPending(vm, sem)
    let bits = UInt(bitPattern: vm)
    let fd = open(name, O_RDONLY)
    func finish(_ bytes: [UInt8]) {
        let vm = UnsafeMutablePointer<VMCore>(bitPattern: bits)!
        pthread_mutex_lock(vm.pointee.ioLock)
        vm.pointee.io.pointee.results[io] = bytes
        pthread_mutex_unlock(vm.pointee.ioLock)
        signalFromOutside(vm, sem, handle: h)
    }
    if fd < 0 {
        DispatchQueue.global().async { finish([]) }
        return mkInt(Int64(io))
    }
    var st = stat()
    fstat(fd, &st)
    DispatchIO.read(fromFileDescriptor: fd, maxLength: max(Int(st.st_size), 1), runningHandlerOn: .global()) { data, _ in
        close(fd)
        finish([UInt8](data))
    }
    return mkInt(Int64(io))
}

/// `nil ioResult: handle` — the bytes as a ByteArray (VM thread allocates).
func primIoResult(_ vm: VMRef, _ w: WorkerRef, _ handle: Oop) -> Oop {
    pthread_mutex_lock(vm.pointee.ioLock)
    let bytes = vm.pointee.io.pointee.results.removeValue(forKey: Int(intVal(handle))) ?? []
    pthread_mutex_unlock(vm.pointee.ioLock)
    let n = min(bytes.count, blockSize - 64)
    let ba = alloc(vm, w, ciByteArray, n, true)
    let p = vm.pointee.om.bytesPtr(ba)
    for i in 0..<n { p[i] = bytes[i] }
    return ba
}

// MARK: - events

/// Shell side: enqueue a native event and signal the event Semaphore
/// (global 1). Any thread; touches no heap memory.
public func postEvent(_ vm: VMRef, kind: Int64, value: Int64, wake: Bool) {
    pthread_mutex_lock(vm.pointee.eventLock)
    if vm.pointee.evq.pointee.tail &- vm.pointee.evq.pointee.head >= eventCapacity {
        pthread_mutex_unlock(vm.pointee.eventLock)
        return // dropped; the shell counts posted vs handled
    }
    vm.pointee.events[vm.pointee.evq.pointee.tail & (eventCapacity - 1)] = Event(kind: kind, value: value, ticks: ticks())
    vm.pointee.evq.pointee.tail &+= 1
    pthread_mutex_unlock(vm.pointee.eventLock)
    signalFromOutside(vm, vm.pointee.globals[0], handle: -1, wake: wake)
}
