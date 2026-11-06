import Darwin
import Synchronization

/// What the interpreter counts. Read by tests, benchmarks and `kajo run`.
struct InterpreterCounters: Sendable, Equatable {
    /// Sends from bytecode (special-send fallbacks included, the host's
    /// entry not).
    var sends: UInt64 = 0
    var cacheMisses: UInt64 = 0
    var cacheFlushes: UInt64 = 0
    var primitiveCalls: UInt64 = 0
    var primitiveFailures: UInt64 = 0
    /// Special arithmetic and comparison bytecodes that sent their selector.
    var specialSendFallbacks: UInt64 = 0
    var errors: UInt64 = 0
    /// Safepoint polls that found the flag set.
    var safepointPolls: UInt64 = 0
    /// Collections and compactions the interpreter caused: allocation
    /// failures, the collect and compact primitives, safepoints.
    var collectionsTriggered: UInt64 = 0
    // Module 8.
    /// Special sends answered by the out-of-line tier without a send.
    var specialSendTier: UInt64 = 0
    var superSends: UInt64 = 0
    var performs: UInt64 = 0
    var closuresCreated: UInt64 = 0
    var closureActivations: UInt64 = 0
    var contextsMaterialized: UInt64 = 0
    /// Non-local returns that cut straight to the home, that sent
    /// `aboutToReturn:through:` (an unwind mark between), and that found
    /// the home dead (`cannotReturn:`).
    var nonLocalReturns: UInt64 = 0
    var unwindingReturns: UInt64 = 0
    var cannotReturns: UInt64 = 0
    /// Stores refused because the object is read-only.
    var readOnlyRefusals: UInt64 = 0
    var largeIntegersMade: UInt64 = 0
    var floatsBoxed: UInt64 = 0
    var methodsInstalled: UInt64 = 0
    /// Module 8d: methods the make primitive made, and refused.
    var methodsMade: UInt64 = 0
    var methodsRefused: UInt64 = 0
    /// Module 8e: classes defined, redefined (reshaped, recompiled, pools
    /// replaced) and removed from Smalltalk, such changes refused, and
    /// the file primitives' writes and reads.
    var classesDefined: UInt64 = 0
    var classesRedefined: UInt64 = 0
    var classesRemoved: UInt64 = 0
    /// Module 9b: obsolete classes whose indices were freed.
    var classesFreed: UInt64 = 0
    var classChangesRefused: UInt64 = 0
    var filesWritten: UInt64 = 0
    var filesRead: UInt64 = 0
    var symbolsInterned: UInt64 = 0
    /// `terminateTo:` moves.
    var terminations: UInt64 = 0
}

/// The registers as the collector and the host see them: indices and
/// offsets, never addresses. The loop keeps them in machine registers as
/// pointers (`Regs`) and writes them here before anything that can pause,
/// and on exit. Every oop-valued register is a root at a pause, together
/// with the stack words [0, sp].
struct SavedRegisters: Sendable {
    /// Offset of the next instruction in the current method's bytecodes.
    var pc = 0
    var sp = 0
    var fp = 0
    var hdr = 0
    var receiver = Oop.none
    var method = Oop.none
    /// What the bottom frame returned, until the host takes it. A root
    /// while it holds a value and only then (concurrent-young SPEC,
    /// amendment 8): a stale result kept dead objects alive.
    var result = Oop.none
}

/// Why the loop stopped.
enum ExitReason: UInt8, Sendable {
    case running
    case returned
    case error
    /// Module 3: the Process was suspended (preempted, waiting, hopped,
    /// terminated) and is no longer this worker's; the worker's `leave`
    /// says why. Its stack must not be touched again.
    case suspended
}

/// What the host needs to build a VMError, recorded where it happened.
struct ErrorRecord: Sendable {
    var kind = VMError.Kind.doesNotUnderstand
    var selector = Oop.none
    /// The class index of the receiver (or of the offending value).
    var receiverClass: UInt64 = 0
    var primitive = 0
}

/// One lookup cache line: class index, selector, method.
struct CacheEntry {
    var classIndex: UInt64
    var selector: UInt64
    var method: UInt64
}

