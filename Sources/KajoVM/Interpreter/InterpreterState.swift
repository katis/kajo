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

/// The interpreter's state, in its own 128-byte aligned allocation (one per
/// worker from module 3 on). Plain values and raw pointers only, so the
/// loop, the send path and the primitives see no ARC.
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

    static let cacheEntries = 1024
    static let byteSize = 256
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
    func classIndex(of v: Oop) -> UInt64 {
        v.isSmallInteger ? WellKnown.smallInteger : om.header(v).classIndex
    }

    // MARK: allocation

    /// A pointer object filled with nil, collecting (with this
    /// interpreter's roots) when the context is out of room. `.none` when
    /// the heap is full of live objects: the error is recorded.
    @inline(__always)
    func allocate(_ cls: UInt64, slots: Int, keeping extra: Oop = .none) -> Oop {
        if unsafe !state.pointee.collectAtEveryAllocation {
            let o = om.tryAllocate(unsafe state.pointee.context, classIndex: cls, slots: slots, fill: nilObject)
            if o != .none { return o }
        }
        return allocateSlow(cls, count: slots, bytes: false, keeping: extra)
    }

    /// A byte object, zeroed; as `allocate`.
    @inline(__always)
    func allocateBytes(_ cls: UInt64, count: Int) -> Oop {
        if unsafe !state.pointee.collectAtEveryAllocation {
            let o = om.tryAllocateBytes(unsafe state.pointee.context, classIndex: cls, count: count)
            if o != .none { return o }
        }
        return allocateSlow(cls, count: count, bytes: true, keeping: .none)
    }

    @inline(never)
    func allocateSlow(_ cls: UInt64, count: Int, bytes: Bool, keeping extra: Oop) -> Oop {
        var roots = rootsForPause()
        if extra != .none { roots.append(extra) }
        let before = pauseCount()
        let ctx = unsafe state.pointee.context
        let o = bytes ? om.allocateBytes(ctx, classIndex: cls, count: count, extraRoots: roots)
                      : om.allocate(ctx, classIndex: cls, slots: count, fill: nilObject, extraRoots: roots)
        afterPause(collections: pauseCount() &- before)
        guard let o else {
            fail(.outOfMemory)
            return .none
        }
        return o
    }

    // MARK: pauses

    /// Stop-the-world collection with this interpreter's roots. The world
    /// is this thread until module 3.
    func collect() {
        om.collect(extraRoots: rootsForPause())
        afterPause(collections: 1)
    }

    func compact() {
        om.compact(extraRoots: rootsForPause())
        afterPause(collections: 1)
    }

    /// Two-way become. Refused for SmallIntegers and the structural
    /// classes, whose shape the interpreter trusts.
    func become(_ a: Oop, _ b: Oop) -> Bool {
        guard a.isObject, b.isObject, !Image.isStructural(classIndex(of: a)), !Image.isStructural(classIndex(of: b)) else {
            return false
        }
        do { try om.becomeExchange(a, b) } catch { return false }
        afterPause(collections: 0)
        return true
    }

    private func pauseCount() -> UInt64 {
        let c = om.counters
        return c.collections &+ c.compactions
    }

    /// Every pause flushes the lookup cache (its entries are oops) and
    /// tells the loop to re-derive its cached bases.
    private func afterPause(collections: UInt64) {
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
        for v in [r.receiver, r.method, r.result] where v != .none { roots.append(v) }
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
