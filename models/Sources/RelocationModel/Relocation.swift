// The protocol: the entry state machine of concurrent relocation, the
// post-store check, hazard slots and epoch freeing, as model steps.
// Each step is one atomic action of one thread (or one store-buffer drain).
// The step-to-SPEC table is in docs/models/relocation.md.

/// The claims of docs/models/relocation.md, plus deadlock.
public enum Claim: Int, Hashable, Sendable, CaseIterable, CustomStringConvertible {
    case noLostStore = 1
    case noStaleRead = 2
    case noHazardedMove = 3
    case noPrematureFree = 4
    case noRelocatingAtPause = 5
    case noDeadlock = 6

    public var description: String {
        switch self {
        case .noLostStore: "1 no lost store"
        case .noStaleRead: "2 no stale read"
        case .noHazardedMove: "3 no hazarded move"
        case .noPrematureFree: "4 no premature free"
        case .noRelocatingAtPause: "5 no RELOCATING at a pause"
        case .noDeadlock: "no deadlock"
        }
    }
}

public struct Violation: Hashable, Sendable {
    public var claim: Claim
    public var message: String
}

// MARK: - layout of shared memory

/// Where each shared word lives, and how to print addresses and values.
struct Layout {
    let objects: Int
    let slots: Int
    let mutators: Int

    /// Bit 32 of the offset word in the VM; any bit above the addresses here.
    static let relocating = 1 << 16
    /// Epoch word of a worker outside the VM (`quiescent`, UInt64.max).
    static let quiescent = 1 << 20
    /// Contents of to-space before the copy writes it.
    static let uninitialised = -1

    func offsetWord(_ o: Int) -> Int { o }
    func hazardWord(_ m: Int) -> Int { objects + m }
    func epochWord(_ m: Int) -> Int { objects + mutators + m }
    var globalEpoch: Int { objects + 2 * mutators }
    var oldBlockStart: Int { globalEpoch + 1 }
    func oldBody(_ o: Int) -> Int { oldBlockStart + o * slots }
    var newBlockStart: Int { oldBlockStart + objects * slots }
    func newBody(_ o: Int) -> Int { newBlockStart + o * slots }
    var words: Int { newBlockStart + objects * slots }

    /// The body an offset word leads to: RELOCATING reads through the alias
    /// mapping, which is the old body (`heap + (off + R)`).
    func body(_ offset: Int) -> Int { offset & ~Layout.relocating }
    func inOldBlock(_ address: Int) -> Bool {
        address >= oldBlockStart && address < newBlockStart
    }
    func hazardValue(_ o: Int) -> Int { o + 1 } // 0 is "no hazard"

    func initialWords() -> [Int] {
        var w = [Int](repeating: 0, count: words)
        for o in 0..<objects { w[offsetWord(o)] = oldBody(o) }
        for a in newBlockStart..<words { w[a] = Layout.uninitialised }
        return w // hazard words 0, epoch words 0 (in the VM, epoch 0), E = 0
    }

    func name(_ a: Int) -> String {
        if a < objects { return "offset[o\(a)]" }
        if a < objects + mutators { return "hz[M\(a - objects)]" }
        if a < globalEpoch { return "epoch[M\(a - objects - mutators)]" }
        if a == globalEpoch { return "E" }
        if a < newBlockStart {
            let k = a - oldBlockStart
            return "old(o\(k / slots)).s\(k % slots)"
        }
        let k = a - newBlockStart
        return "new(o\(k / slots)).s\(k % slots)"
    }

    func offsetName(_ v: Int) -> String {
        let b = body(v)
        let base: String
        if inOldBlock(b) { base = "old(o\((b - oldBlockStart) / slots))" }
        else { base = "new(o\((b - newBlockStart) / slots))" }
        return v & Layout.relocating != 0 ? base + "+R" : base
    }

    func valueName(_ a: Int, _ v: Int) -> String {
        if a < objects { return offsetName(v) }
        if a >= oldBlockStart && v == Layout.uninitialised { return "uninit" }
        if v == Layout.quiescent { return "quiescent" }
        return "\(v)"
    }
}