/// The interpreter's state: the first field of a `Worker` (module 3), in
/// the worker's 128-byte aligned allocation. Plain values and raw pointers
/// only, so the loop, the send path and the primitives see no ARC.
@unsafe struct InterpreterState {
    let om: ObjectMemory
    let context: AllocContext
    let nilObject: Oop
    let trueObject: Oop
    let falseObject: Oop
    let globals: Oop
    let doesNotUnderstand: Oop
    /// Selector oops for the special-send fallbacks, in opcode order.
    let specialSelectors: UnsafeMutablePointer<UInt64>
    /// Direct mapped, `cacheEntries` lines.
    let cache: UnsafeMutablePointer<CacheEntry>
    /// Set by whoever wants this interpreter to stop at its next poll.
    /// Module 3 wires it to the safepoint protocol; here a test switch that
    /// makes every poll collect.
    let safepointFlag: UnsafeMutablePointer<Atomic<UInt32>>
    /// One byte the loop does not know: pointing pc at it leaves the loop.
    let leaveCode: UnsafeMutablePointer<UInt8>
    let collectAtEveryAllocation: Bool

    var stackBase: UnsafeMutablePointer<UInt64>
    var stackEnd: UnsafeMutablePointer<UInt64>
    var regs = SavedRegisters()
    var exit = ExitReason.running
    var error = ErrorRecord()
    /// Bumped by every pause the interpreter takes part in; the loop
    /// re-derives its cached bases when it changes.
    var pauses: UInt64 = 0
    var counters = InterpreterCounters()
    /// Module 3: polls left until the next budget check. The poll is
    /// `countdown -= 1; if countdown == 0 || flag { pollSlow }`.
    var countdown = 1024
    /// Module 3: the length of the send instruction whose primitive is
    /// running, so a primitive that suspends can rewind to it (hop).
    var sendLength = 0
    /// Module 4: this worker's nursery (eden, entry stash, remembered
    /// buffer); nil without one (module 2's standalone interpreter, or a VM
    /// whose nursery is off): every object is then allocated old.
    var young: UnsafeMutablePointer<NurseryAlloc>? = nil
    /// Module 8: the image's symbol table (interning).
    var symbolTable = Oop.none
    /// Module 8: a store primitive that refused a read-only object records
    /// the object, index and value here; `primitiveSend` then sends
    /// `modificationForbiddenAt:value:` in place of the primitive's answer.
    var readOnlyFailure = Oop.none
    var readOnlyIndex = Oop.none
    var readOnlyValue = Oop.none
    /// Module 8: stack segments grown (stack growth by copying).
    var stackGrowths: UInt64 = 0

    static let cacheEntries = 1024
}

/// The state behind a pointer, with the operations primitives and slow
/// paths need. Primitives see only this and oops, never a raw address.
@safe struct Machine {
    let state: UnsafeMutablePointer<InterpreterState>

    var om: ObjectMemory { unsafe state.pointee.om }
    var nilObject: Oop { unsafe state.pointee.nilObject }
    var trueObject: Oop { unsafe state.pointee.trueObject }
    var falseObject: Oop { unsafe state.pointee.falseObject }
    var globals: Oop { unsafe state.pointee.globals }

    @inline(__always)
    func classIndex(of v: Oop) -> UInt64 { classIndexOf(om, v.raw) }

    /// Record a store refused because `o` is read-only (module 8); the
    /// primitive then fails and `primitiveSend` sends
    /// `modificationForbiddenAt:value:`.
    func refuseReadOnly(_ o: Oop, at index: Oop, value: Oop) -> Oop {
        unsafe state.pointee.readOnlyFailure = o
        unsafe state.pointee.readOnlyIndex = index
        unsafe state.pointee.readOnlyValue = value
        return .none
    }

    // MARK: allocation

    /// A pointer object filled with nil, collecting (with this
    /// interpreter's roots) when the context is out of room. `.none` when
    /// the heap is full of live objects: the error is recorded.
    @inline(__always)
    func allocate(_ cls: UInt64, slots: Int, keeping extra: Oop = .none) -> Oop {
        if let y = unsafe state.pointee.young {
            // Module 4: in this worker's eden.
            let o = unsafe tryAllocateYoung(y, om, classIndex: cls, slots: slots, fill: nilObject)
            if o != .none { return o }
        } else if unsafe !state.pointee.collectAtEveryAllocation {
            let o = om.tryAllocate(unsafe state.pointee.context, classIndex: cls, slots: slots, fill: nilObject)
            if o != .none { return o }
        }
        return allocateSlow(cls, count: slots, bytes: false, keeping: extra)
    }

    /// A byte object, zeroed; as `allocate`.
    @inline(__always)
    func allocateBytes(_ cls: UInt64, count: Int) -> Oop {
        if let y = unsafe state.pointee.young {
            let o = unsafe tryAllocateYoungBytes(y, om, classIndex: cls, count: count)
            if o != .none { return o }
        } else if unsafe !state.pointee.collectAtEveryAllocation {
            let o = om.tryAllocateBytes(unsafe state.pointee.context, classIndex: cls, count: count)
            if o != .none { return o }
        }
        return allocateSlow(cls, count: count, bytes: true, keeping: .none)
    }

