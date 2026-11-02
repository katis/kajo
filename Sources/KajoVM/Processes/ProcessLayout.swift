/// The slots of a Process and a Semaphore (object model v0, well-known
/// classes 13 and 14). Both classes are sealed (`Image.isStructural`): only
/// the scheduler's primitives read or write these slots, so a Smalltalk
/// program cannot forge a saved register or a record index.
enum ProcessLayout {
    /// SmallInteger 0 (background), 1 (normal), 2 (UI).
    static let priority = 0
    /// SmallInteger, a `ProcessState`.
    static let state = 1
    /// The Semaphore it waits on, or nil.
    static let waitingOn = 2
    /// SmallInteger 0 (any worker) or 1 (the main worker).
    static let affinity = 3
    /// The next Process in the one list it is in (a ready queue or a
    /// Semaphore's waiters), or nil.
    static let next = 4
    /// SmallInteger index of its native record; -1 once terminated.
    static let record = 5
    /// Saved registers as SmallIntegers: word indices in its stack and the
    /// bytecode offset (module 2's form, never addresses). `pc` is -1
    /// before the first run (the bottom frame is not activated yet).
    static let sp = 6
    static let pc = 7
    static let fp = 8
    static let hdr = 9
    /// What the bottom method returned, nil until it did.
    static let result = 10
    /// A Semaphore signalled once when it terminates, or nil.
    static let exitSemaphore = 11
    /// SmallInteger, for reports; unique in a VM.
    static let id = 12
    static let size = 13
}

enum SemaphoreLayout {
    static let excessSignals = 0
    static let firstWaiter = 1
    static let lastWaiter = 2
    static let size = 3
}

/// A Process's state slot.
enum ProcessState: Int64, Sendable {
    case ready = 0
    case running = 1
    case waiting = 2
    case terminated = 3
}

enum Priority {
    static let background = 0
    static let normal = 1
    static let ui = 2
    static let count = 3
}

enum Affinity {
    static let any = 0
    static let main = 1
    static let count = 2
}
