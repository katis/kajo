/// The nursery's configuration (docs/modules/nursery.md). Part of
/// `VMConfig`; fixed once the VM exists.
struct NurseryConfig: Sendable {
    /// Bytes per worker: eden plus two survivor halves. 0: no nursery, every
    /// object is allocated old (the oracle configuration).
    var bytes = 4 << 20
    /// One survivor half; 0: `bytes / 8`.
    var survivorBytes = 0
    /// N: an object is promoted at its N-th survival (or earlier, when the
    /// copying participant's survivor-to is full). 1 to 7.
    var age = 2
    /// Objects above this many body bytes are allocated old.
    var largeObjectBytes = 8 << 10
    var stress: NurseryStress = []
    var testSwitches = NurseryTestSwitches()

    init() {}

    var enabled: Bool { bytes > 0 }

    /// After the stress flags.
    var effective: NurseryConfig {
        var c = self
        if c.enabled && stress.contains(.tinyNurseries) {
            c.bytes = (64 + 16) << 10
            c.survivorBytes = 8 << 10
        }
        if c.survivorBytes == 0 { c.survivorBytes = c.bytes / 8 }
        return c
    }

    /// One survivor half, rounded to words.
    var survivorHalf: Int { effective.survivorBytes & ~7 }
    /// Eden: what the survivor halves leave, rounded to 128 bytes.
    var edenBytes: Int { (effective.bytes - 2 * survivorHalf) & ~127 }
    /// The region each nursery occupies (128-byte aligned).
    var stride: Int { (effective.bytes + 127) & ~127 }

    /// The promotion reserve for `workers` nurseries: twice everything they
    /// can hold (a scavenge that leaves old space past its soft limit may
    /// be followed by another before the full collection it requested),
    /// plus a third for block tails (bodies never span blocks and may be up
    /// to `largeObjectBytes`), plus two blocks per participant.
    func reserveBytes(workers: Int) -> Int {
        guard enabled else { return 0 }
        let young = (edenBytes + survivorHalf) * workers
        let blocks = (2 * young * 4 / 3 + BlockHeap.blockBytes - 1) / BlockHeap.blockBytes + 2 * workers
        return blocks * BlockHeap.blockBytes
    }

    /// Module 7: the nursery region for `workers` nurseries, a multiple of
    /// the block size (`ObjectMemoryConfig.nurseryRegionBytes`): mapped
    /// twice, so young collection without stopping the world can copy a
    /// young body while mutators read it through the alias.
    func regionBytes(workers: Int) -> Int {
        guard enabled else { return 0 }
        let b = stride * workers
        return (b + BlockHeap.blockBytes - 1) / BlockHeap.blockBytes * BlockHeap.blockBytes
    }

    func validate(workers: Int) -> String? {
        let e = effective
        if !e.enabled { return nil }
        if workers > Header.maxNurseries { return "at most \(Header.maxNurseries) workers with a nursery (\(workers))" }
        if e.age < 1 || UInt64(e.age) > Header.maxAge { return "age must be 1...\(Header.maxAge)" }
        if edenBytes < 16 << 10 { return "eden of \(edenBytes) bytes: the nursery is too small" }
        if survivorHalf < 1024 { return "survivor halves of \(survivorHalf) bytes are too small" }
        return nil
    }
}

/// Stress flags of this module (docs/VERIFICATION.md layer 3).
struct NurseryStress: OptionSet, Sendable {
    let rawValue: UInt8
    /// 64 KiB eden and 8 KiB survivor halves: scavenges every few thousand
    /// objects.
    static let tinyNurseries = NurseryStress(rawValue: 1)
    /// Every scavenge promotes everything (age ignored).
    static let promoteAll = NurseryStress(rawValue: 2)
    /// Every young allocation is preceded by a scavenge.
    static let scavengeAtEveryAllocation = NurseryStress(rawValue: 4)

    init(rawValue: UInt8) { self.rawValue = rawValue }

    /// `tinynursery`, `promoteall`, `scavenge`, comma separated.
    init(parsing s: String) {
        var f: NurseryStress = []
        for part in s.split(separator: ",") {
            switch part {
            case "tinynursery": f.insert(.tinyNurseries)
            case "promoteall": f.insert(.promoteAll)
            case "scavenge": f.insert(.scavengeAtEveryAllocation)
            default: break
            }
        }
        self = f
    }
}

/// Switches that turn a rule off so a test can show the rule matters.
/// Never set outside tests.
struct NurseryTestSwitches: Sendable {
    /// The barrier at this site does not remember its holder.
    var skipBarrierAt: BarrierSite? = nil
    /// A remembered holder is dropped after its scan even when it still
    /// names a survivor.
    var dropCarriedHolders = false
    /// A promoted object naming a survivor is not remembered.
    var forgetPromotedHolders = false
    /// Every scavenge claims with the same tag bit.
    var sameClaimTag = false
    /// Weak slots whose young referent died keep naming it.
    var keepDeadWeakSlots = false
    /// The promotion reserve held back past the soft limit, in blocks,
    /// instead of `reserveBytes(workers:)` (0: none, so promotion runs out
    /// of blocks as soon as the heap is full): the reserve's fallback under
    /// test (docs/modules/reserve-and-depth.md).
    var promotionReserveBlocks: Int? = nil
}

/// Every store of an oop into a heap object that may make an old object
/// name a young one carries the barrier, tagged with its site so the
/// mutation tests can switch each one off (docs/modules/nursery.md
/// "Barrier sites"). Stores of SmallIntegers and of nil, true and false
/// (always old) and initialising stores into an object allocated in the
/// same primitive with no safepoint since are plain.
enum BarrierSite: UInt8, CaseIterable, Sendable {
    /// Interpreter: `store_ivar`.
    case storeIvar = 1
    /// Primitives: `at:put:`, `globalAt:put:`.
    case atPut
    case globalAtPut
    /// Send: the Message and its arguments Array for `doesNotUnderstand:`.
    case messageArgument
    case messageSelector
    case messageArguments
    /// Scheduler: the previous tail's `next` in a ready queue.
    case readyQueueLink
    /// Scheduler: the previous Process's `next` when unlinking.
    case unlinkLink
    /// Scheduler: a Semaphore's `firstWaiter` and `lastWaiter` after an unlink.
    case unlinkFirstWaiter
    case unlinkLastWaiter
    /// Scheduler: a terminated Process's `result`.
    case processResult
    /// Scheduler: a waiting Process's `waitingOn`.
    case waitingOn
    /// Scheduler: the last waiter's `next`, `firstWaiter` (empty list) and
    /// `lastWaiter` when a Process waits.
    case waiterLink
    case firstWaiterOnWait
    case lastWaiterOnWait
    /// Scheduler: `firstWaiter` when a signal pops the first waiter.
    case firstWaiterOnSignal
    /// Scheduler: a new Process's exit Semaphore.
    case exitSemaphore
    /// Host: `VM.setGlobal`.
    case hostGlobal
    /// Module 6: the array copy primitive's stores (under hazard slots).
    case arrayCopy
    /// Module 8: `store_tv_slot` (a temp vector may be old).
    case storeTempVector
    /// Module 8: `instVarAt:put:`.
    case instVarAtPut
    /// Module 8: a Context's slots: materialization (a fresh holder) and
    /// detachment (the args and temps copied into a Context that may be old).
    case contextSlot
    /// Module 8: a new closure's slots (a fresh holder).
    case closureSlot
    /// Module 8: a class's new method dictionary (installation, in a stop).
    case installMethod
    /// Module 8: a new Symbol and grown buckets in the symbol table (in a stop).
    case symbolTable
}
