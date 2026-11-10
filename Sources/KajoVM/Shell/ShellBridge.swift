import Darwin
import Synchronization

// Module 9a: what the shell's primitives (150 to 154) reach through
// `VMHooks.host`. The bridge holds the shell's callbacks (Swift closures the
// shell built outside main-actor context, AGENTS.md) and the event queue.
//
// The event queue is not a new cross-thread protocol. It is a mutex-guarded
// FIFO of Swift values plus module 3's external-signal queue: `post` appends
// under the mutex and, if the kernel's event Semaphore is registered, pushes
// one external signal for it after unlocking; the kernel's event loop waits
// on that Semaphore and takes one event per signal (primitive 154, under the
// same mutex). One signal per event keeps the Semaphore's count equal to the
// queue's length, so no wakeup can be lost: an event posted before the
// Semaphore is registered is counted by the registration, which signals it
// once per queued event under the mutex's order (see `register`). The wake
// of an idle worker is the external-signal queue's own (scheduler lock).

/// The shell's half of a VM: callbacks and the event queue.
@safe final class ShellBridge: @unchecked Sendable {
    let callbacks: ShellCallbacks
    private let lock = unsafe makeMutex()
    private var queue: [ShellEvent] = []  // under lock
    private var head = 0  // under lock
    private var semaphore: Oop? = nil  // under lock
    private var pendingHandle = -1  // under lock: the Semaphore's pending-root slot
    var ref: VMRef? = nil  // set once, before any worker starts
    /// The development answers: the host's setting read by primitive 165
    /// (whether an unhandled error stops its Process for the debugger). Set
    /// by the host before the image resumes, and by a host that starts
    /// serving; read by any worker.
    let stopsForDebugger: Atomic<Bool>
    /// Tests (the review fixes, item 19): this many of primitives 154's and
    /// 160's allocations fail as a full heap's would.
    let failAllocations = Atomic<Int>(0)

    func failNextAllocation() -> Bool {
        while true {
            let n = failAllocations.load(ordering: .relaxed)
            if n <= 0 { return false }
            if failAllocations.compareExchange(expected: n, desired: n - 1, ordering: .relaxed).exchanged { return true }
        }
    }

    init(_ callbacks: ShellCallbacks, stopsForDebugger: Bool = false) {
        self.callbacks = callbacks
        self.stopsForDebugger = Atomic(stopsForDebugger)
    }

    deinit {
        unsafe freeMutex(lock)
        unsafe freeMutex(protocolLock)
    }

    /// Any thread: queue `event` and signal the kernel's event Semaphore.
    func post(_ event: ShellEvent) {
        unsafe pthread_mutex_lock(lock)
        queue.append(event)
        let sem = semaphore
        unsafe pthread_mutex_unlock(lock)
        if let sem, let ref { ref.signalFromOutside(sem, handle: nil) }
    }

    /// Primitive 153, inside the VM: `sem` is the event Semaphore from now
    /// on (rooted in the pending-root table, replacing an earlier one); every
    /// event queued before it is signalled once. Answers the earlier root's
    /// handle to free and the number of signals owed.
    func register(_ sem: Oop, handle: Int) -> (oldHandle: Int, owed: Int) {
        unsafe pthread_mutex_lock(lock)
        let old = pendingHandle
        // Signals pushed for an earlier Semaphore were for events still in
        // the queue only if that Semaphore's loop did not take them; the new
        // loop is owed one signal per queued event.
        let owed = queue.count - head
        semaphore = sem
        pendingHandle = handle
        unsafe pthread_mutex_unlock(lock)
        return (old, owed)
    }

    /// Primitive 154: the oldest queued event, if any.
    func take() -> ShellEvent? {
        unsafe pthread_mutex_lock(lock)
        defer { unsafe pthread_mutex_unlock(lock) }
        guard head < queue.count else { return nil }
        let e = queue[head]
        head += 1
        if head > 1024 && head * 2 > queue.count {
            queue.removeFirst(head)
            head = 0
        }
        return e
    }

    /// The review fixes (item 19, primitives.F9): primitive 154 could not
    /// allocate the event's Array (the heap full): `e` goes back to the
    /// queue's head and the Semaphore is signalled again for it (its signal
    /// was taken by the wait that came for it), so nothing is lost.
    func putBack(_ e: ShellEvent) {
        unsafe pthread_mutex_lock(lock)
        if head > 0 {
            head -= 1
            queue[head] = e
        } else {
            queue.insert(e, at: 0)
        }
        let sem = semaphore
        unsafe pthread_mutex_unlock(lock)
        if let sem, let ref { ref.signalFromOutside(sem, handle: nil) }
    }

    var queued: Int {
        unsafe pthread_mutex_lock(lock)
        defer { unsafe pthread_mutex_unlock(lock) }
        return queue.count - head
    }

    // MARK: module 9b: the development protocol's inbox

