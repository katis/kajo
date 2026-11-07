// What the explorer runs: the objects, the workers' programs, the old-space
// collector's steps, and the protocol switches. docs/models/young-collection.md.

/// Where an instruction finds an object: a global root (an old object the
/// configuration marks as a root) or a register of the worker.
public enum Ref: Hashable, Sendable {
    case root(Int)
    case reg(Int)
}

/// One worker instruction. Each is a short sequence of model steps (see
/// `YoungCollection.swift`); a worker holds no body pointer between
/// instructions, as the interpreter holds none between bytecodes.
public enum Instruction: Hashable, Sendable {
    /// `push_ivar` into a register: `reg := from.slot`.
    case load(reg: Int, from: Ref, slot: Int)
    /// `store_ivar` (the interpreter's store): barrier word (relaxed); with a
    /// barrier on, the young deletion barrier and the snoop; the store
    /// (seq_cst) and the post-store check's reload (seq_cst); the insertion
    /// barrier (`remember`). `value` is a register, or nil for nil.
    case store(into: Ref, slot: Int, value: Int?)
    /// The same store from `primArrayCopy`: under a hazard slot, a relaxed
    /// store and no post-store check, then the same barriers.
    case copyStore(into: Ref, slot: Int, value: Int?)
    /// The register dies (a pop, a return).
    case drop(reg: Int)
    /// A safepoint: service every round owed, then advance the epoch word.
    case poll
    /// Allocate into entry `object` (if it is free) and put it in `reg`;
    /// slot 0 initialised from register `slotFrom` with a plain store and no
    /// barrier (amendment 13). In offload, the worker's new eden half.
    case alloc(reg: Int, object: Int, slotFrom: Int?)
    /// Offload: the owner's eden half is full: open its collection, flip to
    /// the other half and queue the collection for the collector thread.
    case flip
    /// Local: the owner's eden is full: collect its own nursery.
    case collect
    /// Offload: the owner waits until its nursery's collection is done (the
    /// wait at the start of its next flip).
    case waitDone
    /// A primitive that takes a raw body pointer, enters a blocking region,
    /// and reads through the pointer at the end (`slowPeek:`).
    case blockingLoad(reg: Int, from: Ref, slot: Int)
    /// `leaveVM` and `enterVM`.
    case leave, enter
}

/// The abstract old-space collector's steps (claim 5).
public enum OldSpaceStep: Hashable, Sendable {
    /// The initial-mark pause: the snapshot (used entries not in a young log)
    /// and the marks (snapshot entries reachable at the pause).
    case snapshot
    /// The lazy sweep: every unmarked snapshot entry is freed, one per step.
    case sweep
    /// A full stop-the-world collection: every used, unreachable entry that
    /// is not young is freed.
    case fullCollection
}

public enum Generation: Hashable, Sendable {
    case free, old
    case young(Int)
}

public struct ObjectSpec: Sendable {
    public var name: String
    public var generation: Generation
    /// Initial slot contents (object indices, nil for nil).
    public var slots: [Int?]
    /// A global root (only old objects; see "Choices").
    public var root: Bool
    /// Nurseries whose remembered set holds this object at the start (the
    /// membership bit set and the object on the nursery's carried list).
    public var rememberedFor: [Int]

    public init(_ name: String, _ generation: Generation, slots: [Int?] = [], root: Bool = false, rememberedFor: [Int] = []) {
        self.name = name
        self.generation = generation
        self.slots = slots
        self.root = root
        self.rememberedFor = rememberedFor
    }
}

public enum Mode: Sendable {
    /// Every worker collects its own nursery (SPEC Part 1); worker n owns
    /// nursery n.
    case local
    /// Worker 0 flips and a collector thread C collects (SPEC Part 2).
    case offload
}

/// When marking stops (claim 3).
public enum Termination: Sendable {
    /// SPEC step 4: drain rounds until one copies nothing.
    case afterARoundThatCopiesNothing
    /// Negative: no drain round; stop after T1.
    case afterT1
    /// Probe: exactly one drain round, whatever it copied.
    case afterOneDrainRound
}

public struct Configuration: Sendable {
    public var name: String
    public var mode: Mode
    public var nurseries: Int
    public var objects: [ObjectSpec]
    public var workerNames: [String]
    /// Initial registers per worker (object indices or nil).
    public var registers: [[Int?]]
    /// One program per worker. A worker still in the VM at its end leaves.
    public var programs: [[Instruction]]
    public var oldSpace: [OldSpaceStep] = []
    /// Model raw body pointers and eden reuse (claim 4): loads take a body
    /// pointer from the offset word and read through it in a later step.
    public var bodyPointers = false
    /// Memory-model switch: no store buffers.
    public var sequentiallyConsistent = false
    /// Check claim 3 when marking stops. A violation ends its path, so a
    /// negative test that wants to reach the free itself (claim 1) turns
    /// this off; the claim-3 check finds the same object earlier.
    public var terminationCheck = true