// MARK: - state

struct MutatorState: Hashable {
    var pc = 0
    var step = 0
    /// The one register an instruction keeps: e1, e, or the hazard's body
    /// offset.
    var register = 0
    var inVM = true
    var parked = false
}

enum RelocatorStep: Hashable {
    case poll
    case cas
    /// Only with `relocatorPollsOnlyBetweenObjects` off: a poll while the
    /// object is RELOCATING.
    case pollRelocating
    case hazardScan(Int)
    case copy(Int)
    case switchOffset
    case addPending
    case scanEpochs(Int)
    case done
}

struct RelocatorState: Hashable {
    var object = 0
    var step = RelocatorStep.poll
    var skipped = false
    var parked = false
    var minEpoch = Layout.quiescent
}

public struct State: Hashable {
    var memory: Memory
    var mutators: [MutatorState]
    var relocator = RelocatorState()
    /// `gcRequested`, set and cleared by the stopper under the VM mutex.
    var pauseRequested = false
    var pausesLeft: Int
    /// The epoch `s` recorded with the evacuated block, while it is pending.
    var pending: Int?
    var blockFreed = false
    /// Per slot, the value of its writer's last completed store.
    var lastWritten: [Int]
}

/// One transition: a label for traces (empty unless asked for), the next
/// state, and the claim it violates, if any.
struct Step {
    var label: String
    var next: State
    var violation: Violation?
}

// MARK: - the model

struct Model {
    let config: Configuration
    let layout: Layout
    let writers: [Int?]

    init(_ config: Configuration) {
        self.config = config
        self.layout = Layout(objects: config.objects, slots: config.slots, mutators: config.mutators)
        self.writers = config.writers()
    }

    var relocatorThread: Int { config.mutators }

    func initialState() -> State {
        State(
            memory: Memory(words: layout.initialWords(), threads: config.mutators + 1),
            mutators: Array(repeating: MutatorState(), count: config.mutators),
            pausesLeft: config.pauses,
            lastWritten: Array(repeating: 0, count: config.objects * config.slots))
    }

    func isFinished(_ s: State) -> Bool {
        s.relocator.step == .done
            && s.mutators.indices.allSatisfy { s.mutators[$0].pc == config.programs[$0].count }
    }

    /// Checks on a state with no successors: claim 1 at the end, or deadlock.
    func terminalViolation(_ s: State) -> Violation? {
        guard isFinished(s) else {
            return Violation(claim: .noDeadlock, message: "no thread can move and the run is not finished")
        }
        for o in 0..<config.objects {
            let offset = s.memory.words[layout.offsetWord(o)]
            if offset & Layout.relocating != 0 {
                return Violation(claim: .noRelocatingAtPause, message: "o\(o) left RELOCATING at the end")
            }
            for slot in 0..<config.slots where writers[o * config.slots + slot] != nil {
                let v = s.memory.words[layout.body(offset) + slot]
                let want = s.lastWritten[o * config.slots + slot]
                if v != want {
                    return Violation(
                        claim: .noLostStore,
                        message: "at the end o\(o).s\(slot) reads \(layout.valueName(layout.body(offset), v)) through \(layout.offsetName(offset)), last completed store was \(want)")
                }
            }
        }
        return nil
    }

    // MARK: successors

    func successors(_ s: State, labels: Bool) -> [Step] {
        var out: [Step] = []
        func emit(_ label: @autoclosure () -> String, _ next: State, _ v: Violation? = nil) {
            out.append(Step(label: labels ? label() : "", next: next, violation: v))
        }
        for m in 0..<config.mutators { mutatorSteps(s, m, emit) }
        relocatorSteps(s, emit)
        stopperSteps(s, emit)
        drainSteps(s, emit)
        return out
    }

    typealias Emit = (@autoclosure () -> String, State, Violation?) -> Void

