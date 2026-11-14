// Symbol interning without a stop (docs/models/symbol-interning.md,
// docs/modules/symbol-interning.md part 2).
//
// One bucket of the symbol table (a weak array of Symbols) behind one
// strong table slot, a lock beside the table, interners, a lock-free
// reader, and one marking cycle of the concurrent old-space collector. An
// interner looks its bytes up without the lock; on a miss it allocates the
// Symbol (old, whole, never published yet), takes the lock, looks the bytes
// up again (a hit discards the Symbol made: it becomes a String), stores
// the Symbol into a hole of the bucket and lets go. A full bucket: the
// interner lets go, allocates a bucket twice the size, takes the lock,
// checks that the table still names the bucket it measured, copies the old
// bucket's slots, publishes the new bucket in the table, lets go and starts
// again. Every lock-free read of a weak slot that hands its Symbol on goes
// through the keep-alive barrier while a cycle marks. Allocation is a poll:
// a stop (the initial and the final mark) happens only when every thread is
// at one, so never inside a critical section.
//
// Memory: ModelKit's store-buffer model (relaxed stores may drain out of
// order; release stores drain when oldest; the lock is an acquire
// read-modify-write and the unlock a release store, not full fences).
// Object metadata (allocated, snapshot, marked, freed) is the collector's
// state and changes only in stops.
//
// Claims:
//  1. one Symbol per byte sequence among the Symbols any thread holds (a
//     register, a holder it stored into) and the table names;
//  2. a lookup never reads a bucket slot or a Symbol that is not whole;
//  3. no Symbol a thread holds or the table names is freed (swept under a
//     live reference);
//  4. every thread finishes (no deadlock).

import ModelKit

public enum Claim: Int, Hashable, Sendable, CaseIterable, CustomStringConvertible {
    case oneSymbolPerBytes, wholeReads, noLostSymbol, everyoneFinishes
    public var description: String {
        switch self {
        case .oneSymbolPerBytes: "1 one Symbol per byte sequence"
        case .wholeReads: "2 a lookup reads only whole buckets and Symbols"
        case .noLostSymbol: "3 no Symbol held is swept"
        case .everyoneFinishes: "4 every thread finishes"
        }
    }
}

public struct Configuration: Sendable {
    /// The bytes each interner interns (1 is A, 2 is B, 3 is C).
    public var interners: [Int]
    /// The bytes the lock-free reader looks up, if there is one.
    public var reader: Int?
    /// Capacity of the bucket the table names at the start.
    public var firstCapacity: Int
    /// A Symbol of these bytes in the first bucket at the start, held only
    /// by the bucket's weak slot (dropped by the program before the run).
    public var preexisting: Int?
    /// One marking cycle (initial mark, final mark with the weak pass and
    /// the sweep) may run, at any point where every thread is at a poll.
    public var marker = true
    /// Every store reaches memory at once (ModelKit's extension).
    public var sequentiallyConsistent = false
    /// Threads that drop their answer at the end (the program lets the
    /// Symbol go, so only the bucket's weak slot holds it); the others
    /// store it into a holder the marker has already scanned and drop the
    /// register (the lost-object shape of AGENTS.md's weak-read lesson).
    public var drops: Set<Int> = [1]

    // The rules, each on by default and off in one negative test.
    /// The insert looks the bytes up again under the lock.
    public var secondLookup = true
    /// The Symbol's bytes are filled before it is stored into the bucket.
    public var fillBeforePublish = true
    /// The publishing stores (a Symbol into a bucket, a bucket into the
    /// table) are release stores (production: seq_cst, the post-store
    /// check's store, after a release fence); off: relaxed.
    public var releasePublish = true
    /// The keep-alive barrier on the lock-free lookup's hit, on the second
    /// lookup's hit, and on each Symbol the growth copies.
    public var keepAliveFirstLookup = true
    public var keepAliveSecondLookup = true
    public var keepAliveGrowthCopy = true

    public init(interners: [Int], reader: Int? = nil, firstCapacity: Int, preexisting: Int? = nil) {
        self.interners = interners
        self.reader = reader
        self.firstCapacity = firstCapacity
        self.preexisting = preexisting
    }

