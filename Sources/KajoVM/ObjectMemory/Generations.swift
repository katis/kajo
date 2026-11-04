import Darwin

/// What the object memory offers the nursery (module 4) and the
/// collectors after it: the soft limit and promotion reserve, entry
/// stashes, the nursery region, class formats, weak slots and ephemerons,
/// and the hook that runs before every operation that needs nothing young.

/// A private free-entry list held as an array (module 4's nurseries): the
/// entries `[next, count)` of `base` are free in the table and owned by
/// this stash. The owner hands them out in order; a scavenge refills it
/// with the entries of dead young objects. Module 1's sweep discards every
/// stash (its entries are free in the table and land in the new runs) and
/// the free-list verifier walks them.
@unsafe struct EntryStash {
    var base: UnsafeMutablePointer<UInt32>? = nil
    var next = 0
    var count = 0
    var capacity = 0

    /// The entries handed out since the stash was last swept: `[0, next)`.
    var taken: Int { unsafe next }

    mutating func reserve(_ n: Int) {
        if unsafe n <= capacity { return }
        let c = unsafe Swift.max(n, capacity &* 2, 1024)
        guard let raw = unsafe realloc(UnsafeMutableRawPointer(base), c &* 4) else { fatalError("out of memory") }
        unsafe base = raw.bindMemory(to: UInt32.self, capacity: c)
        unsafe capacity = c
    }

    mutating func append(_ index: UInt32) {
        if unsafe count == capacity { unsafe reserve(count &+ 1) }
        unsafe base.unsafelyUnwrapped[count] = index
        unsafe count &+= 1
    }

    /// Add a free entry as the next one handed out (module 7's released
    /// deferred frees: reused first, so a double free shows at once).
    mutating func pushNext(_ index: UInt32) {
        unsafe append(index)
        let b = unsafe base.unsafelyUnwrapped
        let last = unsafe count &- 1
        let t = unsafe b[next]
        unsafe b[next] = b[last]
        unsafe b[last] = t
    }

    mutating func free() {
        unsafe Darwin.free(UnsafeMutableRawPointer(base))
        unsafe base = nil
        unsafe next = 0
        unsafe count = 0
        unsafe capacity = 0
    }
}

/// A class's format word (ADR 0009 section 6), beside the class table:
///
///     bits  0..15  named slots (the indexed part follows them)
///     bit  16      weak: the indexed slots are not traced; a slot whose
///                  referent is reclaimed becomes nil (module 4)
///     bit  17      ephemeron: slot 0 is a key traced only if it is
///                  reachable some other way (module 4)
///     bits 18..20  kind (module 8): 0 pointers fixed, 1 pointers variable,
///                  2 bytes, 3 16-bit words, 4 32-bit words, 5 64-bit words
///     bit  21      sealed (module 8): no primitive reads, writes, creates
///                  or exchanges an instance, no method of the class
///                  touches an instance variable (module 2's structural
///                  classes, generalised: every metaclass is sealed)
///     bit  22      behaviors (module 8): the instances are classes or
///                  metaclasses (every metaclass, and Metaclass)
///
/// The header keeps only "pointers or bytes" and the count (bytes for every
/// non-pointer kind); the element size is the class's. Weak implies
/// variable pointers, ephemeron fixed pointers with a key, and the
/// non-pointer kinds have no named slots.
struct ClassFormat: Hashable, Sendable {
    var raw: UInt64

    init(raw: UInt64) { self.raw = raw }

    enum Kind: UInt64, Sendable, CaseIterable {
        case fixed = 0
        case variable = 1
        case bytes = 2
        case words16 = 3
        case words32 = 4
        case words64 = 5

        var isPointers: Bool { self == .fixed || self == .variable }
        /// Bytes per indexed element of a non-pointer kind.
        var elementBytes: Int {
            switch self {
            case .fixed, .variable: 8
            case .bytes: 1
            case .words16: 2
            case .words32: 4
            case .words64: 8
            }
        }
    }

    static let namedMask: UInt64 = 0xFFFF
    static let weakBit: UInt64 = 1 << 16
    static let ephemeronBit: UInt64 = 1 << 17
    static let kindShift: UInt64 = 18
    static let kindMask: UInt64 = 7 << kindShift
    static let sealedBit: UInt64 = 1 << 21
    static let behaviorsBit: UInt64 = 1 << 22
    static let validMask: UInt64 = namedMask | weakBit | ephemeronBit | kindMask | sealedBit | behaviorsBit