    /// A body access at `address` after the block was freed.
    func useAfterFree(_ s: State, _ who: String, _ address: Int) -> Violation? {
        guard s.blockFreed && layout.inOldBlock(address) else { return nil }
        return Violation(claim: .noPrematureFree, message: "\(who) accesses \(layout.name(address)) in the freed block")
    }

    func drainSteps(_ s: State, _ emit: Emit) {
        for t in s.memory.buffers.indices {
            for i in s.memory.drainable(t) {
                var n = s
                let e = n.memory.drain(t, i)
                let who = t == relocatorThread ? "R" : "M\(t)"
                emit("\(who) drain: \(layout.name(e.address)) = \(layout.valueName(e.address, e.value)) (\(e.order) store becomes visible)",
                     n, useAfterFree(s, who + "'s buffered store", e.address))
            }
        }
    }

    // MARK: mutators

    func mutatorSteps(_ s: State, _ m: Int, _ emit: Emit) {
        let ms = s.mutators[m]
        let program = config.programs[m]
        guard ms.pc < program.count, !ms.parked else { return }
        let instruction = program[ms.pc]
        let who = "M\(m)"
        let L = layout
        var n = s
        func complete(_ n: inout State) {
            n.mutators[m].pc += 1
            n.mutators[m].step = 0
        }
        func set(_ n: inout State, step: Int, register: Int? = nil) {
            n.mutators[m].step = step
            if let r = register { n.mutators[m].register = r }
        }
        let tag = "\(who) \(instruction):"

        switch instruction {
        case let .store(o, slot, value):
            let sc = config.seqCstStoreReload
            let storeOrder: Order = sc ? .seqCst : .release
            let reloadOrder: Order = sc ? .seqCst : .acquire
            let k = o * config.slots + slot
            switch ms.step {
            case 0: // e1 = offset(o).load(relaxed)
                let e1 = s.memory.load(m, L.offsetWord(o), .relaxed)!
                set(&n, step: 1, register: e1)
                emit("\(tag) e1 = offset[o\(o)] (relaxed) -> \(L.offsetName(e1))", n, nil)
            case 1: // slot(heap + e1, i).store(v, seq_cst)
                let a = L.body(ms.register) + slot
                n.memory.store(m, a, value, storeOrder)
                if config.postStoreCheck {
                    set(&n, step: 2)
                } else {
                    n.lastWritten[k] = value
                    complete(&n)
                }
                emit("\(tag) \(L.name(a)) := \(value) (\(storeOrder), buffered)\(config.postStoreCheck ? "" : "; no post-store check, done")",
                     n, useAfterFree(s, who, a))
            case 2: // e2 = offset(o).load(seq_cst); compare
                guard let e2 = s.memory.load(m, L.offsetWord(o), reloadOrder) else { return }
                if e2 == ms.register && e2 & Layout.relocating == 0 {
                    n.lastWritten[k] = value
                    complete(&n)
                    emit("\(tag) e2 = offset[o\(o)] (\(reloadOrder)) -> \(L.offsetName(e2)), unchanged: done", n, nil)
                } else {
                    set(&n, step: 3)
                    emit("\(tag) e2 = offset[o\(o)] (\(reloadOrder)) -> \(L.offsetName(e2)), check fails: postStoreSlow", n, nil)
                }
            case 3: // postStoreSlow: wait while RELOCATING (acquire loads)
                let e = s.memory.load(m, L.offsetWord(o), .acquire)!
                guard e & Layout.relocating == 0 else { return } // spins
                set(&n, step: 4, register: e)
                emit("\(tag) postStoreSlow: e = offset[o\(o)] (acquire) -> \(L.offsetName(e))", n, nil)
            case 4: // redo the store into the current body
                let a = L.body(ms.register) + slot
                n.memory.store(m, a, value, storeOrder)
                set(&n, step: 5)
                emit("\(tag) postStoreSlow: \(L.name(a)) := \(value) (\(storeOrder), buffered)", n, useAfterFree(s, who, a))
            default: // 5: reload; done if unchanged
                guard let e = s.memory.load(m, L.offsetWord(o), reloadOrder) else { return }
                if e == ms.register {
                    n.lastWritten[k] = value
                    complete(&n)
                    emit("\(tag) postStoreSlow: offset[o\(o)] (\(reloadOrder)) -> \(L.offsetName(e)), unchanged: done", n, nil)
                } else {
                    set(&n, step: 3)
                    emit("\(tag) postStoreSlow: offset[o\(o)] (\(reloadOrder)) -> \(L.offsetName(e)), changed: again", n, nil)
                }
            }

        case let .read(o, slot):
            let k = o * config.slots + slot
            if ms.step == 0 {
                let e = s.memory.load(m, L.offsetWord(o), .relaxed)!
                set(&n, step: 1, register: e)
                emit("\(tag) e = offset[o\(o)] (relaxed) -> \(L.offsetName(e))", n, nil)
            } else {
                let a = L.body(ms.register) + slot
                let v = s.memory.load(m, a, .relaxed)!
                complete(&n)
                var violation = useAfterFree(s, who, a)
                if violation == nil && v == Layout.uninitialised {
                    violation = Violation(claim: .noStaleRead, message: "\(who) reads uninitialised to-space at \(L.name(a))")
                }
                if violation == nil && writers[k] == m && v != s.lastWritten[k] {
                    violation = Violation(claim: .noLostStore, message: "\(who) reads \(v) from \(L.name(a)) after its own completed store of \(s.lastWritten[k])")
                }
                emit("\(tag) \(L.name(a)) (relaxed) -> \(L.valueName(a, v))", n, violation)
            }

        case let .hazard(o, slot, value):
            let k = o * config.slots + slot
            switch ms.step {
            case 0: // hz[k].store(o, seq_cst)
                n.memory.store(m, L.hazardWord(m), L.hazardValue(o), .seqCst)
                set(&n, step: 1)
                emit("\(tag) hz[\(who)] := o\(o) (seq_cst, buffered)", n, nil)
            case 1: // loop { e = offset.load(seq_cst); spin while RELOCATING }
                guard let e = s.memory.load(m, L.offsetWord(o), .seqCst),
                      e & Layout.relocating == 0 else { return }
                set(&n, step: 2, register: e)
                emit("\(tag) e = offset[o\(o)] (seq_cst) -> \(L.offsetName(e)): body pointer p taken", n, nil)
            case 2: // first access through p: a store, no post-store check
                let a = L.body(ms.register) + slot
                n.memory.store(m, a, value, .relaxed)
                set(&n, step: 3)
                emit("\(tag) \(L.name(a)) := \(value) through p (relaxed, buffered)", n, useAfterFree(s, who, a))
            case 3: // second access through p: read it back
                let a = L.body(ms.register) + slot
                let v = s.memory.load(m, a, .relaxed)!
                set(&n, step: 4)
                emit("\(tag) \(L.name(a)) through p (relaxed) -> \(L.valueName(a, v))", n, useAfterFree(s, who, a))
            default: // hz[k].store(0, release)
                n.memory.store(m, L.hazardWord(m), 0, .release)
                n.lastWritten[k] = value
                complete(&n)
                emit("\(tag) hz[\(who)] := 0 (release, buffered): hazard released", n, nil)
            }

        case .poll:
            switch ms.step {
            case 0: // advanceEpoch: E.load(acquire) ...
                let e = s.memory.load(m, L.globalEpoch, .acquire)!
                set(&n, step: 1, register: e)
                emit("\(tag) E (acquire) -> \(e)", n, nil)
            case 1: // ... epoch word store(release)
                n.memory.store(m, L.epochWord(m), ms.register, .release)
                set(&n, step: 2)
                emit("\(tag) epoch[\(who)] := \(ms.register) (release, buffered)", n, nil)
            default: // safepoint: park if a pause is requested (mutex: full fence)
                guard s.memory.isDrained(m) else { return }
                if s.pauseRequested {
                    n.mutators[m].parked = true
                    emit("\(tag) pause requested: parks", n, nil)
                } else {
                    complete(&n)
                    emit("\(tag) no pause requested", n, nil)
                }
            }

        case .leave:
            if ms.step == 0 { // quiesce
                n.memory.store(m, L.epochWord(m), Layout.quiescent, .release)
                set(&n, step: 1)
                emit("\(tag) epoch[\(who)] := quiescent (release, buffered)", n, nil)
            } else { // mutex: active -= 1
                guard s.memory.isDrained(m) else { return }
                n.mutators[m].inVM = false
                complete(&n)
                emit("\(tag) leaves the VM", n, nil)
            }

        case .enter:
            switch ms.step {
            case 0: // mutex: wait while a pause is requested, active += 1
                guard s.memory.isDrained(m), !s.pauseRequested else { return }
                n.mutators[m].inVM = true
                set(&n, step: config.enterPublishesZeroFirst ? 1 : 2)
                emit("\(tag) enters the VM", n, nil)
            case 1:
                n.memory.store(m, L.epochWord(m), 0, .seqCst)
                set(&n, step: 2)
                emit("\(tag) epoch[\(who)] := 0 (seq_cst, buffered)", n, nil)
            case 2:
                guard let e = s.memory.load(m, L.globalEpoch, .seqCst) else { return }
                set(&n, step: 3, register: e)
                emit("\(tag) E (seq_cst) -> \(e)", n, nil)
            default:
                n.memory.store(m, L.epochWord(m), ms.register, .release)
                complete(&n)
                emit("\(tag) epoch[\(who)] := \(ms.register) (release, buffered)", n, nil)
            }
        }
    }