    /// The one out-of-line call of the allocation path.
    @inline(never)
    func allocateSlow(_ cls: UInt64, count: Int, bytes: Bool, keeping extra: Oop) -> Oop {
        if unsafe state.pointee.young != nil { return allocateYoungSlow(cls, count: count, bytes: bytes, keeping: extra) }
        return allocateOld(cls, count: count, bytes: bytes, keeping: extra)
    }

    /// An object of any size the count field holds (module 10): the fast
    /// path for one that fits a block, a run of blocks otherwise
    /// (`allocateLarge`). For primitives whose size comes from Smalltalk or
    /// from another object (`basicNew:`, copies, concatenation, the host's
    /// strings); the interpreter's own allocations fit a block by the
    /// bytecode verifier and keep `allocate`.
    @inline(__always)
    func allocateAny(_ cls: UInt64, count: Int, bytes: Bool, keeping extra: Oop = .none) -> Oop {
        if count <= (bytes ? Header.maxBytes : Header.maxSlots) {
            return bytes ? allocateBytes(cls, count: count) : allocate(cls, slots: count, keeping: extra)
        }
        return allocateLarge(cls, count: count, bytes: bytes, keeping: extra)
    }

    /// Module 10: a large object, old at birth: a run of blocks, else a
    /// stop that collects and compacts and tries once more. `.none` when
    /// the heap has no run for it or the count passes the count field:
    /// the primitive fails and the kernel reports it, never a VM error
    /// (a program asking for 100 MB in a 64 MB heap is not out of memory
    /// for everything else).
    @inline(never)
    func allocateLarge(_ cls: UInt64, count: Int, bytes: Bool, keeping extra: Oop = .none) -> Oop {
        guard count >= 0, count <= Header.maxLargeCount else { return .none }
        let o = allocateOld(cls, count: count, bytes: bytes, keeping: extra, softFailure: true)
        if o != .none, let vm = unsafe workerOf(state).pointee.vm { unsafe startCycleAfterLargeAllocation(vm, workerOf(state), o) }
        return o
    }

    /// An old object (no nursery, or one too large for eden): the context's
    /// block, else a stop that collects (module 1's policy; module 4's hook
    /// promotes everything first). Module 10: any size (`tryAllocateAny`);
    /// `softFailure` answers `.none` without recording an error.
    func allocateOld(_ cls: UInt64, count: Int, bytes: Bool, keeping extra: Oop, softFailure: Bool = false) -> Oop {
        let ctx = unsafe state.pointee.context
        if let vm = unsafe workerOf(state).pointee.vm {
            // Module 3: another worker may be stopping the world already;
            // park for it and try again before stopping it ourselves.
            let w = unsafe workerOf(state)
            let keep = extra == .none ? [nilObject] : [nilObject, extra]
            while true {
                if unsafe !state.pointee.collectAtEveryAllocation {
                    let o = om.tryAllocateAny(ctx, classIndex: cls, count: count, isBytes: bytes, fill: nilObject)
                    if o != .none { return o }
                }
                var result: Oop? = nil
                let before = pauseCount()
                let stopped = unsafe stopWorld(vm, w, retry: false, keeping: keep) { stop in
                    let roots = stop.roots()
                    let collections = unsafe om.gc.pointee.counters.collections
                    // Large bytes, part 2: the record is taken before the
                    // collection, as the pools stood when the request failed.
                    let pre = unsafe fallbackRecord(vm, .oldAllocation)
                    // Large bytes, part 2: a cycle that has marked holds
                    // the dead runs until its apply; finishing its sweep
                    // here frees them, before module 1's full collection.
                    if unsafe finishSweepInStop(vm, for: .oldAllocation) {
                        let o = om.tryAllocateAny(ctx, classIndex: cls, count: count, isBytes: bytes, fill: nilObject)
                        if o != .none {
                            result = o
                            return
                        }
                    }
                    result = bytes ? om.allocateBytes(ctx, classIndex: cls, count: count, extraRoots: roots)
                                   : om.allocate(ctx, classIndex: cls, slots: count, fill: nilObject, extraRoots: roots)
                    // Module 10: a full collection forced by an old (large)
                    // allocation is module 5's fallback too: counted, never
                    // hidden (it was not counted before).
                    if unsafe om.gc.pointee.counters.collections != collections { unsafe noteFullCollection(vm, .oldAllocation, record: pre) }
                }
                if !stopped { continue }
                unsafe state.pointee.counters.collectionsTriggered &+= pauseCount() &- before
                guard let o = result else {
                    if !softFailure { fail(.outOfMemory) }
                    return .none
                }
                return o
            }
        }
        var roots = rootsForPause()
        if extra != .none { roots.append(extra) }
        let before = pauseCount()
        let o = bytes ? om.allocateBytes(ctx, classIndex: cls, count: count, extraRoots: roots)
                      : om.allocate(ctx, classIndex: cls, slots: count, fill: nilObject, extraRoots: roots)
        afterPause(collections: pauseCount() &- before)
        guard let o else {
            if !softFailure { fail(.outOfMemory) }
            return .none
        }
        return o
    }