    /// Two interners of the same bytes and a reader of them: the hole and
    /// uniqueness (no growth).
    public static let sameBytes = Configuration(interners: [1, 1], reader: 1, firstCapacity: 2)
    /// One interner of A and one of B into the same bucket of one slot, a
    /// reader of A: a growth raced by an insert of other bytes.
    public static let bucketMates = Configuration(interners: [1, 2], reader: 1, firstCapacity: 1)
    /// A Symbol C held only weakly fills the bucket; two interners of A
    /// grow it while a cycle marks: the growth copy's keep-alive.
    public static let growth = Configuration(interners: [1, 1], firstCapacity: 1, preexisting: 3)
}

// MARK: - state

/// Interner program counters. Poll points: `lookup`, `allocate`,
/// `allocateBucket`, `stash`, `done`.
enum PC: UInt8, Hashable {
    case lookup, allocate, fill, lock, secondLookup, publish, fillLate, unlock, stash, done
    case unlockForGrowth, allocateBucket, lockForGrowth, check, copy, unlockAfterGrowth
    /// The reader's: read the table, a slot, a Symbol's bytes.
    case readTable, readSlot, readBytes
}

let pollPoints: Set<PC> = [.lookup, .allocate, .allocateBucket, .stash, .done, .readTable]

struct Thread: Hashable {
    var pc: PC
    /// The bucket measured (growth) or read (the reader).
    var bucket: Int8 = -1
    /// The Symbol made and not yet published (a register).
    var sym: Int8 = -1
    /// The Symbol answered (a register until stashed).
    var answer: Int8 = -1
    var newBucket: Int8 = -1
    /// The reader's slot index and candidate.
    var slot: Int8 = 0
    var candidate: Int8 = -1
    /// The slot of the hole the second lookup found.
    var hole: Int8 = -1
    var allocations: Int8 = 0
    var growths: Int8 = 0
}

/// A Symbol's or a bucket's collector state.
enum Life: UInt8, Hashable { case unallocated, allocated, discarded }

public struct State: Hashable {
    var mem: Memory
    var threads: [Thread]
    var symLife: [Life]
    var symSnapshot: [Bool]
    var symMarked: [Bool]
    var symFreed: [Bool]
    var bucketAllocated: [Bool]
    var bucketSnapshot: [Bool]
    var bucketCap: [Int8]
    /// The holder each thread stored its answer into (-1: nothing).
    var stash: [Int8]
    /// 0 idle, 1 marking, 2 done.
    var phase: UInt8 = 0
}

// MARK: - the model

let garbage = -1

struct Model: ExplorableModel {
    typealias Claim = SymbolInterningModel.Claim
    let c: Configuration
    let threads: Int
    let syms: Int
    let buckets: Int
    let maxCap: Int
    static let symsPerThread = 3
    static let bucketsPerThread = 2

    init(_ c: Configuration) {
        self.c = c
        threads = c.interners.count + (c.reader == nil ? 0 : 1)
        syms = 1 + c.interners.count * Model.symsPerThread
        buckets = 1 + c.interners.count * Model.bucketsPerThread
        maxCap = c.firstCapacity << Model.bucketsPerThread
    }

    // Memory layout: table, lock, buckets' slots, Symbols' bytes.
    let table = 0, lock = 1
    func slotAddress(_ b: Int, _ i: Int) -> Int { 2 + b * maxCap + i }
    func bytesAddress(_ s: Int) -> Int { 2 + buckets * maxCap + s }

    func isReader(_ t: Int) -> Bool { t >= c.interners.count }
    func bytesOf(_ t: Int) -> Int { isReader(t) ? c.reader! : c.interners[t] }