    // The same shape as the event queue, its own mutex: requests the
    // host's transport parsed and checked (`DevRequest`, KajoDev), as
    // canonical JSON with the connection they came on; the protocol
    // Process's Semaphore, signalled once per request.
    private let protocolLock = unsafe makeMutex()
    private var protocolOpen = false  // under protocolLock
    private var requests: [(Int, [UInt8])] = []  // under protocolLock
    private var requestHead = 0  // under protocolLock
    private var requestSemaphore: Oop? = nil  // under protocolLock
    private var requestHandle = -1  // under protocolLock

    /// The host opened a transport: primitive 159 may register.
    func openProtocol() {
        unsafe pthread_mutex_lock(protocolLock)
        protocolOpen = true
        unsafe pthread_mutex_unlock(protocolLock)
    }

    var isProtocolOpen: Bool {
        unsafe pthread_mutex_lock(protocolLock)
        defer { unsafe pthread_mutex_unlock(protocolLock) }
        return protocolOpen
    }

    /// Any thread: queue a request and signal the protocol Process.
    func postRequest(connection: Int, json: [UInt8]) {
        unsafe pthread_mutex_lock(protocolLock)
        requests.append((connection, json))
        let sem = requestSemaphore
        unsafe pthread_mutex_unlock(protocolLock)
        if let sem, let ref { ref.signalFromOutside(sem, handle: nil) }
    }

    /// Primitive 159: as `register`, for the protocol's Semaphore. nil when
    /// no transport is open.
    func registerProtocol(_ sem: Oop, handle: Int) -> (oldHandle: Int, owed: Int)? {
        unsafe pthread_mutex_lock(protocolLock)
        defer { unsafe pthread_mutex_unlock(protocolLock) }
        guard protocolOpen else { return nil }
        let old = requestHandle
        requestSemaphore = sem
        requestHandle = handle
        return (old, requests.count - requestHead)
    }

    /// Primitive 160: the oldest request.
    func takeRequest() -> (Int, [UInt8])? {
        unsafe pthread_mutex_lock(protocolLock)
        defer { unsafe pthread_mutex_unlock(protocolLock) }
        guard requestHead < requests.count else { return nil }
        let r = requests[requestHead]
        requestHead += 1
        if requestHead > 256 && requestHead * 2 > requests.count {
            requests.removeFirst(requestHead)
            requestHead = 0
        }
        return r
    }

    /// As `putBack`, for a request primitive 160 could not allocate.
    func putBackRequest(_ r: (Int, [UInt8])) {
        unsafe pthread_mutex_lock(protocolLock)
        if requestHead > 0 {
            requestHead -= 1
            requests[requestHead] = r
        } else {
            requests.insert(r, at: 0)
        }
        let sem = requestSemaphore
        unsafe pthread_mutex_unlock(protocolLock)
        if let sem, let ref { ref.signalFromOutside(sem, handle: nil) }
    }

    var queuedRequests: Int {
        unsafe pthread_mutex_lock(protocolLock)
        defer { unsafe pthread_mutex_unlock(protocolLock) }
        return requests.count - requestHead
    }

    /// The protocol Semaphore's pending-root slot (-1: none), cleared.
    func unregisterProtocol() -> Int {
        unsafe pthread_mutex_lock(protocolLock)
        defer { unsafe pthread_mutex_unlock(protocolLock) }
        let h = requestHandle
        requestHandle = -1
        requestSemaphore = nil
        return h
    }

    /// The pending-root slot of the registered Semaphore (-1: none), cleared.
    func unregister() -> Int {
        unsafe pthread_mutex_lock(lock)
        defer { unsafe pthread_mutex_unlock(lock) }
        let h = pendingHandle
        pendingHandle = -1
        semaphore = nil
        return h
    }
}

// MARK: - C hooks over the bridge (context = the bridge, unretained)

@inline(__always)
private func bridge(_ ctx: UnsafeMutableRawPointer?) -> ShellBridge? {
    guard let ctx = unsafe ctx else { return nil }
    return unsafe Unmanaged<ShellBridge>.fromOpaque(ctx).takeUnretainedValue()
}

let shellWakeHook: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
    unsafe bridge(ctx)?.callbacks.wakeMain?()
}

let shellStuckHook: @convention(c) (UnsafeMutableRawPointer?, Int64, UnsafePointer<CChar>, Double) -> Void = { ctx, id, sel, ms in
    guard let b = unsafe bridge(ctx), let f = b.callbacks.stuck else { return }
    f(StuckReport(process: id, method: unsafe String(cString: sel), milliseconds: ms))
}

let shellEventHook: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>, Int) -> Void = { ctx, bytes, count in
    guard let b = unsafe bridge(ctx), let f = b.callbacks.events else { return }
    f(unsafe Array(UnsafeBufferPointer(start: bytes, count: count)))
}

/// The bridge of the VM a primitive runs in, nil outside a shell.
@inline(__always)
func shellBridge(_ vm: VMPointer) -> ShellBridge? { unsafe bridge(vm.pointee.hooks.host) }