    /// Mutators that hold a body pointer into the old block right now: the
    /// register of an instruction that is about to use it.
    func pointerHolders(_ s: State) -> [Int] {
        s.mutators.indices.filter { m in
            let ms = s.mutators[m]
            guard ms.pc < config.programs[m].count, layout.inOldBlock(layout.body(ms.register)) else { return false }
            switch config.programs[m][ms.pc] {
            case .store: return ms.step == 1 || ms.step == 4
            case .read: return ms.step == 1
            case .hazard: return ms.step == 2 || ms.step == 3
            default: return false
            }
        }
    }

    /// Claim 4 at the moment of freeing: nobody holds a pointer into the
    /// block and no buffered store targets it.
    func freeViolation(_ s: State, _ by: String) -> Violation? {
        if let m = pointerHolders(s).first {
            return Violation(claim: .noPrematureFree, message: "\(by) frees the block while M\(m) holds a body pointer into it")
        }
        for t in s.memory.buffers.indices {
            if let e = s.memory.buffers[t].first(where: { layout.inOldBlock($0.address) }) {
                return Violation(claim: .noPrematureFree, message: "\(by) frees the block while a store to \(layout.name(e.address)) is still buffered")
            }
        }
        return nil
    }

    // MARK: relocator

    /// The step after a poll: the next object, or a retry of the free.
    func afterPoll(_ r: inout RelocatorState) {
        if r.step == .pollRelocating {
            r.step = config.hazardCheck ? .hazardScan(0) : .copy(0)
        } else if r.object < config.objects {
            r.step = .cas
        } else {
            r.step = .scanEpochs(0)
            r.minEpoch = Layout.quiescent
        }
    }