    /// Argument `i` (0-based) of a primitive call with more than two, read
    /// from the stack where the send left it.
    func argument(_ i: Int, of c: PrimitiveCall) -> Oop {
        precondition(i < c.argc)
        let top = unsafe state.pointee.regs.sp
        return unsafe Oop(raw: state.pointee.stackBase[top - c.argc + 1 + i])
    }

    // MARK: pauses

    /// Stop-the-world collection with this interpreter's roots. The world
    /// is this thread until module 3. The pause operations are out of line:
    /// they build Swift arrays for module 1's root interface, and that ARC
    /// must stay out of the primitives and polls that call them.
    @inline(never)
    func collect() {
        if let vm = unsafe workerOf(state).pointee.vm {
            unsafe stopWorld(vm, workerOf(state), retry: true) { om.collect(extraRoots: $0.roots()) }
            unsafe state.pointee.counters.collectionsTriggered &+= 1
            return
        }
        om.collect(extraRoots: rootsForPause())
        afterPause(collections: 1)
    }

    @inline(never)
    func compact() {
        if let vm = unsafe workerOf(state).pointee.vm {
            unsafe stopWorld(vm, workerOf(state), retry: true) { om.compact(extraRoots: $0.roots()) }
            unsafe state.pointee.counters.collectionsTriggered &+= 1
            return
        }
        om.compact(extraRoots: rootsForPause())
        afterPause(collections: 1)
    }

    /// Two-way become. Refused for SmallIntegers and the structural
    /// classes, whose shape the interpreter trusts.
    @inline(never)
    func become(_ a: Oop, _ b: Oop) -> Bool {
        guard a.isObject, b.isObject, !om.isSealed(classIndex(of: a)), !om.isSealed(classIndex(of: b)),
              !om.isReadOnly(a), !om.isReadOnly(b) else {
            return false
        }
        if let vm = unsafe workerOf(state).pointee.vm {
            var ok = false
            unsafe stopWorld(vm, workerOf(state), retry: true) { _ in
                do { try om.becomeExchange(a, b); ok = true } catch {}
            }
            return ok
        }
        do { try om.becomeExchange(a, b) } catch { return false }
        afterPause(collections: 0)
        return true
    }

    func pauseCount() -> UInt64 {
        let c = om.counters
        return c.collections &+ c.compactions
    }

    /// Every pause flushes the lookup cache (its entries are oops) and
    /// tells the loop to re-derive its cached bases.
    func afterPause(collections: UInt64) {
        flushCache()
        unsafe state.pointee.pauses &+= 1
        unsafe state.pointee.counters.collectionsTriggered &+= collections
    }

    func flushCache() {
        unsafe memset(state.pointee.cache, 0, InterpreterState.cacheEntries * MemoryLayout<CacheEntry>.stride)
        unsafe state.pointee.counters.cacheFlushes &+= 1
    }

    /// The stack words [0, sp] and every oop-valued register.
    func rootsForPause() -> [Oop] {
        let r = unsafe state.pointee.regs
        var roots: [Oop] = []
        roots.reserveCapacity(r.sp + 4)
        let base = unsafe state.pointee.stackBase
        for i in 0...r.sp { unsafe roots.append(Oop(raw: base[i])) }
        for v in [r.receiver, r.method, r.result, unsafe state.pointee.readOnlyFailure,
                  unsafe state.pointee.readOnlyIndex, unsafe state.pointee.readOnlyValue] where v != .none { roots.append(v) }
        return roots
    }

    // MARK: errors

    /// Record an error at the current instruction; the loop leaves.
    func fail(_ kind: VMError.Kind, selector: Oop = .none, receiverClass: UInt64 = 0, primitive: Int = 0) {
        unsafe state.pointee.error = ErrorRecord(kind: kind, selector: selector, receiverClass: receiverClass, primitive: primitive)
        unsafe state.pointee.exit = .error
        unsafe state.pointee.counters.errors &+= 1
    }

    var failed: Bool { unsafe state.pointee.exit == .error }
}
