// AOT 1, the native engine (docs/modules/aot.md): what a worker carries for
// it. One plain struct at the end of the worker, written by the worker's
// own thread only; the generated code reads the hot fields at the offsets
// `NativeLayout` computes from this declaration (and the layout hash makes
// a module built against another declaration refuse to bind).

/// The registers a slow path answers to native code: the frame and the pc
/// to continue at (a bytecode offset), the top of its operand stack.
@unsafe struct NativeOut {
    var fp: UnsafeMutablePointer<UInt64>? = nil
    var hdr: UnsafeMutablePointer<UInt64>? = nil
    var v: UInt64 = 0
    var pc: UInt64 = 0
}

/// Engine switches and native work, counted per worker (plain words, the
/// worker's own thread; summed by the host as the interpreter's are).
struct NativeCounters: Sendable, Equatable {
    /// The driver entered native code: at a slice's start or after the
    /// interpreter left for it.
    var entries: UInt64 = 0
    /// Native code handed a frame to the interpreter: the frame's method
    /// has no binding, or its pc is not a resume point (or its depth is
    /// not the traced one there).
    var toInterpreterUnbound: UInt64 = 0
    /// ... because the Process steps or has an interrupt to run (rule 11).
    var toInterpreterStepping: UInt64 = 0
    /// The interpreter left for native code at a `pollSlow` (budget check)
    /// and at a `returnSlow` into a frame a native caller marked.
    var toNativeAtPoll: UInt64 = 0
    var toNativeAtReturn: UInt64 = 0
    /// Native markers a slow path's continuation put on a frame the VM
    /// activated above a native caller (so its return resumes natively).
    var markersSet: UInt64 = 0
    /// Sends native code made through its own probe and activation
    /// (`counters.sends` counts them too), and slow-path calls by kind.
    var nativeSends: UInt64 = 0
    var nativeReturns: UInt64 = 0
    var slowCalls: UInt64 = 0
    /// Continuations into another frame or method a slow path answered and
    /// native code tail-called (a cold resume at a pc).
    var resumes: UInt64 = 0

    mutating func add(_ x: NativeCounters) {
        entries &+= x.entries; toInterpreterUnbound &+= x.toInterpreterUnbound
        toInterpreterStepping &+= x.toInterpreterStepping; toNativeAtPoll &+= x.toNativeAtPoll
        toNativeAtReturn &+= x.toNativeAtReturn; markersSet &+= x.markersSet; nativeSends &+= x.nativeSends
        nativeReturns &+= x.nativeReturns; slowCalls &+= x.slowCalls; resumes &+= x.resumes
    }

    var named: [(name: String, value: UInt64)] {
        [("nativeEntries", entries), ("toInterpreterUnbound", toInterpreterUnbound),
         ("toInterpreterStepping", toInterpreterStepping), ("toNativeAtPoll", toNativeAtPoll),
         ("toNativeAtReturn", toNativeAtReturn), ("nativeMarkersSet", markersSet), ("nativeSends", nativeSends),
         ("nativeReturns", nativeReturns), ("nativeSlowCalls", slowCalls), ("nativeResumes", resumes)]
    }
}

/// The worker's native state. `table` is the VM's method-to-native table
/// (nil: no module bound, the driver only interprets); `vt` the interface
/// table the generated code calls the VM through; `resume` the bound
/// module's resume table. The generated code reads `table`, `vt`, `out` and
/// the native send counter.
@unsafe struct NativeWorkerState {
    var table: UnsafeMutableRawPointer? = nil
    var vt: UnsafeRawPointer? = nil
    var module: UnsafeRawPointer? = nil
    var out = unsafe NativeOut()
    /// 1 while native code runs on this worker (the interpreter's
    /// `pollSlow` decides a switch only when it is 0).
    var inNative: UInt8 = 0
    /// The interpreter left (`pollSlow`, `returnSlow`) so the driver enters
    /// native code at the saved registers.
    var switchToNative = false
    var counters = NativeCounters()
}