    /// After an object is switched or reverted.
    func nextObject(_ r: inout RelocatorState) {
        r.object += 1
        if r.object < config.objects { r.step = .poll }
        else { r.step = r.skipped ? .done : .addPending }
    }

    func relocatorSteps(_ s: State, _ emit: Emit) {
        let r = s.relocator
        guard !r.parked else { return }
        let t = relocatorThread
        let L = layout
        let o = r.object
        var n = s
        switch r.step {
        case .done:
            return
        case .poll, .pollRelocating: // between objects, and while waiting to free
            guard s.memory.isDrained(t) else { return }
            if s.pauseRequested {
                n.relocator.parked = true
                emit("R poll: pause requested: parks", n, nil)
            } else {
                afterPoll(&n.relocator)
                emit("R poll: no pause", n, nil)
            }
        case .cas: // step 4: CAS off -> off + R (seq_cst), then a seq_cst fence
            guard s.memory.isDrained(t) else { return }
            precondition(s.memory.words[L.offsetWord(o)] == L.oldBody(o))
            n.memory.words[L.offsetWord(o)] = L.oldBody(o) | Layout.relocating
            if config.relocatorPollsOnlyBetweenObjects {
                n.relocator.step = config.hazardCheck ? .hazardScan(0) : .copy(0)
            } else {
                n.relocator.step = .pollRelocating
            }
            emit("R relocate o\(o): CAS offset[o\(o)] old(o\(o)) -> old(o\(o))+R (seq_cst), fence (seq_cst)", n, nil)
        case let .hazardScan(i): // step 5: read every worker's hazard word (seq_cst)
            let v = s.memory.load(t, L.hazardWord(i), .seqCst)!
            if v == L.hazardValue(o) {
                n.memory.store(t, L.offsetWord(o), L.oldBody(o), .release)
                n.relocator.skipped = true
                nextObject(&n.relocator)
                emit("R relocate o\(o): hz[M\(i)] (seq_cst) -> o\(o): revert offset[o\(o)] := old(o\(o)) (release, buffered), skip", n, nil)
            } else {
                n.relocator.step = i + 1 < config.mutators ? .hazardScan(i + 1) : .copy(0)
                emit("R relocate o\(o): hz[M\(i)] (seq_cst) -> \(v == 0 ? "none" : "o\(v - 1)")", n, nil)
            }
        case let .copy(slot): // step 6: relaxed load from old, relaxed store into new
            let from = L.oldBody(o) + slot, to = L.newBody(o) + slot
            let v = s.memory.load(t, from, .relaxed)!
            n.memory.store(t, to, v, .relaxed)
            n.relocator.step = slot + 1 < config.slots ? .copy(slot + 1) : .switchOffset
            emit("R relocate o\(o): copy \(L.name(from)) (relaxed) -> \(v), \(L.name(to)) := \(v) (relaxed, buffered)", n, nil)
        case .switchOffset: // step 7: store new (release)
            var violation: Violation?
            for m in s.mutators.indices where s.mutators[m].pc < config.programs[m].count {
                if case let .hazard(ho, _, _) = config.programs[m][s.mutators[m].pc], ho == o,
                   (2...4).contains(s.mutators[m].step) {
                    violation = Violation(claim: .noHazardedMove, message: "R switches o\(o) while M\(m) holds it under its hazard slot")
                }
            }
            n.memory.store(t, L.offsetWord(o), L.newBody(o), config.switchOrder)
            nextObject(&n.relocator)
            emit("R relocate o\(o): switch offset[o\(o)] := new(o\(o)) (\(config.switchOrder), buffered)", n, violation)
        case .addPending: // step 8: pending with s = E; E += 1 (seq_cst RMW)
            guard s.memory.isDrained(t) else { return }
            let e = s.memory.words[L.globalEpoch]
            n.memory.words[L.globalEpoch] = e + 1
            n.pending = e
            n.relocator.step = .scanEpochs(0)
            n.relocator.minEpoch = Layout.quiescent
            emit("R addPending: block pending with s = \(e), E := \(e + 1) (seq_cst fetch_add)", n, nil)
        case let .scanEpochs(i): // tryFreePending
            guard let pendingEpoch = s.pending else {
                n.relocator.step = .done
                emit("R tryFreePending: nothing pending (freed at a pause)", n, nil)
                return
            }
            if config.epochRule && i < config.mutators {
                let v = s.memory.load(t, L.epochWord(i), .acquire)!
                n.relocator.minEpoch = min(r.minEpoch, v)
                n.relocator.step = .scanEpochs(i + 1)
                emit("R tryFreePending: epoch[M\(i)] (acquire) -> \(L.valueName(L.epochWord(i), v))", n, nil)
            } else if !config.epochRule || r.minEpoch > pendingEpoch {
                n.blockFreed = true
                n.pending = nil
                n.relocator.step = .done
                let why = config.epochRule ? "every epoch word > \(pendingEpoch)" : "no epoch rule"
                emit("R tryFreePending: \(why): frees the block", n, freeViolation(s, "R"))
            } else {
                n.relocator.step = .poll
                emit("R tryFreePending: min epoch \(r.minEpoch) <= \(pendingEpoch): waits", n, nil)
            }
        }
    }