    func initialState() -> State {
        var words = Array(repeating: garbage, count: 2 + buckets * maxCap + syms)
        words[table] = 1  // bucket 0
        words[lock] = 0
        for i in 0..<c.firstCapacity { words[slotAddress(0, i)] = 0 }
        var life = Array(repeating: Life.unallocated, count: syms)
        if let p = c.preexisting {
            life[0] = .allocated
            words[bytesAddress(0)] = p
            words[slotAddress(0, 0)] = 1
        }
        var bucketAllocated = Array(repeating: false, count: buckets)
        bucketAllocated[0] = true
        var caps = Array(repeating: Int8(0), count: buckets)
        caps[0] = Int8(c.firstCapacity)
        var ts = c.interners.map { _ in Thread(pc: .lookup) }
        if c.reader != nil { ts.append(Thread(pc: .readTable)) }
        return State(mem: Memory(words: words, threads: threads, sequentiallyConsistent: c.sequentiallyConsistent),
                     threads: ts, symLife: life, symSnapshot: Array(repeating: false, count: syms),
                     symMarked: Array(repeating: false, count: syms), symFreed: Array(repeating: false, count: syms),
                     bucketAllocated: bucketAllocated, bucketSnapshot: Array(repeating: false, count: buckets),
                     bucketCap: caps, stash: Array(repeating: -1, count: threads))
    }

    func fingerprint(_ s: State) -> UInt64 {
        var h = Hasher()
        s.hash(into: &h)
        return UInt64(bitPattern: Int64(h.finalize()))
    }

    var publishOrder: Order { c.releasePublish ? .release : .relaxed }

    /// The keep-alive barrier: while a cycle marks, a Symbol read from a weak
    /// slot and handed on is marked if it is a snapshot entry.
    func keepAlive(_ n: inout State, _ sym: Int) {
        if n.phase == 1 && n.symSnapshot[sym] { n.symMarked[sym] = true }
    }

    /// A lookup of `bytes` in the bucket the table names, by thread `t`, all
    /// in one step (the interner's lock-free and locked lookups; the reader
    /// is modelled a load at a time). Answers the Symbol and its slot, the
    /// first hole, and a whole-read violation.
    func lookup(_ s: State, _ t: Int, bytes: Int) -> (found: Int, foundSlot: Int, bucket: Int, hole: Int, bad: String?) {
        let tb = s.mem.load(t, table, .relaxed)!
        if tb == garbage { return (-1, -1, -1, -1, "a table slot never written") }
        if tb == 0 { return (-1, -1, -1, -1, nil) }
        let b = tb - 1
        var hole = -1, found = -1, foundSlot = -1
        // The whole bucket: the first hole is looked for apart from the
        // match (production: `symbolSlot` scans for a hole on its own).
        for i in 0..<Int(s.bucketCap[b]) {
            let v = s.mem.load(t, slotAddress(b, i), .relaxed)!
            if v == garbage { return (-1, -1, b, -1, "bucket \(b) slot \(i) read before the bucket was whole") }
            if v == 0 { if hole < 0 { hole = i }; continue }
            if found >= 0 { continue }
            let bytesNow = s.mem.load(t, bytesAddress(v - 1), .relaxed)!
            if bytesNow == garbage || bytesNow == 0 { return (-1, -1, b, -1, "Symbol \(v - 1) read before its bytes were filled") }
            if bytesNow == bytes { found = v - 1; foundSlot = i }
        }
        return (found, foundSlot, b, hole, nil)
    }

    func allAtPolls(_ s: State) -> Bool {
        for t in 0..<threads where !pollPoints.contains(s.threads[t].pc) || !s.mem.isDrained(t) { return false }
        return true
    }