    /// Module 4's form: weak classes are variable, ephemerons fixed, and
    /// any other class variable (kasm's default; v0 let `basicNew:` add
    /// indexed slots to any class).
    init(namedSlots: Int, weak: Bool = false, ephemeron: Bool = false) {
        self.init(namedSlots: namedSlots, kind: ephemeron ? .fixed : .variable, weak: weak, ephemeron: ephemeron)
    }

    init(namedSlots: Int, kind: Kind, weak: Bool = false, ephemeron: Bool = false, sealed: Bool = false,
         behaviors: Bool = false) {
        precondition(namedSlots >= 0 && UInt64(namedSlots) <= ClassFormat.namedMask && !(weak && ephemeron))
        raw = UInt64(namedSlots) | (weak ? ClassFormat.weakBit : 0) | (ephemeron ? ClassFormat.ephemeronBit : 0)
            | kind.rawValue &<< ClassFormat.kindShift | (sealed ? ClassFormat.sealedBit : 0)
            | (behaviors ? ClassFormat.behaviorsBit : 0)
        precondition(isValid, "invalid class format 0x\(String(raw, radix: 16))")
    }

    var namedSlots: Int { Int(truncatingIfNeeded: raw & ClassFormat.namedMask) }
    var isWeak: Bool { raw & ClassFormat.weakBit != 0 }
    var isEphemeron: Bool { raw & ClassFormat.ephemeronBit != 0 }
    /// Weak or ephemeron: the collectors treat it specially.
    var isSpecial: Bool { raw & (ClassFormat.weakBit | ClassFormat.ephemeronBit) != 0 }
    var kind: Kind { Kind(rawValue: (raw & ClassFormat.kindMask) &>> ClassFormat.kindShift) ?? .fixed }
    var isSealed: Bool { raw & ClassFormat.sealedBit != 0 }
    var instancesAreBehaviors: Bool { raw & ClassFormat.behaviorsBit != 0 }
    /// Instances are byte objects (bytes and the 16-, 32-, 64-bit kinds).
    var isBytes: Bool { !kind.isPointers }

    func with(sealed: Bool) -> ClassFormat {
        ClassFormat(raw: sealed ? raw | ClassFormat.sealedBit : raw & ~ClassFormat.sealedBit)
    }

    /// The rules a format word must follow (the snapshot and image loaders
    /// check them).
    var isValid: Bool {
        guard raw & ~ClassFormat.validMask == 0, let k = Kind(rawValue: (raw & ClassFormat.kindMask) &>> ClassFormat.kindShift)
        else { return false }
        if isWeak && (isEphemeron || k != .variable) { return false }
        if isEphemeron && (k != .fixed || namedSlots < 1) { return false }
        if !k.isPointers && namedSlots != 0 { return false }
        return true
    }

    /// Whether an object with this header may be an instance: pointers or
    /// bytes as the kind says, fixed classes exactly their named slots,
    /// variable ones at least, word kinds a whole number of elements.
    func admits(isBytes b: Bool, count: UInt64) -> Bool {
        let k = kind
        if k.isPointers {
            if b { return false }
            return k == .fixed ? count == UInt64(namedSlots) : count >= UInt64(namedSlots)
        }
        return b && count % UInt64(k.elementBytes) == 0
    }
}

extension ObjectMemory {
    // MARK: - soft limit and promotion reserve

    /// Blocks in use (exact with the contexts retired; a context's current
    /// block counts from the moment it was taken).
    var blocksInUse: Int {
        lockPools()
        defer { unlockPools() }
        return unsafe pools.pointee.blocksInUse
    }

    /// Blocks a mutator may hold; the rest is the promotion reserve.
    var softLimitBlocks: Int {
        get {
            lockPools()
            defer { unlockPools() }
            return unsafe pools.pointee.softLimitBlocks
        }
        nonmutating set {
            precondition(newValue >= 1 && newValue <= heap.blockCount)
            lockPools()
            unsafe pools.pointee.softLimitBlocks = newValue
            unlockPools()
        }
    }

    /// Old space is past its soft limit: a full collection is due.
    var isOverSoftLimit: Bool {
        lockPools()
        defer { unlockPools() }
        return unsafe pools.pointee.blocksInUse > pools.pointee.softLimitBlocks
    }

    /// Promotion refills that found no block at all.
    var reserveExhaustions: UInt64 {
        lockPools()
        defer { unlockPools() }
        return unsafe pools.pointee.reserveExhausted
    }