    // The protocol's rules, each on by default and turned off by one test.
    /// H0, a round that only turns the barrier on, completes before H1 scans
    /// any stack (SPEC "Ordering and soundness" 4). Claim 2.
    public var barrierOnRound = true
    /// Claim 3.
    public var termination = Termination.afterARoundThatCopiesNothing
    /// The order of `remember`'s load of the remembered word (seq_cst in the
    /// code). Claim 6.
    public var rememberLoadOrder = Order.seqCst
    /// The interpreter store's post-store check reloads the offset word with
    /// seq_cst between the store and the barrier (ADR 0007). Claim 6: with
    /// it, the model orders the store before the remembered-word load
    /// whatever that load's order; see the doc.
    public var postStoreReload = true
    /// Offload: at T1 scan the owner's new-half objects allocated before its
    /// H1 acknowledgement (amendment 7a). Claim 7.
    public var newHalfScan = true
    /// Offload: a store of a Y value into a new-half holder of the same
    /// nursery remembers the holder (amendment 7b). Claim 7.
    public var snoop = true
    /// The old eden (and survivor-from) is reused only after every epoch
    /// word passed the collection's epoch. Claim 4.
    public var epochRule = true
    /// A worker in a blocking region keeps its epoch word (else it publishes
    /// quiescent, as outside the VM). Claim 4.
    public var blockingRegionsKeepEpoch = true
    /// A worker waiting inside the VM is quiescent for the epoch
    /// (amendment 14). Claim 4.
    public var waitersAreQuiescent = true
    /// Deferred entry frees belong to their nursery: the snapshot excludes
    /// them and a full collection leaves them used (amendment 17). Claim 5.
    public var deferredEntriesBelongToTheirNursery = true
    /// The final mark on the devices (docs/modules/final-mark.md): worker 0
    /// is the main worker, whose flip or collect waits for a stop only once
    /// it is requested; while O merely wants one (`stwWanted`) it may open
    /// one collection, and O then waits for that one too. Off: module 7's
    /// rule, every opener waits while a stop is wanted. Liveness only: O
    /// still stops only once no collection is open.
    public var mainOpensWhileWanted = true

    public init(name: String, mode: Mode, nurseries: Int, objects: [ObjectSpec], workerNames: [String],
                registers: [[Int?]], programs: [[Instruction]], oldSpace: [OldSpaceStep] = []) {
        self.name = name
        self.mode = mode
        self.nurseries = nurseries
        self.objects = objects
        self.workerNames = workerNames
        self.registers = registers
        self.programs = programs.map { program in
            var inside = true
            for i in program {
                if i == .leave { inside = false }
                if i == .enter { inside = true }
            }
            return inside ? program + [.leave] : program
        }
        self.oldSpace = oldSpace
    }

    var workers: Int { programs.count }
    var maxSlots: Int { max(1, objects.map(\.slots.count).max() ?? 1) }
    var maxRegisters: Int { max(1, registers.map(\.count).max() ?? 1) }

    func objectIndex(_ name: String) -> Int {
        objects.firstIndex { $0.name == name }!
    }
}

// MARK: - the configurations

extension Configuration {
    /// Local collection by W of its nursery 0 while A and B run: SPEC
    /// "Ordering and soundness" point 4's interleaving (claim 2) and a
    /// deletion record that only a drain round publishes (claim 3).
    ///
    /// G is an old global whose slot holds X (young in nursery 0); G is in
    /// nursery 0's remembered set. A acknowledges, loads X from G, and holds
    /// it; B overwrites G's slot with nil between two polls.
    public static var local: Configuration {
        Configuration(
            name: "local", mode: .local, nurseries: 1,
            objects: [
                ObjectSpec("G", .old, slots: [1], root: true, rememberedFor: [0]),
                ObjectSpec("X", .young(0)),
            ],
            workerNames: ["W", "A", "B"],
            registers: [[], [nil], []],
            programs: [
                [.collect],
                [.poll, .load(reg: 0, from: .root(0), slot: 0), .poll, .drop(reg: 0)],
                [.poll, .poll, .store(into: .root(0), slot: 0, value: nil), .poll],
            ])
    }

    /// Local collection with a chain G -> X -> Z, where A takes X and then
    /// Z while B cuts both edges, the second after it acknowledged the first
    /// drain round: only a second drain round publishes that record. Claim 3
    /// with a termination rule that stops after one drain round.
    public static var chain: Configuration {
        Configuration(
            name: "chain", mode: .local, nurseries: 1,
            objects: [
                ObjectSpec("G", .old, slots: [1], root: true, rememberedFor: [0]),
                ObjectSpec("X", .young(0), slots: [2]),
                ObjectSpec("Z", .young(0)),
            ],
            workerNames: ["W", "A", "B"],
            registers: [[], [nil, nil], [nil]],
            programs: [
                [.collect],
                [.poll, .poll, .load(reg: 0, from: .root(0), slot: 0), .load(reg: 1, from: .reg(0), slot: 0),
                 .poll, .poll],
                [.poll, .poll, .load(reg: 0, from: .root(0), slot: 0), .store(into: .root(0), slot: 0, value: nil),
                 .poll, .store(into: .reg(0), slot: 0, value: nil), .poll],
            ])
    }