    // MARK: stopper

    func stopperSteps(_ s: State, _ emit: Emit) {
        if !s.pauseRequested {
            guard s.pausesLeft > 0, !isFinished(s) else { return }
            var n = s
            n.pauseRequested = true
            n.pausesLeft -= 1
            emit("S requests a pause (gcRequested)", n, nil)
            return
        }
        let stopped = s.mutators.allSatisfy { !$0.inVM || $0.parked }
            && ((s.relocator.step == .done && s.memory.isDrained(relocatorThread)) || s.relocator.parked)
        guard stopped else { return }
        var n = s
        var violation: Violation?
        for o in 0..<config.objects where s.memory.words[layout.offsetWord(o)] & Layout.relocating != 0 {
            violation = Violation(claim: .noRelocatingAtPause, message: "o\(o) is RELOCATING with the world stopped")
        }
        var freed = ""
        if s.pending != nil {
            if violation == nil { violation = freeViolation(s, "the pause") }
            n.blockFreed = true
            n.pending = nil
            freed = ", frees the pending block"
        }
        n.pauseRequested = false
        for m in n.mutators.indices where n.mutators[m].parked {
            n.mutators[m].parked = false
            n.mutators[m].pc += 1
            n.mutators[m].step = 0
        }
        if n.relocator.parked {
            n.relocator.parked = false
            afterPoll(&n.relocator)
        }
        emit("S world stopped\(freed); releases it", n, violation)
    }
}