    /// The bump of a promotion: `bytes` in `ctx`'s block, taking a block
    /// from the reserve when it is full. nil only when the reserve is
    /// exhausted. Counted as neither an allocation nor an allocated byte.
    @inline(__always)
    func bumpPromotion(_ ctx: AllocContext, bytes: UInt64) -> UInt64? {
        let c = unsafe ctx.state
        let top = unsafe c.pointee.top
        if unsafe _fastPath(top &+ bytes <= c.pointee.end) {
            unsafe c.pointee.top = top &+ bytes
            return top
        }
        return promotionRefill(ctx, bytes: bytes)
    }

    @inline(never)
    func promotionRefill(_ ctx: AllocContext, bytes: UInt64) -> UInt64? {
        if !refillBlock(ctx, bytes: bytes, reserve: true) { return nil }
        let c = unsafe ctx.state
        let top = unsafe c.pointee.top
        unsafe c.pointee.top = top &+ bytes
        return top
    }

    // MARK: - entry stashes

    /// Register a stash; module 1's sweep and verifiers know it from now on.
    /// The pointer stays valid until `unregisterStash`.
    func registerStash(_ s: UnsafeMutablePointer<EntryStash>) {
        lockPools()
        unsafe pools.pointee.stashes.append(s)
        unlockPools()
    }

    func unregisterStash(_ s: UnsafeMutablePointer<EntryStash>) {
        lockPools()
        defer { unlockPools() }
        let n = unsafe pools.pointee.stashes.count
        for i in 0..<n where unsafe pools.pointee.stashes[i] == s {
            unsafe pools.pointee.stashes[i] = pools.pointee.stashes[n - 1]
            _ = unsafe pools.pointee.stashes.popLast()
            return
        }
    }

    /// Move whole entry runs from the pool (or a fresh chunk at the high
    /// water mark) into `stash` until it holds at least `atLeast` free
    /// entries past `next`. The stash's owner, any thread. False when the
    /// table is full and nothing was added.
    func refillStash(_ stash: UnsafeMutablePointer<EntryStash>, atLeast: Int) -> Bool {
        lockPools()
        defer { unlockPools() }
        var added = false
        while unsafe stash.pointee.count &- stash.pointee.next < atLeast {
            if let head = unsafe pools.pointee.entryRuns.popLast() {
                var e = head
                while e != 0 {
                    unsafe stash.pointee.append(UInt32(truncatingIfNeeded: e &>> 4))
                    e = stateWord(e) & EntryState.nextMask
                }
                added = true
                continue
            }
            let hw = unsafe pools.pointee.highWater
            let n = Swift.min(UInt64(Swift.max(config.entryChunk, atLeast)), entryCapacity - hw)
            if n == 0 { break }
            for i in 0..<n {
                let e = (hw + i) << 4
                setStateWord(e, EntryState.free(next: 0))
                setHeaderWord(e, 0)
                unsafe stash.pointee.append(UInt32(truncatingIfNeeded: hw + i))
            }
            unsafe pools.pointee.highWater = hw + n
            added = true
        }
        return added
    }

    /// Give the free entries `[next, count)` of `stash` beyond `keep` back
    /// to the pool as runs. World stopped, or the stash's owner.
    func trimStash(_ stash: UnsafeMutablePointer<EntryStash>, keep: Int) {
        let free = unsafe stash.pointee.count &- stash.pointee.next
        if free <= keep { return }
        var runs = RunBuilder(chunk: UInt64(config.entryChunk))
        let base = unsafe stash.pointee.base.unsafelyUnwrapped
        var i = unsafe stash.pointee.next &+ keep
        let end = unsafe stash.pointee.count
        while i < end {
            unsafe runs.add(UInt64(base[i]) &<< 4, self)
            i &+= 1
        }
        unsafe stash.pointee.count = stash.pointee.next &+ keep
        lockPools()
        unsafe runs.finish(into: &pools.pointee.entryRuns)
        unlockPools()
    }

    // MARK: - nursery region

