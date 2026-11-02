// What the explorer runs: the objects, the mutators' programs, the number of
// pauses, and the four protocol switches. docs/models/relocation.md.

/// One mutator instruction. Each is a short sequence of model steps (see
/// `Relocation.swift`); a mutator holds no body pointer between instructions,
/// as the interpreter holds none between bytecodes.
public enum Instruction: Hashable, Sendable, CustomStringConvertible {
    /// `setSlot`: store `value` into `slot` of `object` with the post-store
    /// check (SPEC.md "Copy protocol").
    case store(object: Int, slot: Int, value: Int)
    /// `push_ivar`: relaxed load of the offset, then a load of the slot.
    case read(object: Int, slot: Int)
    /// A primitive holding a body pointer under a hazard slot across two
    /// accesses: store `value` into `slot`, then read it back
    /// (SPEC.md "Pins and hazards", `arrayCopy`).
    case hazard(object: Int, slot: Int, value: Int)
    /// The budget poll's slow path: advance the epoch word, park if a pause
    /// is requested (`advanceEpoch`, `safepoint`).
    case poll
    /// `leaveVM`: the epoch word becomes quiescent.
    case leave
    /// `enterVM`: epoch word 0 (seq_cst), then the current epoch.
    case enter

    public var description: String {
        switch self {
        case let .store(o, s, v): "store o\(o).s\(s) := \(v)"
        case let .read(o, s): "read o\(o).s\(s)"
        case let .hazard(o, s, v): "hazard o\(o).s\(s) := \(v)"
        case .poll: "poll"
        case .leave: "leaveVM"
        case .enter: "enterVM"
        }
    }
}

public struct Configuration: Sendable {
    /// Entries in the relocation set, all with their old bodies in one block.
    public var objects: Int
    /// Slots per body.
    public var slots: Int
    /// One program per mutator. A mutator still in the VM at the end of its
    /// program leaves it.
    public var programs: [[Instruction]]
    /// How many times the stopper may stop the world.
    public var pauses: Int

    /// The four rules, each on by default and turned off by one negative test.
    /// Redo the store when the offset changed or was RELOCATING.
    public var postStoreCheck = true
    /// The relocator reads every hazard word after its CAS and reverts.
    public var hazardCheck = true
    /// Free the evacuated block only when every epoch word is past it.
    public var epochRule = true
    /// The post-store check's store and reload are seq_cst (else release and
    /// acquire).
    public var seqCstStoreReload = true

    /// `enterVM` stores 0 (seq_cst) before reading the epoch; not one of the
    /// brief's four switches, an extra probe of the enter path.
    public var enterPublishesZeroFirst = true
    /// The order of the switch store (release in SPEC.md); relaxed is a probe
    /// that gives claim 2 a negative test.
    public var switchOrder = Order.release
    /// The relocator polls for a pause only between objects; off is a probe
    /// that gives claim 5 a negative test (a poll right after the CAS).
    public var relocatorPollsOnlyBetweenObjects = true

    public init(objects: Int, slots: Int, programs: [[Instruction]], pauses: Int) {
        self.objects = objects
        self.slots = slots
        self.programs = programs.map { program in
            var inVM = true
            for i in program {
                if i == .leave { inVM = false }
                if i == .enter { inVM = true }
            }
            return inVM ? program + [.leave] : program
        }
        self.pauses = pauses
    }

    var mutators: Int { programs.count }

    /// The mutator that writes each slot (index `object * slots + slot`), or
    /// nil. A slot has at most one writer, so its expected final value is
    /// that writer's last completed store.
    func writers() -> [Int?] {
        var w = [Int?](repeating: nil, count: objects * slots)
        for (m, program) in programs.enumerated() {
            for i in program {
                switch i {
                case let .store(o, s, _), let .hazard(o, s, _):
                    let k = o * slots + s
                    precondition(w[k] == nil || w[k] == m, "slot o\(o).s\(s) has two writers")
                    w[k] = m
                default: break
                }
            }
        }
        return w
    }

    /// The configuration every claim and negative test runs: two mutators,
    /// two objects of one slot in one block, one pause.
    ///
    /// M0 stores into o0 (post-store check), then polls and reads it back.
    /// M1 uses o1 through a hazard slot, leaves and re-enters the VM, and
    /// reads o1 back (a body pointer that may straddle the free).
    public static var standard: Configuration {
        Configuration(
            objects: 2, slots: 1,
            programs: [
                [.store(object: 0, slot: 0, value: 1), .poll, .read(object: 0, slot: 0)],
                [.hazard(object: 1, slot: 0, value: 2), .leave, .enter, .read(object: 1, slot: 0)],
            ],
            pauses: 1)
    }

    /// The standard configuration with a third mutator and two slots per
    /// body, to show the state space stays finite and the claims hold: M2
    /// stores into o1, the object M1 may hold under its hazard (so the store
    /// can meet a revert), then reads o0 holding a body pointer the epoch
    /// rule must wait for; it never polls and leaves at the end.
    public static var threeMutators: Configuration {
        Configuration(
            objects: 2, slots: 2,
            programs: [
                [.store(object: 0, slot: 0, value: 1), .poll, .read(object: 0, slot: 0)],
                [.hazard(object: 1, slot: 0, value: 2), .leave, .enter, .read(object: 1, slot: 0)],
                [.store(object: 1, slot: 1, value: 3), .read(object: 0, slot: 0)],
            ],
            pauses: 1)
    }

    /// Two mutators storing into both objects, two slots per body, two
    /// pauses: stores of both mutators into one object at once, a store
    /// into an object another mutator holds under a hazard, and pauses
    /// before and after the free.
    public static var contended: Configuration {
        Configuration(
            objects: 2, slots: 2,
            programs: [
                [.store(object: 0, slot: 0, value: 1), .poll, .store(object: 1, slot: 0, value: 11), .read(object: 0, slot: 1)],
                [.store(object: 0, slot: 1, value: 2), .hazard(object: 1, slot: 1, value: 12), .poll, .read(object: 1, slot: 0)],
            ],
            pauses: 2)
    }
}