    func successors(_ s: State, labels: Bool) -> [Transition<State, Claim>] {
        var out: [Transition<State, Claim>] = []
        func add(_ l: @autoclosure () -> String, _ n: State, _ v: Violation<Claim>? = nil) {
            out.append(Transition(label: labels ? l() : "", next: n, violation: v))
        }
        func whole(_ m: String) -> Violation<Claim> { Violation(claim: .wholeReads, message: m) }

        // Store-buffer drains.
        for t in 0..<threads {
            for i in s.mem.drainable(t) {
                var n = s
                let e = n.mem.drain(t, i)
                add("T\(t) drains [\(e.address)] := \(e.value) (\(e.order))", n)
            }
        }

        for t in 0..<threads {
            let th = s.threads[t]
            let x = bytesOf(t)
            var n = s
            switch th.pc {
            case .done:
                break
            case .lookup:
                let r = lookup(s, t, bytes: x)
                if let bad = r.bad { add("T\(t) lock-free lookup of \(x)", n, whole(bad)); continue }
                if r.found >= 0 {
                    if c.keepAliveFirstLookup { keepAlive(&n, r.found) }
                    n.threads[t].answer = Int8(r.found)
                    n.threads[t].pc = .stash
                    add("T\(t) lock-free lookup of \(x) finds S\(r.found)", n)
                } else {
                    n.threads[t].pc = .allocate
                    add("T\(t) lock-free lookup of \(x) misses", n)
                }
            case .allocate:
                guard th.allocations < Model.symsPerThread else {
                    add("T\(t) allocates", n, Violation(claim: .everyoneFinishes, message: "T\(t) retried past the model's objects"))
                    continue
                }
                let sym = 1 + t * Model.symsPerThread + Int(th.allocations)
                n.symLife[sym] = .allocated
                n.threads[t].sym = Int8(sym)
                n.threads[t].allocations += 1
                // The allocation zero-fills the body (a relaxed store).
                n.mem.store(t, bytesAddress(sym), 0, .relaxed)
                n.threads[t].pc = c.fillBeforePublish ? .fill : .lock
                add("T\(t) allocates S\(sym) (old, pinned, read-only)", n)
            case .fill, .fillLate:
                n.mem.store(t, bytesAddress(Int(th.sym)), x, .relaxed)
                n.threads[t].pc = th.pc == .fill ? .lock : .unlock
                if th.pc == .fillLate { n.threads[t].sym = -1 }
                add("T\(t) fills S\(th.sym)'s bytes with \(x)", n)
            case .lock, .lockForGrowth:
                // pthread_mutex_lock: an acquire read-modify-write on the
                // lock word, not a full fence: this thread's earlier stores
                // (the Symbol's fill, the new bucket's nils) may still be
                // in its buffer. Taken when the word reads free in memory.
                guard s.mem.words[lock] == 0, !s.mem.buffers[t].contains(where: { $0.address == lock }) else { continue }
                n.mem.words[lock] = 1
                n.threads[t].pc = th.pc == .lock ? .secondLookup : .check
                add("T\(t) takes the lock", n)
            case .secondLookup:
                let r = lookup(s, t, bytes: x)
                if let bad = r.bad { add("T\(t) second lookup", n, whole(bad)); continue }
                if c.secondLookup && r.found >= 0 {
                    if c.keepAliveSecondLookup { keepAlive(&n, r.found) }
                    n.threads[t].answer = Int8(r.found)
                    n.symLife[Int(th.sym)] = .discarded
                    n.threads[t].sym = -1
                    n.threads[t].pc = .unlock
                    add("T\(t) second lookup finds S\(r.found); S\(th.sym) becomes a String", n)
                } else if r.hole >= 0 {
                    n.threads[t].hole = Int8(r.hole)
                    n.threads[t].bucket = Int8(r.bucket)
                    n.threads[t].pc = .publish
                    add("T\(t) second lookup misses, hole \(r.hole) in B\(r.bucket)", n)
                } else {
                    n.threads[t].bucket = Int8(r.bucket)
                    n.threads[t].pc = .unlockForGrowth
                    add("T\(t) second lookup misses, B\(r.bucket) full", n)
                }
            case .publish:
                n.mem.store(t, slotAddress(Int(th.bucket), Int(th.hole)), Int(th.sym) + 1, publishOrder)
                n.threads[t].answer = th.sym
                if c.fillBeforePublish {
                    n.threads[t].sym = -1
                    n.threads[t].pc = .unlock
                } else {
                    n.threads[t].pc = .fillLate
                }
                add("T\(t) stores S\(th.sym) into B\(th.bucket)[\(th.hole)] (\(publishOrder))", n)
            case .unlock, .unlockForGrowth, .unlockAfterGrowth:
                // pthread_mutex_unlock: a release store of the lock word;
                // the lock is free once it drains, after every store of
                // the critical section.
                n.mem.store(t, lock, 0, .release)
                switch th.pc {
                case .unlock: n.threads[t].pc = .stash
                case .unlockForGrowth:
                    n.symLife[Int(th.sym)] = .discarded
                    n.threads[t].sym = -1
                    n.threads[t].pc = .allocateBucket
                default: n.threads[t].pc = .allocate
                }
                add("T\(t) lets the lock go", n)
            case .allocateBucket:
                guard th.growths < Model.bucketsPerThread else {
                    add("T\(t) allocates a bucket", n, Violation(claim: .everyoneFinishes, message: "T\(t) grew past the model's objects"))
                    continue
                }
                let nb = 1 + t * Model.bucketsPerThread + Int(th.growths)
                let cap = Int(s.bucketCap[Int(th.bucket)]) * 2
                n.bucketAllocated[nb] = true
                n.bucketCap[nb] = Int8(cap)
                for i in 0..<cap { n.mem.store(t, slotAddress(nb, i), 0, .relaxed) }
                n.threads[t].newBucket = Int8(nb)
                n.threads[t].growths += 1
                n.threads[t].pc = .lockForGrowth
                add("T\(t) allocates B\(nb) of \(cap) (old, nil)", n)
            case .check:
                let tb = s.mem.load(t, table, .relaxed)!
                if tb - 1 == Int(th.bucket) {
                    n.threads[t].pc = .copy
                    add("T\(t) finds the table still naming B\(th.bucket)", n)
                } else {
                    n.threads[t].newBucket = -1
                    n.threads[t].pc = .unlockAfterGrowth
                    add("T\(t) finds the table changed: B\(th.newBucket) for nothing", n)
                }
            case .copy:
                let old = Int(th.bucket), nb = Int(th.newBucket)
                for i in 0..<Int(s.bucketCap[old]) {
                    let v = s.mem.load(t, slotAddress(old, i), .relaxed)!
                    if v > 0 && c.keepAliveGrowthCopy { keepAlive(&n, v - 1) }
                    n.mem.store(t, slotAddress(nb, i), v, .relaxed)
                }
                n.mem.store(t, table, nb + 1, publishOrder)
                n.threads[t].newBucket = -1
                n.threads[t].pc = .unlockAfterGrowth
                add("T\(t) copies B\(old) into B\(nb) and stores B\(nb) into the table (\(publishOrder))", n)
            case .stash:
                n.threads[t].answer = -1
                n.threads[t].pc = .done
                if c.drops.contains(t) {
                    add("T\(t) drops S\(th.answer)", n)
                } else {
                    n.stash[t] = th.answer
                    add("T\(t) stores S\(th.answer) into an already scanned holder and drops it", n)
                }
            case .readTable:
                let tb = s.mem.load(t, table, .relaxed)!
                if tb == garbage { add("R reads the table", n, whole("a table slot never written")); continue }
                if tb == 0 { n.threads[t].pc = .done; add("R finds no bucket", n); continue }
                n.threads[t].bucket = Int8(tb - 1)
                n.threads[t].slot = 0
                n.threads[t].pc = .readSlot
                add("R reads B\(tb - 1) from the table", n)
            case .readSlot:
                let b = Int(th.bucket), i = Int(th.slot)
                if i >= Int(s.bucketCap[b]) { n.threads[t].pc = .done; add("R misses", n); continue }
                let v = s.mem.load(t, slotAddress(b, i), .relaxed)!
                if v == garbage { add("R reads B\(b)[\(i)]", n, whole("R read bucket \(b) slot \(i) before the bucket was whole")); continue }
                if v == 0 {
                    n.threads[t].slot += 1
                    add("R reads B\(b)[\(i)]: nil", n)
                } else {
                    n.threads[t].candidate = Int8(v - 1)
                    n.threads[t].pc = .readBytes
                    add("R reads B\(b)[\(i)]: S\(v - 1)", n)
                }
            case .readBytes:
                let sym = Int(th.candidate)
                let v = s.mem.load(t, bytesAddress(sym), .relaxed)!
                if v == garbage || v == 0 {
                    add("R reads S\(sym)'s bytes", n, whole("R read Symbol \(sym) before its bytes were filled"))
                    continue
                }
                if v == x {
                    if c.keepAliveFirstLookup { keepAlive(&n, sym) }
                    n.threads[t].answer = Int8(sym)
                    n.threads[t].candidate = -1
                    n.threads[t].pc = .stash
                    add("R finds S\(sym)", n)
                } else {
                    n.threads[t].candidate = -1
                    n.threads[t].slot += 1
                    n.threads[t].pc = .readSlot
                    add("R reads S\(sym)'s bytes: \(v), not \(x)", n)
                }
            }
        }

        // The collector: stops only where every thread is at a poll.
        if c.marker && s.phase < 2 && allAtPolls(s) {
            var n = s
            if s.phase == 0 {
                // Initial mark: the snapshot is every allocated object; what
                // the roots and the holders reach is marked (the marker's
                // tracing, done at once).
                for k in 0..<syms where s.symLife[k] != .unallocated && !s.symFreed[k] { n.symSnapshot[k] = true }
                for b in 0..<buckets where s.bucketAllocated[b] { n.bucketSnapshot[b] = true }
                for k in heldSymbols(s) { n.symMarked[k] = true }
                n.phase = 1
                add("initial mark (stop): snapshot taken, holders traced", n)
            } else {
                // Final mark: the registers are roots again (a holder stored
                // into after the initial mark is not rescanned: SATB); the
                // weak pass nils every snapshot bucket's slot whose Symbol is
                // an unmarked snapshot entry; the sweep frees them.
                for th in s.threads {
                    for r in [th.answer, th.sym] where r >= 0 && s.symSnapshot[Int(r)] { n.symMarked[Int(r)] = true }
                }
                for b in 0..<buckets where s.bucketSnapshot[b] {
                    for i in 0..<Int(s.bucketCap[b]) {
                        let a = slotAddress(b, i)
                        let v = n.mem.words[a]
                        if v > 0 && n.symSnapshot[v - 1] && !n.symMarked[v - 1] { n.mem.words[a] = 0 }
                    }
                }
                for k in 0..<syms where n.symSnapshot[k] && !n.symMarked[k] { n.symFreed[k] = true }
                n.phase = 2
                add("final mark (stop): weak pass, sweep", n, lost(n))
            }
        }
        return out
    }