    /// Reserve `bytes` of heap offsets beyond the block range for the
    /// nurseries, never a block. When the object memory was made with
    /// `nurseryRegionBytes` of at least `bytes`, the region is the doubly
    /// mapped memory right after the blocks (module 7: a RELOCATING young
    /// body is still read through the alias); otherwise plain anonymous
    /// memory between the heap and its alias, never aliased (module 4).
    /// Answers the region's first offset. Once per object memory.
    func reserveNurseryRegion(bytes: Int) -> UInt64 {
        precondition(unsafe gc.pointee.nurseryEnd == 0, "the nursery region is reserved once")
        let aliased = heap.extraBytes >= bytes
        let start = aliased ? UInt64(heap.bytes) : (UInt64(heap.bytes &+ heap.extraBytes) &+ 4095) & ~4095
        precondition(start &+ UInt64(bytes) <= VirtualMemory.aliasDistance, "nurseries do not fit below the alias")
        unsafe gc.pointee.nurseryStart = start
        unsafe gc.pointee.nurseryEnd = start &+ UInt64(bytes)
        unsafe gc.pointee.nurseryAliased = aliased
        return start
    }

    var nurseryRegion: Range<UInt64> { unsafe gc.pointee.nurseryStart..<gc.pointee.nurseryEnd }

    /// Module 7: the nursery region is covered by the alias mapping.
    var nurseryRegionAliased: Bool { unsafe gc.pointee.nurseryAliased }

    /// Return nursery pages to the system (the VM is being destroyed or the
    /// region is empty). Plain anonymous memory, so `madvise` frees it.
    func releaseNurseryPages(_ offset: UInt64, _ bytes: Int) {
        unsafe _ = madvise(heapBase + Int(offset), bytes, MADV_FREE)
    }

    // MARK: - class formats

    func classFormat(_ index: UInt64) -> ClassFormat {
        unsafe ClassFormat(raw: gc.pointee.classFormats[Int(index)])
    }

    func setClassFormat(_ index: UInt64, _ f: ClassFormat) {
        precondition(index != 0)
        let hasNil = unsafe gc.pointee.nilObject != .none
        precondition(!f.isSpecial || hasNil, "a weak class needs the nil object")
        unsafe gc.pointee.classFormats[Int(index)] = f.raw
    }

    /// The object a dead weak referent is replaced by (the image's nil).
    var nilObject: Oop {
        get { unsafe gc.pointee.nilObject }
        nonmutating set { unsafe gc.pointee.nilObject = newValue }
    }

    /// Module 8d: a release image (`MemoryShared.gc.releaseImage`).
    var isReleaseImage: Bool {
        get { unsafe gc.pointee.releaseImage }
        nonmutating set { unsafe gc.pointee.releaseImage = newValue }
    }

    // MARK: - finalization

    /// Take the oldest queued ephemeron, or nil when the queue is empty.
    /// Any thread inside the VM (the finalization Process's primitive): the
    /// queue has its own allocation under the pool lock; the collector
    /// appends with the world stopped.
    func takeFinalized() -> Oop? {
        lockPools()
        defer { unlockPools() }
        let q = unsafe shared.pointee.finalization
        guard unsafe q.pointee.count > 0 else { return nil }
        let v = unsafe q.pointee[0]
        unsafe q.pointee.removeFirst()
        return Oop(raw: v)
    }

    var finalizationQueueCount: Int {
        lockPools()
        defer { unlockPools() }
        return unsafe shared.pointee.finalization.pointee.count
    }

    /// A collection fired ephemerons since the last call: the finalization
    /// Semaphore is due a signal. World stopped.
    func takeFinalizationSignal() -> Bool {
        let s = unsafe gc.pointee.finalizationSignal
        unsafe gc.pointee.finalizationSignal = false
        return s
    }

    /// The queue as roots, under the pool lock (module 7's collectors, the
    /// world running).
    func forEachFinalizedLocked(_ body: (Oop) -> Void) {
        lockPools()
        defer { unlockPools() }
        forEachFinalized(body)
    }

    /// World stopped: the queue as roots.
    func forEachFinalized(_ body: (Oop) -> Void) {
        let q = unsafe shared.pointee.finalization
        for i in unsafe 0..<q.pointee.count { unsafe body(Oop(raw: q.pointee[i])) }
    }

    // MARK: - the hook before old-space operations

    func setBeforeOldSpaceOperation(_ hook: (([Oop]?) -> Void)?) {
        unsafe gc.pointee.beforeOldSpaceOperation = hook
    }

    /// Module 4: promote everything before an operation that needs nothing
    /// young. No-op without a nursery.
    func prepareOldSpaceOperation(_ extraRoots: [Oop]?) {
        if let h = unsafe gc.pointee.beforeOldSpaceOperation { h(extraRoots) }
    }
}
