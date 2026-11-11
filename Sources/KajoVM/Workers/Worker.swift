import Darwin
import Synchronization

/// Why a Process left a worker (the worker's `leave`).
enum LeaveReason: UInt8, Sendable {
    case none
    /// Its budget or slice ran out: at the back of its ready queue.
    case preempted
    /// It yielded, waits on a Semaphore, hopped to main or detached: queued
    /// or waiting, its registers saved.
    case suspended
    /// It terminated itself, or a terminate request was honoured.
    case terminated
}

/// One OS thread that runs Smalltalk (or the shell's main thread in a turn,
/// or the host on the host worker). One 128-byte aligned allocation padded
/// to whole 128-byte lines; `interp` is at offset 0, so the interpreter's
/// state pointer is the worker pointer (`workerOf`). Only its own thread
/// writes it, and only while it is inside the VM; a stopper reads the
/// registers of parked workers.
@unsafe struct Worker {
    var interp: InterpreterState
    let index: Int
    let isMain: Bool
    /// nil for module 2's standalone interpreter.
    let vm: UnsafeMutablePointer<VMState>?
    /// A few nil words the registers point at once the Process is gone.
    let dummy: UnsafeMutablePointer<UInt64>
    /// The Process it runs, `.none` between Processes.
    var current = Oop.none
    /// Its record index, -1 between Processes.
    var record = -1
    var leave = LeaveReason.none
    /// Mach ticks: the running Process is preempted at the first budget
    /// check at or after it.
    var deadline: UInt64 = .max
    var pollEvery: Int
    var minPriority = 0
    /// No poll of the current slice has run yet: `preemptEveryPoll` lets
    /// the first one pass, or a Process resumed at a send would be
    /// preempted at that send again and never progress.
    var freshSlice = false
    /// Module 9b: the interrupt the dequeue took from the Process's record
    /// (`InterruptKind`), run when the slice resumes it.
    var interrupt = 0
    /// Wait time, kept apart from work time (AGENTS.md): parked in someone
    /// else's stop, stopping the world itself, entering and leaving.
    var parkNs: UInt64 = 0
    var stopNs: UInt64 = 0
    var enterWaitNs: UInt64 = 0
    var leaveWaitNs: UInt64 = 0
    /// Module 4: time spent in scavenges' parallel phases while parked.
    var collectorNs: UInt64 = 0
    /// The stop epoch whose pause this worker's lookup cache has seen.
    var seenEpoch: UInt64 = 0
    /// Module 6: this worker's post-store checks and hazard slots.
    var relocation = RelocationMutatorCounters()
    /// Module 6: the relocator (the marker worker) is between its CAS and
    /// its switch or revert; a park there would deadlock (checked builds
    /// trap, every build counts it).
    var inRelocation = false
    /// Module 7: the oop the young allocation slow path keeps across a
    /// collection (`keeping:`); a root of this worker's round
    /// acknowledgements. 0 otherwise.
    var youngHeld: UInt64 = 0
    /// Perturbation generator state (xorshift).
    var rng: UInt64
    var thread: pthread_t? = nil
    /// AOT 1: the native engine's state (Native/NativeState.swift), last so
    /// no offset the interpreter reads moves.
    var native = unsafe NativeWorkerState()

    static let bytes = unsafe (MemoryLayout<Worker>.size + 127) & ~127
}

typealias WorkerPointer = UnsafeMutablePointer<Worker>

/// The worker an interpreter state belongs to: the same address.
@_transparent
func workerOf(_ s: StatePointer) -> WorkerPointer {
    unsafe UnsafeMutableRawPointer(s).assumingMemoryBound(to: Worker.self)
}

extension Worker {
    /// Allocate a worker over `image` with its own lookup cache and
    /// allocation context. `flag` is the safepoint flag its polls read.
    static func make(image: Image, vm: UnsafeMutablePointer<VMState>?, index: Int, isMain: Bool,
                     flag: UnsafeMutablePointer<Atomic<UInt32>>, pollEvery: Int, seed: UInt64) -> WorkerPointer {
        unsafe precondition(MemoryLayout<Worker>.offset(of: \Worker.interp) == 0, "the interpreter state is the worker's first field")
        let raw = unsafe UnsafeMutableRawPointer.allocate(byteCount: Worker.bytes, alignment: 128)
        let special = UnsafeMutablePointer<UInt64>.allocate(capacity: image.specialSelectors.count)
        for (i, s) in image.specialSelectors.enumerated() { unsafe special[i] = s.raw }
        let cache = unsafe UnsafeMutablePointer<CacheEntry>.allocate(capacity: InterpreterState.cacheEntries)
        unsafe cache.initialize(repeating: CacheEntry(classIndex: 0, selector: 0, method: 0), count: InterpreterState.cacheEntries)
        let leave = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        unsafe leave.initialize(to: 0xFF)
        precondition(Opcode(rawValue: 0xFF) == nil, "the leave code must not be an opcode")
        let dummy = UnsafeMutablePointer<UInt64>.allocate(capacity: 16)
        unsafe dummy.initialize(repeating: image.nilObject.raw, count: 16)
        let om = image.om
        let w = unsafe raw.bindMemory(to: Worker.self, capacity: 1)
        var interp = unsafe InterpreterState(
            om: om, context: om.makeContext(), nilObject: image.nilObject, trueObject: image.trueObject,
            falseObject: image.falseObject, globals: image.globals, doesNotUnderstand: image.doesNotUnderstand,
            specialSelectors: special, cache: cache, safepointFlag: flag, leaveCode: leave,
            collectAtEveryAllocation: om.config.stress.contains(.collectAtEveryAllocation),
            stackBase: dummy, stackEnd: dummy + 16)
        unsafe interp.countdown = pollEvery
        unsafe interp.symbolTable = image.symbolTable
        unsafe w.initialize(to: Worker(interp: interp, index: index, isMain: isMain, vm: vm, dummy: dummy,
                                       pollEvery: pollEvery, rng: seed | 1))
        return unsafe w
    }

    /// Release a worker made by `make` (its thread, if any, has joined).
    static func destroy(_ w: WorkerPointer) {
        let s = unsafe w.pointee.interp
        unsafe s.om.destroyContext(s.context)
        unsafe s.specialSelectors.deallocate()
        unsafe s.cache.deallocate()
        unsafe s.leaveCode.deallocate()
        unsafe w.pointee.dummy.deallocate()
        unsafe w.deinitialize(count: 1)
        unsafe UnsafeMutableRawPointer(w).deallocate()
    }
}

// MARK: - time

/// Mach ticks: deadlines are kept in ticks so the budget check never
/// converts (experiments/ui-thread-scheduling RESULTS "Clock").
@_transparent
func ticks() -> UInt64 { mach_absolute_time() }

func nanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

let timebase: (numer: UInt64, denom: UInt64) = {
    var info = mach_timebase_info_data_t()
    unsafe mach_timebase_info(&info)
    return (UInt64(info.numer), UInt64(info.denom))
}()

func ticksToNs(_ t: UInt64) -> UInt64 { t.multipliedFullWidth(by: timebase.numer).low / timebase.denom }
func nsToTicks(_ ns: UInt64) -> UInt64 {
    let (hi, lo) = ns.multipliedFullWidth(by: timebase.denom)
    return hi >= timebase.numer ? .max : timebase.numer.dividingFullWidth((hi, lo)).quotient
}