    /// Two local collections of nursery 0 while M stores X into the old
    /// remembered holder G (SPEC "Ordering and soundness" point 2): G must
    /// still be remembered at the second collection, which only it can
    /// keep X alive for. A reads G meanwhile. Claim 6. `copyStore` swaps
    /// M's store for the `primArrayCopy` store.
    public static func remembered(copyStore: Bool = false) -> Configuration {
        let store: Instruction = copyStore
            ? .copyStore(into: .root(0), slot: 0, value: 0)
            : .store(into: .root(0), slot: 0, value: 0)
        return Configuration(
            name: copyStore ? "remembered, arrayCopy store" : "remembered", mode: .local, nurseries: 1,
            objects: [
                ObjectSpec("G", .old, slots: [nil], root: true, rememberedFor: [0]),
                ObjectSpec("X", .young(0)),
            ],
            workerNames: ["W", "M", "A"],
            registers: [[], [1], [nil]],
            programs: [
                [.collect, .collect],
                [.poll, .poll, store, .drop(reg: 0)],
                [.poll, .load(reg: 0, from: .root(0), slot: 0), .poll, .drop(reg: 0)],
            ])
    }

    /// Offload: W flips nursery 0 to the collector thread C, allocates N in
    /// its new eden half, stores X (young, in Y) into N, publishes N in the
    /// old global G and drops both. A loads N from G and X from N, then cuts
    /// N's slot. N is not in Y and not remembered by the cross-nursery
    /// barrier (same nursery): only the new-half scan, the snoop, or a
    /// deletion record keeps X. Claim 7. `initialising` puts X into N with
    /// the allocation's own (unbarriered) initialising store instead.
    public static func newHalf(initialising: Bool = false) -> Configuration {
        let fill: [Instruction] = initialising
            ? [.alloc(reg: 1, object: 2, slotFrom: 0)]
            : [.alloc(reg: 1, object: 2, slotFrom: nil), .store(into: .reg(1), slot: 0, value: 0)]
        return Configuration(
            name: initialising ? "new half, initialising store" : "new half", mode: .offload, nurseries: 1,
            objects: [
                ObjectSpec("G", .old, slots: [nil], root: true),
                ObjectSpec("X", .young(0)),
                ObjectSpec("N", .free, slots: [nil]),
            ],
            workerNames: ["W", "A"],
            registers: [[1, nil], [nil, nil]],
            programs: [
                [.flip] + fill + [.store(into: .root(0), slot: 0, value: 1), .drop(reg: 0), .drop(reg: 1), .poll, .poll],
                [.poll, .load(reg: 0, from: .root(0), slot: 0), .load(reg: 1, from: .reg(0), slot: 0),
                 .store(into: .reg(0), slot: 0, value: nil), .poll, .poll],
            ])
    }

    /// Offload with body pointers: M reads Q (young, in Y, reachable from
    /// the old global G) through a raw body pointer, first in one
    /// instruction and then inside a blocking region, leaves and re-enters
    /// the VM and reads it again; W flips and waits for the collection
    /// (quiescent). The old eden is reused once the epoch rule allows it.
    /// Claim 4.
    public static var epochs: Configuration {
        var c = Configuration(
            name: "epochs", mode: .offload, nurseries: 1,
            objects: [
                ObjectSpec("G", .old, slots: [1], root: true, rememberedFor: [0]),
                ObjectSpec("Q", .young(0), slots: [nil]),
            ],
            workerNames: ["W", "M"],
            registers: [[], [nil, nil]],
            programs: [
                [.flip, .waitDone],
                [.load(reg: 0, from: .root(0), slot: 0), .load(reg: 1, from: .reg(0), slot: 0), .poll,
                 .blockingLoad(reg: 1, from: .reg(0), slot: 0), .leave, .enter,
                 .load(reg: 0, from: .root(0), slot: 0), .load(reg: 1, from: .reg(0), slot: 0)],
            ])
        c.bodyPointers = true
        return c
    }

    /// Two nurseries collected locally and overlapping, and an old-space
    /// collector: SPEC amendment 17. H (young in nursery 0) holds Y (young in
    /// nursery 1) and is in nursery 1's remembered set; H is dead. Nursery
    /// 0's collection defers H's free; nursery 1's collection may re-arm H,
    /// so the free waits for nursery 0's second collection, after which W0
    /// allocates into H's entry. O takes a snapshot and sweeps (or runs a
    /// full collection) in between. Claim 5.
    public static func ownership(_ oldSpace: [OldSpaceStep]) -> Configuration {
        Configuration(
            name: oldSpace == [.fullCollection] ? "ownership, full collection" : "ownership, snapshot and sweep",
            mode: .local, nurseries: 2,
            objects: [
                ObjectSpec("H", .young(0), slots: [1], rememberedFor: [1]),
                ObjectSpec("Y", .young(1)),
            ],
            workerNames: ["W0", "W1"],
            registers: [[nil], [1]],
            programs: [
                [.collect, .collect, .alloc(reg: 0, object: 0, slotFrom: nil)],
                [.collect],
            ],
            oldSpace: oldSpace)
    }
}