// MARK: - fingerprint

extension State {
    /// A 64-bit fingerprint of every field, for the explorer's visited set
    /// (hash compaction, as TLC does). Written as plain loops because the
    /// synthesized `Hashable` over nested arrays dominated the run time.
    func fingerprint() -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        @inline(__always) func mix(_ v: Int) {
            h = (h ^ UInt64(bitPattern: Int64(v))) &* 0x0000_0100_0000_01B3
            h ^= h >> 29
        }
        for w in memory.words { mix(w) }
        for b in memory.buffers {
            mix(-1000 - b.count)
            for e in b { mix(e.address); mix(e.value); mix(Int(e.order.rawValue)) }
        }
        for m in mutators {
            mix(m.pc); mix(m.step); mix(m.register); mix(m.inVM ? 1 : 0); mix(m.parked ? 1 : 0)
        }
        switch relocator.step {
        case .poll: mix(1)
        case .cas: mix(2)
        case .pollRelocating: mix(3)
        case let .hazardScan(i): mix(4); mix(i)
        case let .copy(i): mix(5); mix(i)
        case .switchOffset: mix(6)
        case .addPending: mix(7)
        case let .scanEpochs(i): mix(8); mix(i)
        case .done: mix(9)
        }
        mix(relocator.object); mix(relocator.skipped ? 1 : 0); mix(relocator.parked ? 1 : 0); mix(relocator.minEpoch)
        mix(pauseRequested ? 1 : 0); mix(pausesLeft); mix(pending ?? -1); mix(blockFreed ? 1 : 0)
        for v in lastWritten { mix(v) }
        // final avalanche (splitmix64)
        h ^= h >> 30; h = h &* 0xbf58_476d_1ce4_e5b9
        h ^= h >> 27; h = h &* 0x94d0_49bb_1331_11eb
        h ^= h >> 31
        return h
    }
}