    /// Symbols the threads hold: registers and the holders they stored into.
    func heldSymbols(_ s: State) -> [Int] {
        var r: [Int] = []
        for th in s.threads { for v in [th.answer, th.sym] where v >= 0 { r.append(Int(v)) } }
        for v in s.stash where v >= 0 { r.append(Int(v)) }
        return r
    }

    /// Symbols the bucket the table names holds (memory as it stands).
    func tableSymbols(_ s: State) -> [Int] {
        let tb = s.mem.words[table]
        guard tb > 0 else { return [] }
        return (0..<Int(s.bucketCap[tb - 1])).compactMap { i in
            let v = s.mem.words[slotAddress(tb - 1, i)]
            return v > 0 ? v - 1 : nil
        }
    }

    func lost(_ s: State) -> Violation<Claim>? {
        for k in heldSymbols(s) where s.symFreed[k] {
            return Violation(claim: .noLostSymbol, message: "a thread holds S\(k), which the sweep freed")
        }
        for k in tableSymbols(s) where s.symFreed[k] {
            return Violation(claim: .noLostSymbol, message: "the table's bucket names S\(k), which the sweep freed")
        }
        return nil
    }

    func terminalViolation(_ s: State) -> Violation<Claim>? {
        for (t, th) in s.threads.enumerated() where th.pc != .done {
            return Violation(claim: .everyoneFinishes, message: "T\(t) never finished (\(th.pc))")
        }
        if let v = lost(s) { return v }
        var byBytes: [Int: Set<Int>] = [:]
        for k in heldSymbols(s) + tableSymbols(s) {
            byBytes[s.mem.words[bytesAddress(k)], default: []].insert(k)
        }
        for (b, set) in byBytes where set.count > 1 {
            return Violation(claim: .oneSymbolPerBytes, message: "bytes \(b) have Symbols \(set.sorted()) held or in the table")
        }
        for k in heldSymbols(s) where s.symLife[k] == .discarded {
            return Violation(claim: .oneSymbolPerBytes, message: "a thread holds S\(k), a Symbol made for nothing")
        }
        return nil
    }
}

public typealias Report = ModelKit.Report<Claim>
public typealias Trace = ModelKit.Trace<Claim>

public func explore(_ c: Configuration, stopAtFirstViolation: Bool = false) -> Report {
    exploreModel(Model(c), stopAtFirstViolation: stopAtFirstViolation)
}
