// The protocol: young collection without stopping the world (ADR 0008,
// experiments/concurrent-young/SPEC.md), as model steps. Marks and edges, not
// bodies: a collection is a concurrent mark of Y_k whose action on a marked
// object is the copy. Each step is one atomic action of one thread or one
// store-buffer drain. The step-to-SPEC table is in
// docs/models/young-collection.md.

/// The claims of docs/models/young-collection.md that have their own check.
/// Claims 2, 6 and 7 are about what loses an object, so their negative
/// tests find claim 1 (and usually 3) broken.
public enum Claim: Int, Hashable, Sendable, CaseIterable, CustomStringConvertible {
    case noLostObject = 1
    case soundTermination = 3
    case noPrematureReuse = 4
    case oneOwnerPerEntry = 5
    case noDeadlock = 8

    public var description: String {
        switch self {
        case .noLostObject: "1 no lost object"
        case .soundTermination: "3 termination is sound"
        case .noPrematureReuse: "4 no premature reuse"
        case .oneOwnerPerEntry: "5 one owner per entry"
        case .noDeadlock: "no deadlock"
        }
    }
}

public typealias Violation = ModelKit.Violation<Claim>
typealias Step = Transition<State, Claim>

// MARK: - layout of shared memory

struct Layout {
    let objects: Int
    let slots: Int
    let nurseries: Int
    let workers: Int

    static let quiescent = 1 << 20
    static func member(_ n: Int) -> Int { 1 << n }
    static func pending(_ n: Int) -> Int { 1 << (8 + n) }

    func slot(_ o: Int, _ i: Int) -> Int { o * slots + i }
    func rem(_ o: Int) -> Int { objects * slots + o }
    /// The header's slot count, as a flag: 1 (the object's slots) or 0 (a
    /// dead holder whose free is deferred, amendment 10).
    func header(_ o: Int) -> Int { objects * slots + objects + o }
    /// The offset word, as a flag: 0 the body in the old eden, 1 the copy.
    func offset(_ o: Int) -> Int { objects * slots + 2 * objects + o }
    var barrierWord: Int { objects * slots + 3 * objects }
    func collecting(_ n: Int) -> Int { barrierWord + 1 + n }
    func epoch(_ w: Int) -> Int { barrierWord + 1 + nurseries + w }
    var globalEpoch: Int { barrierWord + 1 + nurseries + workers }
    var words: Int { globalEpoch + 1 }
}

// MARK: - state

enum Entry: Hashable {
    case free, old
    case young(Int)
    /// Dead, used, in no young log: its free is deferred by its nursery.
    case deferred(Int)
}

struct ObjectState: Hashable {
    var entry: Entry
    /// In the Y of its nursery's current (or last) collection.
    var inY = false
    var marked = false
    /// The old body was reused (claim 4).
    var bodyGone = false
    var inSnapshot = false
    var oldSpaceMarked = false
    var reusedSinceSnapshot = false
    /// Witness bookkeeping for claim 5.
    var deferredAcrossPause = false
    var reusedAfterDeferredPause = false
}

enum RoundKind: Int8, Hashable, CustomStringConvertible {
    case h0, h1, drain
    var description: String {
        switch self {
        case .h0: "H0"
        case .h1: "H1"
        case .drain: "drain"
        }
    }
}

struct NurseryState: Hashable {
    var active = false
    var done = true
    var round = 0
    var kind = RoundKind.h0
    var need = 0
    var acked: [Int]
    var handedRoots: [Int] = []
    var handedRem: [Int] = []
    var handedDel: [Int] = []
    /// Offload: the owner's new-half objects allocated before its H1
    /// acknowledgement (amendment 7a).
    var newHalf: [Int] = []
    /// The Y of the current (or last) collection, for the sweep.
    var young: [Int] = []
    var carried: [Int] = []
    var nextCarried: [Int] = []
    var deferred: [Int] = []
}

enum Phase: Int8, Hashable {
    case openRound, waitRound, newHalf, carried, takeHanded, roots, holders, dels, drain, decide
    case finish, fold, sweep, bump, epochScan, epochRetry, reuse, deferredFree, done
}

struct CollectorState: Hashable {
    var k: Int
    var phase = Phase.openRound
    var kind = RoundKind.h0
    var i = 0
    var sub = 0
    var namesK = false
    var inDrainRound = false
    var copied = false
    var carried: [Int] = []
    var newHalf: [Int] = []
    var roots: [Int] = []
    var rems: [Int] = []
    var dels: [Int] = []
    var gray: [Int] = []
    var s = 0
    var minEpoch = Int.max
    var seen: [Int] = []
    /// A participant collector quiesced while waiting.
    var waiting = false
}

struct WorkerState: Hashable {
    var pc = 0
    var step = 0
    var regs: [Int]
    /// Instruction temporaries (barrier word seen, a body pointer).
    var a = 0
    var inside = true
    var blocking = false
    var waiting = false
    var rem: [[Int]]
    var del: [[Int]]
    /// Local: the collection this worker runs inside `collect`.
    var collection: CollectorState?
}

public struct State: Hashable {
    var memory: Memory
    var objects: [ObjectState]
    var workers: [WorkerState]
    var nurseries: [NurseryState]
    /// Offload: the collector thread's collection and its queue.
    var collector: CollectorState?
    var queue: [Int] = []
    var ycActive = 0
    var stwWanted = false
    var oldSpacePc = 0
    var oldSpaceStep = 0
}

// MARK: - the model

struct Model {
    let config: Configuration
    let layout: Layout
    let N: Int

    init(_ config: Configuration) {
        self.config = config
        self.N = config.objects.count
        self.layout = Layout(objects: config.objects.count, slots: config.maxSlots,
                             nurseries: config.nurseries, workers: config.workers)
    }

    var collectorThread: Int { config.workers }
    var oldSpaceThread: Int { config.workers + 1 }

    func initialState() -> State {
        let L = layout
        var words = [Int](repeating: 0, count: L.words)
        var objects: [ObjectState] = []
        var nurseries = (0..<config.nurseries).map { _ in
            NurseryState(acked: Array(repeating: 0, count: config.workers))
        }
        for (o, spec) in config.objects.enumerated() {
            let entry: Entry
            switch spec.generation {
            case .free: entry = .free
            case .old: entry = .old
            case let .young(n): entry = .young(n)
            }
            objects.append(ObjectState(entry: entry))
            for i in 0..<config.maxSlots {
                words[L.slot(o, i)] = i < spec.slots.count ? (spec.slots[i] ?? -1) : -1
            }
            words[L.header(o)] = spec.slots.isEmpty ? 0 : 1
            for n in spec.rememberedFor {
                words[L.rem(o)] |= Layout.member(n)
                nurseries[n].carried.append(o)
            }
        }
        let workers = (0..<config.workers).map { w in
            var regs = config.registers[w].map { $0 ?? -1 }
            while regs.count < config.maxRegisters { regs.append(-1) }
            return WorkerState(
                regs: regs,
                rem: Array(repeating: [], count: config.nurseries),
                del: Array(repeating: [], count: config.nurseries))
        }
        return State(
            memory: Memory(words: words, threads: config.workers + 2, sequentiallyConsistent: config.sequentiallyConsistent),
            objects: objects, workers: workers, nurseries: nurseries)
    }

    // MARK: names

    func name(_ o: Int) -> String { o < 0 ? "nil" : config.objects[o].name }
    func workerName(_ w: Int) -> String { config.workerNames[w] }
    func names(_ list: [Int]) -> String { "{" + list.map(name).joined(separator: ", ") + "}" }

    func instructionName(_ w: Int, _ i: Instruction) -> String {
        func ref(_ r: Ref) -> String {
            switch r {
            case let .root(o): name(o)
            case let .reg(k): "r\(k)"
            }
        }
        func val(_ v: Int?) -> String { v.map { "r\($0)" } ?? "nil" }
        switch i {
        case let .load(r, f, s): return "r\(r) := \(ref(f)).s\(s)"
        case let .store(t, s, v): return "store \(ref(t)).s\(s) := \(val(v))"
        case let .copyStore(t, s, v): return "arrayCopy \(ref(t)).s\(s) := \(val(v))"
        case let .drop(r): return "drop r\(r)"
        case .poll: return "poll"
        case let .alloc(r, o, f): return "r\(r) := alloc \(name(o))" + (f.map { " with s0 := r\($0)" } ?? "")
        case .flip: return "flip"
        case .collect: return "collect"
        case .waitDone: return "waitDone"
        case let .blockingLoad(r, f, s): return "slowPeek r\(r) := \(ref(f)).s\(s)"
        case .leave: return "leaveVM"
        case .enter: return "enterVM"
        }
    }

    // MARK: object predicates

    func youngIn(_ s: State, _ v: Int) -> Int? {
        guard v >= 0, case let .young(n) = s.objects[v].entry else { return nil }
        return n
    }

    func isFree(_ s: State, _ v: Int) -> Bool { v >= 0 && s.objects[v].entry == .free }

    func owner(_ n: Int) -> Int { n } // worker n owns nursery n (offload: worker 0, nursery 0)

    func isFinished(_ s: State) -> Bool {
        s.workers.indices.allSatisfy { s.workers[$0].pc == config.programs[$0].count }
            && s.collector == nil && s.queue.isEmpty
            && s.oldSpacePc == config.oldSpace.count
    }

    /// Every object a worker can reach: from registers and global roots,
    /// through slot words in memory and through stores still buffered.
    func reachable(_ s: State) -> [Bool] {
        var buffered: [Int: [Int]] = [:]
        for b in s.memory.buffers {
            for e in b where e.address < N * layout.slots { buffered[e.address, default: []].append(e.value) }
        }
        var seen = [Bool](repeating: false, count: N)
        var stack: [Int] = []
        func push(_ v: Int) {
            if v >= 0 && !seen[v] { seen[v] = true; stack.append(v) }
        }
        for w in s.workers { for r in w.regs { push(r) } }
        for (o, spec) in config.objects.enumerated() where spec.root && s.objects[o].entry != .free { push(o) }
        while let o = stack.popLast() {
            for i in 0..<layout.slots {
                let a = layout.slot(o, i)
                push(s.memory.words[a])
                for v in buffered[a] ?? [] { push(v) }
            }
        }
        return seen
    }

    func terminalViolation(_ s: State) -> Violation? {
        if !isFinished(s) {
            return Violation(claim: .noDeadlock, message: "no thread can move and the run is not finished")
        }
        return nil
    }

    func isWitness(_ s: State) -> Bool {
        s.objects.contains { $0.reusedAfterDeferredPause }
    }

    // MARK: successors

    typealias Emit = (@autoclosure () -> String, State, Violation?) -> Void

    func successors(_ s: State, labels: Bool) -> [Step] {
        var out: [Step] = []
        func emit(_ label: @autoclosure () -> String, _ next: State, _ v: Violation?) {
            out.append(Step(label: labels ? label() : "", next: next, violation: v))
        }
        for w in 0..<config.workers { workerSteps(s, w, emit) }
        if let c = s.collector {
            collectorSteps(s, c, participant: nil, emit)
        } else if let k = s.queue.first {
            var n = s
            n.queue.removeFirst()
            n.collector = CollectorState(k: k, kind: config.barrierOnRound ? .h0 : .h1)
            emit("C takes nursery \(k)'s collection from the queue", n, nil)
        }
        oldSpaceSteps(s, emit)
        drainSteps(s, emit)
        return out
    }

    func threadName(_ t: Int) -> String {
        t < config.workers ? workerName(t) : (t == collectorThread ? "C" : "O")
    }

    func drainSteps(_ s: State, _ emit: Emit) {
        for t in s.memory.buffers.indices {
            for i in s.memory.drainable(t) {
                var n = s
                let e = n.memory.drain(t, i)
                emit("\(threadName(t)) drain: \(wordName(e.address)) = \(valueName(e.address, e.value)) (\(e.order) store becomes visible)", n, nil)
            }
        }
    }

    func wordName(_ a: Int) -> String {
        let L = layout
        if a < N * L.slots { return "\(name(a / L.slots)).s\(a % L.slots)" }
        if a < L.header(0) { return "rem[\(name(a - L.rem(0)))]" }
        if a < L.offset(0) { return "header[\(name(a - L.header(0)))]" }
        if a < L.barrierWord { return "offset[\(name(a - L.offset(0)))]" }
        if a == L.barrierWord { return "barrierWord" }
        if a < L.epoch(0) { return "collecting[\(a - L.collecting(0))]" }
        if a < L.globalEpoch { return "epoch[\(workerName(a - L.epoch(0)))]" }
        return "E"
    }

    func valueName(_ a: Int, _ v: Int) -> String {
        if a < N * layout.slots { return name(v) }
        if a >= layout.rem(0) && a < layout.header(0) { return remName(v) }
        if a >= layout.offset(0) && a < layout.barrierWord { return v == 0 ? "old body" : "copy" }
        if v == Layout.quiescent { return "quiescent" }
        return "\(v)"
    }

    func remName(_ v: Int) -> String {
        var parts: [String] = []
        for n in 0..<config.nurseries {
            if v & Layout.member(n) != 0 { parts.append("member \(n)") }
            if v & Layout.pending(n) != 0 { parts.append("pending \(n)") }
        }
        return parts.isEmpty ? "0" : parts.joined(separator: "+")
    }

    // MARK: rounds (SPEC "Handshakes")

    /// The nursery whose open round worker `w` owes, if any.
    func owedRound(_ s: State, _ w: Int) -> Int? {
        let ws = s.workers[w]
        guard ws.inside, !ws.blocking else { return nil }
        for k in 0..<config.nurseries {
            let ns = s.nurseries[k]
            if ns.active && ns.need > 0 && ns.acked[w] != ns.round { return k }
        }
        return nil
    }

    /// One round's work for worker `w` (by `w`, or by proxy): H0 clears the
    /// deletion buffer, H1 scans the stack (when `scan`) and publishes, a
    /// drain round publishes. Answers a description.
    func roundWork(_ n: inout State, _ w: Int, _ k: Int, scan: Bool) -> String {
        let kind = n.nurseries[k].kind
        var did: [String] = []
        switch kind {
        case .h0:
            if !n.workers[w].del[k].isEmpty { did.append("clears del \(names(n.workers[w].del[k]))") }
            n.workers[w].del[k] = []
        case .h1, .drain:
            if kind == .h1 && scan {
                let found = n.workers[w].regs.filter { $0 >= 0 && youngIn(n, $0) == k && n.objects[$0].inY }
                n.nurseries[k].handedRoots += found
                did.append("stack scan finds \(names(found))")
            }
            if !n.workers[w].rem[k].isEmpty {
                n.nurseries[k].handedRem += n.workers[w].rem[k]
                did.append("publishes rem \(names(n.workers[w].rem[k]))")
                n.workers[w].rem[k] = []
            }
            if !n.workers[w].del[k].isEmpty {
                n.nurseries[k].handedDel += n.workers[w].del[k]
                did.append("publishes del \(names(n.workers[w].del[k]))")
                n.workers[w].del[k] = []
            }
            if kind == .h1 && config.mode == .offload && w == owner(k) {
                let range = n.objects.indices.filter { youngIn(n, $0) == k && !n.objects[$0].inY }
                n.nurseries[k].newHalf = range
                did.append("records new half \(names(range))")
            }
        }
        n.nurseries[k].acked[w] = n.nurseries[k].round
        return did.isEmpty ? "" : ": " + did.joined(separator: ", ")
    }

    /// Worker `w` services the round of nursery `k` (mutex: full fence),
    /// then, unless it is polling (the poll advances at its end), advances
    /// its epoch word as `serviceHandshakes` does. A waiter is no longer
    /// quiescent after it; it quiesces again before it blocks.
    func serviceRound(_ s: State, _ w: Int, _ k: Int, _ tag: String, advance: Bool = true, _ emit: Emit) {
        guard s.memory.isDrained(w) else { return }
        var n = s
        let kind = s.nurseries[k].kind
        let did = roundWork(&n, w, k, scan: true)
        n.nurseries[k].need -= 1
        var epoch = ""
        if advance {
            let e = n.memory.words[layout.globalEpoch]
            n.memory.store(w, layout.epoch(w), e, .release)
            n.workers[w].waiting = false
            n.workers[w].collection?.waiting = false
            epoch = "; E (acquire) -> \(e), epoch[\(workerName(w))] := \(e) (release)"
        }
        emit("\(tag) acknowledges \(kind) of nursery \(k)\(did)\(epoch)", n, nil)
    }

    // MARK: waiting (SPEC "Handshakes": every wait loop services rounds)

    /// A worker waits inside the VM for `ready`: services owed rounds,
    /// quiesces (amendment 14) and blocks; on wake it advances its epoch
    /// under the mutex. Answers true when the caller may act now.
    func waitSteps(_ s: State, _ w: Int, ready: Bool, _ tag: String, _ emit: Emit) -> Bool {
        let ws = s.workers[w]
        if ready {
            if !ws.waiting { return true }
            guard s.memory.isDrained(w) else { return false }
            var n = s
            n.workers[w].waiting = false
            let e = s.memory.words[layout.globalEpoch]
            n.memory.words[layout.epoch(w)] = e
            emit("\(tag) wakes: epoch[\(workerName(w))] := \(e) (under the mutex)", n, nil)
            return false
        }
        if let k = owedRound(s, w) {
            serviceRound(s, w, k, tag, emit)
            return false
        }
        if config.waitersAreQuiescent && !ws.waiting && s.memory.isDrained(w) {
            var n = s
            n.workers[w].waiting = true
            n.memory.words[layout.epoch(w)] = Layout.quiescent
            emit("\(tag) waits: epoch[\(workerName(w))] := quiescent (under the mutex)", n, nil)
        }
        return false
    }

    // MARK: workers

    func resolve(_ s: State, _ w: Int, _ r: Ref) -> Int {
        switch r {
        case let .root(o): o
        case let .reg(k): s.workers[w].regs[k]
        }
    }

    func useAfterFree(_ s: State, _ who: String, _ o: Int) -> Violation? {
        guard isFree(s, o) else { return nil }
        return Violation(claim: .noLostObject, message: "\(who) uses \(name(o)), whose entry is free")
    }

    func complete(_ n: inout State, _ w: Int) {
        n.workers[w].pc += 1
        n.workers[w].step = 0
    }

    func workerSteps(_ s: State, _ w: Int, _ emit: Emit) {
        let ws = s.workers[w]
        let program = config.programs[w]
        guard ws.pc < program.count else { return }
        let instruction = program[ws.pc]
        let L = layout
        let who = workerName(w)
        let tag = "\(who) \(instructionName(w, instruction)):"
        var n = s

        switch instruction {
        case let .load(r, from, slot):
            let o = resolve(s, w, from)
            if o < 0 {
                n.workers[w].regs[r] = -1
                complete(&n, w)
                emit("\(tag) source is nil", n, nil)
                return
            }
            if config.bodyPointers && ws.step == 0 {
                let p = s.memory.load(w, L.offset(o), .relaxed)!
                n.workers[w].a = p
                n.workers[w].step = 1
                emit("\(tag) body pointer from offset[\(name(o))] (relaxed) -> \(p == 0 ? "old body" : "copy")", n, useAfterFree(s, who, o))
                return
            }
            let v = s.memory.load(w, L.slot(o, slot), .relaxed)!
            n.workers[w].regs[r] = v
            complete(&n, w)
            var violation = useAfterFree(s, who, o) ?? useAfterFree(s, who, v)
            if violation == nil && config.bodyPointers && ws.a == 0 && s.objects[o].bodyGone {
                violation = Violation(claim: .noPrematureReuse, message: "\(who) reads \(name(o)) through a pointer into its old body, which was reused")
            }
            emit("\(tag) \(name(o)).s\(slot) (relaxed) -> \(name(v))", n, violation)

        case let .store(into, slot, value), let .copyStore(into, slot, value):
            storeSteps(s, w, instruction, into, slot, value, tag, emit)

        case let .drop(r):
            n.workers[w].regs[r] = -1
            complete(&n, w)
            emit("\(tag) r\(r) := nil", n, nil)

        case .poll:
            if ws.step == 0 {
                if let k = owedRound(s, w) {
                    serviceRound(s, w, k, tag, advance: false, emit)
                    return
                }
                let e = s.memory.load(w, L.globalEpoch, .acquire)!
                n.memory.store(w, L.epoch(w), e, .release)
                complete(&n, w)
                emit("\(tag) E (acquire) -> \(e), epoch[\(who)] := \(e) (release)", n, nil)
            }

        case let .alloc(r, o, from):
            let k = config.mode == .offload ? 0 : w
            if s.objects[o].entry != .free {
                n.workers[w].regs[r] = -1
                complete(&n, w)
                emit("\(tag) entry \(name(o)) is not free; allocates elsewhere (not modelled)", n, nil)
                return
            }
            let v = from.map { s.workers[w].regs[$0] } ?? -1
            var obj = ObjectState(entry: .young(k))
            obj.reusedSinceSnapshot = s.objects[o].inSnapshot
            obj.inSnapshot = s.objects[o].inSnapshot
            obj.oldSpaceMarked = s.objects[o].oldSpaceMarked
            obj.reusedAfterDeferredPause = s.objects[o].deferredAcrossPause
            n.objects[o] = obj
            // A fresh entry is initialised before it is published.
            for i in 0..<L.slots { n.memory.words[L.slot(o, i)] = -1 }
            n.memory.words[L.rem(o)] = 0
            n.memory.words[L.header(o)] = config.objects[o].slots.isEmpty ? 0 : 1
            n.memory.words[L.offset(o)] = 0
            if v >= 0 { n.memory.store(w, L.slot(o, 0), v, .relaxed) }
            n.workers[w].regs[r] = o
            complete(&n, w)
            emit("\(tag) \(name(o)) young in nursery \(k)\(config.mode == .offload ? ", new half" : "")\(v >= 0 ? ", s0 := \(name(v)) (relaxed, no barrier)" : "")",
                 n, useAfterFree(s, who, v))

        case .flip, .collect:
            let k = w
            if instruction == .collect, let c = ws.collection {
                collectorSteps(s, c, participant: w, emit)
                return
            }
            let ready = !s.stwWanted && !s.nurseries[k].active
            guard waitSteps(s, w, ready: ready, tag, emit), s.memory.isDrained(w) else { return }
            let young = s.objects.indices.filter { youngIn(s, $0) == k }
            for o in young {
                n.objects[o].inY = true
                n.objects[o].marked = false
                n.objects[o].bodyGone = false
                n.memory.words[L.offset(o)] = 0
            }
            n.memory.words[L.collecting(k)] = 1
            n.memory.words[L.barrierWord] += 1
            n.ycActive += 1
            n.nurseries[k].active = true
            n.nurseries[k].done = false
            n.nurseries[k].need = 0
            n.nurseries[k].newHalf = []
            n.nurseries[k].young = young
            let c = CollectorState(k: k, kind: config.barrierOnRound ? .h0 : .h1)
            if instruction == .flip {
                n.queue.append(k)
                complete(&n, w)
                emit("\(tag) opens nursery \(k)'s collection (collecting[\(k)] := 1, barrierWord += 1, Y = \(names(young))), flips to the other eden half, queues it for C", n, nil)
            } else {
                n.workers[w].collection = c
                emit("\(tag) opens nursery \(k)'s collection (collecting[\(k)] := 1, barrierWord += 1, Y = \(names(young)))", n, nil)
            }

        case .waitDone:
            guard waitSteps(s, w, ready: s.nurseries[owner(w)].done, tag, emit) else { return }
            complete(&n, w)
            emit("\(tag) nursery \(w)'s collection is done", n, nil)

        case let .blockingLoad(r, from, slot):
            let o = resolve(s, w, from)
            switch ws.step {
            case 0: // blockingBegin: service owed rounds, then mark blocking (mutex)
                if let k = owedRound(s, w) {
                    serviceRound(s, w, k, tag, emit)
                    return
                }
                guard s.memory.isDrained(w) else { return }
                n.workers[w].blocking = true
                n.workers[w].step = 1
                if !config.blockingRegionsKeepEpoch {
                    n.memory.words[L.epoch(w)] = Layout.quiescent
                    emit("\(tag) blockingBegin, epoch[\(who)] := quiescent (no epoch rule for blocking regions)", n, nil)
                } else {
                    emit("\(tag) blockingBegin (epoch word kept)", n, nil)
                }
            case 1:
                let p = s.memory.load(w, L.offset(o), .relaxed)!
                n.workers[w].a = p
                n.workers[w].step = 2
                emit("\(tag) body pointer from offset[\(name(o))] (relaxed) -> \(p == 0 ? "old body" : "copy"); blocks", n, useAfterFree(s, who, o))
            case 2:
                let v = s.memory.load(w, L.slot(o, slot), .relaxed)!
                n.workers[w].regs[r] = v
                n.workers[w].step = 3
                var violation = useAfterFree(s, who, o)
                if violation == nil && ws.a == 0 && s.objects[o].bodyGone {
                    violation = Violation(claim: .noPrematureReuse, message: "\(who) reads \(name(o)) through a pointer into its old body, which was reused")
                }
                emit("\(tag) reads \(name(o)).s\(slot) through the pointer -> \(name(v))", n, violation)
            default: // blockingEnd (mutex)
                guard s.memory.isDrained(w) else { return }
                n.workers[w].blocking = false
                if !config.blockingRegionsKeepEpoch {
                    n.memory.words[L.epoch(w)] = s.memory.words[L.globalEpoch]
                }
                complete(&n, w)
                emit("\(tag) blockingEnd", n, nil)
            }

        case .leave: // under one mutex hold: owed rounds, quiesce, leave
            if let k = owedRound(s, w) {
                serviceRound(s, w, k, tag, emit)
                return
            }
            guard s.memory.isDrained(w) else { return }
            n.memory.words[L.epoch(w)] = Layout.quiescent
            n.workers[w].inside = false
            // Outside the VM a worker holds no reference (SPEC "Handshakes");
            // the stack it ran belongs to a Process, not modelled.
            n.workers[w].regs = n.workers[w].regs.map { _ in -1 }
            complete(&n, w)
            emit("\(tag) epoch[\(who)] := quiescent, leaves the VM, holds nothing (under the mutex)", n, nil)

        case .enter:
            switch ws.step {
            case 0:
                guard s.memory.isDrained(w) else { return }
                n.workers[w].inside = true
                n.workers[w].step = 1
                emit("\(tag) enters the VM", n, nil)
            case 1:
                n.memory.store(w, L.epoch(w), 0, .seqCst)
                n.workers[w].step = 2
                emit("\(tag) epoch[\(who)] := 0 (seq_cst)", n, nil)
            default:
                guard let e = s.memory.load(w, L.globalEpoch, .seqCst) else { return }
                n.memory.store(w, L.epoch(w), e, .release)
                complete(&n, w)
                emit("\(tag) E (seq_cst) -> \(e), epoch[\(who)] := \(e) (release)", n, nil)
            }
        }
    }

    /// The store paths with their barriers (SPEC "Barriers"; the experiment's
    /// `storeWithBarriers`, `preStoreSlow`, `setSlotAndBarrier`, `barrier`,
    /// `remember`, and the `primArrayCopy` loop).
    func storeSteps(_ s: State, _ w: Int, _ instruction: Instruction, _ into: Ref, _ slot: Int, _ value: Int?,
                    _ tag: String, _ emit: Emit) {
        let ws = s.workers[w]
        let L = layout
        let who = workerName(w)
        let h = resolve(s, w, into)
        let v = value.map { ws.regs[$0] } ?? -1
        let interpreter: Bool
        if case .store = instruction { interpreter = true } else { interpreter = false }
        var n = s
        if h < 0 {
            complete(&n, w)
            emit("\(tag) target is nil", n, nil)
            return
        }
        /// The insertion barrier's condition: v young in a nursery other than
        /// the holder's.
        func crossNursery() -> Int? {
            guard let k = youngIn(s, v) else { return nil }
            return youngIn(s, h) == k ? nil : k
        }
        switch ws.step {
        case 0: // barrierWord (relaxed)
            let bw = s.memory.load(w, L.barrierWord, .relaxed)!
            n.workers[w].a = bw
            n.workers[w].step = bw != 0 ? 1 : 3
            emit("\(tag) barrierWord (relaxed) -> \(bw)\(bw != 0 ? ": barriers on" : "")", n, useAfterFree(s, who, h))
        case 1: // young deletion barrier, then the snoop's condition
            let old = s.memory.load(w, L.slot(h, slot), .relaxed)!
            var did = "old \(h < 0 ? "" : name(h)).s\(slot) (relaxed) -> \(name(old))"
            if let k = youngIn(s, old), s.memory.load(w, L.collecting(k), .acquire)! != 0 {
                n.workers[w].del[k].append(old)
                did += ", collecting[\(k)] (acquire) -> 1: del[\(k)] += \(name(old))"
            }
            n.workers[w].step = 3
            if config.mode == .offload && config.snoop, let k = youngIn(s, v), youngIn(s, h) == k,
               s.objects[v].inY, !s.objects[h].inY, s.memory.load(w, L.collecting(k), .acquire)! != 0 {
                n.workers[w].step = 2
                did += "; snoop: \(name(v)) in Y_\(k) into new-half \(name(h)): remember \(name(h))"
            }
            emit("\(tag) \(did)", n, nil)
        case 2, 10: // the snoop's remember (before the store, as in preStoreSlow)
            let k = youngIn(s, v)!
            rememberSteps(s, w, h, k, phase: ws.step == 2 ? 0 : 1, then: 3, tag + " snoop", emit)
        case 3: // the store
            let order: Order = interpreter ? .seqCst : .relaxed
            n.memory.store(w, L.slot(h, slot), v, order)
            n.workers[w].step = interpreter && config.postStoreReload ? 4 : 5
            emit("\(tag) \(name(h)).s\(slot) := \(name(v)) (\(order))", n, nil)
        case 4: // post-store check: reload the offset word (seq_cst)
            guard s.memory.load(w, L.offset(h), .seqCst) != nil else { return }
            n.workers[w].step = 5
            emit("\(tag) post-store check: offset[\(name(h))] (seq_cst) unchanged", n, nil)
        case 5, 6: // insertion barrier
            guard let k = crossNursery() else {
                complete(&n, w)
                emit("\(tag) no insertion barrier (\(name(v)) not young in another nursery than \(name(h)))", n, nil)
                return
            }
            rememberSteps(s, w, h, k, phase: ws.step == 5 ? 0 : 1, then: nil, tag, emit)
        default:
            preconditionFailure("store step \(ws.step)")
        }
    }

    /// `remember(o)` for nursery k: load the remembered word (seq_cst in the
    /// code); if the bit is clear, fetch_or it and push the holder if this
    /// call set it. `then` is the store step to go on with, nil to complete.
    func rememberSteps(_ s: State, _ w: Int, _ h: Int, _ k: Int, phase: Int, then: Int?, _ tag: String, _ emit: Emit) {
        let L = layout
        var n = s
        let bit = Layout.member(k)
        func next(_ n: inout State) {
            if let t = then { n.workers[w].step = t } else { complete(&n, w) }
        }
        if phase == 0 {
            guard let r = s.memory.load(w, L.rem(h), config.rememberLoadOrder) else { return }
            if r & bit != 0 {
                next(&n)
                emit("\(tag) rem[\(name(h))] (\(config.rememberLoadOrder)) -> \(remName(r)): already remembered", n, nil)
            } else {
                n.workers[w].step = then == nil ? 6 : 10
                emit("\(tag) rem[\(name(h))] (\(config.rememberLoadOrder)) -> \(remName(r))", n, nil)
            }
        } else {
            guard let old = n.memory.readModifyWrite(w, L.rem(h), { $0 | bit }) else { return }
            var did = "fetch_or rem[\(name(h))] member \(k) (seq_cst) -> was \(remName(old))"
            if old & bit == 0 {
                n.workers[w].rem[k].append(h)
                did += ": rem[\(k)] += \(name(h))"
            }
            next(&n)
            emit("\(tag) \(did)", n, nil)
        }
    }

    // MARK: collector (SPEC Part 1 steps 2 to 6; ycCollect)

    /// Store the collector state back where it lives.
    func put(_ n: inout State, _ c: CollectorState?, participant: Int?) {
        if let w = participant { n.workers[w].collection = c } else { n.collector = c }
    }

    func collectorSteps(_ s: State, _ c: CollectorState, participant: Int?, _ emit: Emit) {
        let L = layout
        let k = c.k
        let t = participant ?? collectorThread
        let who = participant.map { workerName($0) + " collect" } ?? "C"
        let tag = "\(who) [\(k)]"
        var n = s
        var c2 = c

        /// Classify a reference found by the collector (`classify`): 1 when
        /// it is young in k after this collection, 2 + j when young in
        /// another nursery j, 0 otherwise. Evacuates (marks) an unmarked Y_k
        /// object: the header and offset CAS of the copy are a full fence, so
        /// this needs the collector's buffer empty (nil when it is not).
        func classify(_ n: inout State, _ c: inout CollectorState, _ v: Int, _ did: inout String) -> Int? {
            guard v >= 0 else { return 0 }
            guard let j = youngIn(n, v) else { return 0 }
            if j != k { return 2 + j }
            if n.objects[v].marked || !n.objects[v].inY { return 1 }
            guard n.memory.isDrained(t) else { return nil }
            n.objects[v].marked = true
            c.copied = true
            if !config.objects[v].slots.isEmpty { c.gray.append(v) }
            if config.bodyPointers {
                n.memory.store(t, L.offset(v), 1, .release)
                did += ", copies \(name(v)) (offset CAS, fence, switch release)"
            } else {
                did += ", copies \(name(v))"
            }
            return 1
        }

        func advanceTo(_ c: inout CollectorState, _ phase: Phase) {
            c.phase = phase
            c.i = 0
            c.sub = 0
        }

        /// After a holder list or a drain, what comes next.
        func afterT1Item(_ c: inout CollectorState) {
            switch c.phase {
            case .newHalf: advanceTo(&c, .carried)
            case .carried: advanceTo(&c, .takeHanded)
            case .roots: advanceTo(&c, .holders)
            case .holders: advanceTo(&c, .dels)
            case .dels: advanceTo(&c, .drain)
            default: preconditionFailure()
            }
        }

        switch c.phase {
        case .openRound: // runRound: under the mutex, proxies for outside and blocking workers
            guard s.memory.isDrained(t) else { return }
            n.nurseries[k].round += 1
            n.nurseries[k].kind = c.kind
            var need = 0
            var proxies: [String] = []
            for w in 0..<config.workers {
                let ws = n.workers[w]
                if ws.inside && !ws.blocking {
                    need += 1
                } else {
                    let did = roundWork(&n, w, k, scan: ws.blocking)
                    proxies.append(workerName(w) + " by proxy" + did)
                }
            }
            n.nurseries[k].need = need
            if c.kind == .drain { c2.copied = false }
            advanceTo(&c2, .waitRound)
            put(&n, c2, participant: participant)
            emit("\(tag) opens \(c.kind) (round \(n.nurseries[k].round), need \(need))\(proxies.isEmpty ? "" : "; " + proxies.joined(separator: "; "))", n, nil)

        case .waitRound:
            if s.nurseries[k].need == 0 {
                if c.waiting {
                    guard s.memory.isDrained(t), let w = participant else { return }
                    c2.waiting = false
                    let e = s.memory.words[L.globalEpoch]
                    n.memory.words[L.epoch(w)] = e
                    put(&n, c2, participant: participant)
                    emit("\(tag) wakes: epoch[\(workerName(w))] := \(e) (under the mutex)", n, nil)
                    return
                }
                switch c.kind {
                case .h0:
                    c2.kind = .h1
                    advanceTo(&c2, .openRound)
                    put(&n, c2, participant: participant)
                    emit("\(tag) H0 complete", n, nil)
                case .h1:
                    // T1: the new-half range, the carried list (SPEC step 3).
                    c2.newHalf = config.mode == .offload && config.newHalfScan ? s.nurseries[k].newHalf : []
                    c2.carried = s.nurseries[k].carried
                    n.nurseries[k].carried = []
                    advanceTo(&c2, .newHalf)
                    put(&n, c2, participant: participant)
                    emit("\(tag) H1 complete; T1\(c2.newHalf.isEmpty ? "" : ": new half \(names(c2.newHalf))"), carried \(names(c2.carried))", n, nil)
                case .drain:
                    advanceTo(&c2, .takeHanded)
                    put(&n, c2, participant: participant)
                    emit("\(tag) drain round complete", n, nil)
                }
                return
            }
            if let w = participant {
                if let j = owedRound(s, w) {
                    serviceRound(s, w, j, tag, emit)
                    return
                }
                if config.waitersAreQuiescent && !c.waiting && s.memory.isDrained(t) {
                    c2.waiting = true
                    n.memory.words[L.epoch(w)] = Layout.quiescent
                    put(&n, c2, participant: participant)
                    emit("\(tag) waits for the round: epoch[\(workerName(w))] := quiescent (under the mutex)", n, nil)
                }
            }

        case .newHalf: // scanNewHalf: the recorded objects' slots as roots
            guard c.i < c.newHalf.count else {
                afterT1Item(&c2)
                put(&n, c2, participant: participant)
                emit("\(tag) new half scanned", n, nil)
                return
            }
            let o = c.newHalf[c.i]
            let v = s.memory.load(t, L.slot(o, c.sub), .relaxed)!
            var did = ""
            guard classify(&n, &c2, v, &did) != nil else { return }
            c2.sub += 1
            if c2.sub >= max(1, config.objects[o].slots.count) { c2.sub = 0; c2.i += 1 }
            put(&n, c2, participant: participant)
            emit("\(tag) new half: \(name(o)).s\(c.sub) (relaxed) -> \(name(v))\(did)", n, nil)

        case .carried, .holders: // scanHolder
            let list = c.phase == .carried ? c.carried : c.rems
            guard c.i < list.count else {
                afterT1Item(&c2)
                put(&n, c2, participant: participant)
                emit("\(tag) \(c.phase == .carried ? "carried" : "remembered") holders scanned", n, nil)
                return
            }
            let h = list[c.i]
            let bit = Layout.member(k)
            let slots = config.objects[h].slots.count
            switch c.sub {
            case 0: // fetch_and(~bit k), seq_cst, and the fence
                guard let old = n.memory.readModifyWrite(t, L.rem(h), { $0 & ~bit }) else { return }
                if old & bit == 0 {
                    c2.i += 1
                    put(&n, c2, participant: participant)
                    emit("\(tag) scanHolder \(name(h)): fetch_and rem (seq_cst) -> was \(remName(old)): not a member, skip", n, nil)
                } else {
                    c2.sub = 1
                    c2.namesK = false
                    put(&n, c2, participant: participant)
                    emit("\(tag) scanHolder \(name(h)): fetch_and rem (seq_cst) -> was \(remName(old)), fence", n, nil)
                }
            case 1: // header: slot count; a holder in Y_k is traced if reachable
                let hdr = s.memory.load(t, L.header(h), .relaxed)!
                if hdr == 0 || slots == 0 || (youngIn(s, h) == k && s.objects[h].inY) {
                    c2.i += 1
                    c2.sub = 0
                    put(&n, c2, participant: participant)
                    emit("\(tag) scanHolder \(name(h)): \(hdr == 0 || slots == 0 ? "header says no slots" : "in Y_\(k), traced if reachable"): done", n, nil)
                } else {
                    c2.sub = 2
                    put(&n, c2, participant: participant)
                    emit("\(tag) scanHolder \(name(h)): header (relaxed) -> \(slots) slot\(slots == 1 ? "" : "s")", n, nil)
                }
            default:
                let i = c.sub - 2
                if i < slots {
                    let v = s.memory.load(t, L.slot(h, i), .relaxed)!
                    var did = ""
                    guard let r = classify(&n, &c2, v, &did) else { return }
                    if r == 1 { c2.namesK = true }
                    c2.sub += 1
                    put(&n, c2, participant: participant)
                    emit("\(tag) scanHolder \(name(h)): s\(i) (relaxed) -> \(name(v))\(did)", n, nil)
                } else if c.namesK { // keepForNext: the pending bit
                    let pend = Layout.pending(k)
                    guard let old = n.memory.readModifyWrite(t, L.rem(h), { $0 | pend }) else { return }
                    if old & pend == 0 { n.nurseries[k].nextCarried.append(h) }
                    c2.i += 1
                    c2.sub = 0
                    put(&n, c2, participant: participant)
                    emit("\(tag) scanHolder \(name(h)): names Y_\(k): keepForNext, fetch_or rem pending \(k) (seq_cst) -> was \(remName(old))", n, nil)
                } else {
                    c2.i += 1
                    c2.sub = 0
                    put(&n, c2, participant: participant)
                    emit("\(tag) scanHolder \(name(h)): names nothing in nursery \(k): not kept", n, nil)
                }
            }

        case .takeHanded: // under the mutex
            guard s.memory.isDrained(t) else { return }
            c2.roots = s.nurseries[k].handedRoots
            c2.rems = s.nurseries[k].handedRem
            c2.dels = s.nurseries[k].handedDel
            n.nurseries[k].handedRoots = []
            n.nurseries[k].handedRem = []
            n.nurseries[k].handedDel = []
            advanceTo(&c2, .roots)
            put(&n, c2, participant: participant)
            emit("\(tag) takes handed: roots \(names(c2.roots)), rem \(names(c2.rems)), del \(names(c2.dels))", n, nil)

        case .roots, .dels: // visit
            let list = c.phase == .roots ? c.roots : c.dels
            guard c.i < list.count else {
                afterT1Item(&c2)
                put(&n, c2, participant: participant)
                emit("\(tag) \(c.phase == .roots ? "stack roots" : "deletion records") visited", n, nil)
                return
            }
            let v = list[c.i]
            var did = ""
            guard classify(&n, &c2, v, &did) != nil else { return }
            c2.i += 1
            put(&n, c2, participant: participant)
            emit("\(tag) visits \(c.phase == .roots ? "root" : "deletion record") \(name(v))\(did.isEmpty ? ": nothing to copy" : did)", n, nil)

        case .drain: // scan copied objects' new bodies
            guard let o = c.gray.last else {
                advanceTo(&c2, .decide)
                put(&n, c2, participant: participant)
                emit("\(tag) gray stack empty", n, nil)
                return
            }
            let slots = config.objects[o].slots.count
            if c.sub >= slots {
                c2.gray.removeLast()
                c2.sub = 0
                put(&n, c2, participant: participant)
                emit("\(tag) drain: \(name(o)) scanned", n, nil)
                return
            }
            let v = s.memory.load(t, L.slot(o, c.sub), .relaxed)!
            var did = ""
            guard let r = classify(&n, &c2, v, &did) else { return }
            if r >= 2 { // rememberFor: the barrier's rule applied to the copy
                let j = r - 2
                guard let old = n.memory.readModifyWrite(t, L.rem(o), { $0 | Layout.member(j) }) else { return }
                if old & Layout.member(j) == 0 {
                    if let w = participant { n.workers[w].rem[j].append(o) } else { n.nurseries[j].carried.append(o) }
                    did += ", rememberFor \(j): \(name(o))"
                }
            }
            c2.sub += 1
            put(&n, c2, participant: participant)
            emit("\(tag) drain: \(name(o)).s\(c.sub) (relaxed) -> \(name(v))\(did)", n, nil)

        case .decide: // after T1 or a drain round (SPEC step 4)
            var stop = false
            var why = ""
            if !c.inDrainRound {
                if config.termination == .afterT1 { stop = true; why = "no drain rounds" }
            } else {
                switch config.termination {
                case .afterARoundThatCopiesNothing:
                    stop = !c.copied
                    why = c.copied ? "" : "the round copied nothing"
                case .afterOneDrainRound, .afterT1:
                    stop = true
                    why = "one drain round done"
                }
            }
            if !stop {
                c2.kind = .drain
                c2.inDrainRound = true
                advanceTo(&c2, .openRound)
                put(&n, c2, participant: participant)
                emit("\(tag) \(c.inDrainRound ? "the round copied something" : "T1 done"): another drain round", n, nil)
                return
            }
            // Claim 3: nothing reachable in Y_k is left unmarked.
            let reach = reachable(s)
            var violation: Violation?
            if config.terminationCheck,
               let o = s.objects.indices.first(where: { reach[$0] && youngIn(s, $0) == k && s.objects[$0].inY && !s.objects[$0].marked }) {
                violation = Violation(claim: .soundTermination, message: "\(who) stops marking (\(why)) with \(name(o)) reachable and unmarked")
            }
            advanceTo(&c2, .finish)
            put(&n, c2, participant: participant)
            emit("\(tag) stops marking: \(why)", n, violation)

        case .finish: // flag off, under the mutex
            guard s.memory.isDrained(t) else { return }
            n.memory.words[L.collecting(k)] = 0
            n.memory.words[L.barrierWord] -= 1
            n.nurseries[k].active = false
            n.nurseries[k].handedRoots = []
            n.nurseries[k].handedRem = []
            n.nurseries[k].handedDel = []
            advanceTo(&c2, .fold)
            put(&n, c2, participant: participant)
            emit("\(tag) finish: collecting[\(k)] := 0, barrierWord -= 1 (under the mutex)", n, nil)

        case .fold: // foldCarried
            let list = s.nurseries[k].nextCarried
            guard c.i < list.count else {
                advanceTo(&c2, .sweep)
                put(&n, c2, participant: participant)
                emit("\(tag) carried set folded", n, nil)
                return
            }
            let h = list[c.i]
            guard let old = n.memory.readModifyWrite(t, L.rem(h), { ($0 | Layout.member(k)) & ~Layout.pending(k) }) else { return }
            c2.i += 1
            put(&n, c2, participant: participant)
            emit("\(tag) foldCarried \(name(h)): fetch_or member \(k), fetch_and ~pending \(k): was \(remName(old))", n, nil)

        case .sweep: // sweepCollection: per Y entry
            let young = s.nurseries[k].young
            guard c.i < young.count else {
                n.nurseries[k].carried += n.nurseries[k].nextCarried
                n.nurseries[k].nextCarried = []
                advanceTo(&c2, .bump)
                put(&n, c2, participant: participant)
                emit("\(tag) entry sweep done; carried := \(names(n.nurseries[k].carried))", n, nil)
                return
            }
            let o = young[c.i]
            c2.i += 1
            if s.objects[o].marked {
                put(&n, c2, participant: participant)
                emit("\(tag) sweep: \(name(o)) survives", n, nil)
                return
            }
            let reach = reachable(s)
            var violation: Violation?
            if reach[o] {
                violation = Violation(claim: .noLostObject, message: "\(who) frees \(name(o)), which a worker can still reach")
            }
            let r = s.memory.load(t, L.rem(o), .relaxed)!
            if r != 0 {
                n.memory.store(t, L.header(o), 0, .release)
                n.memory.store(t, L.rem(o), 0, .seqCst)
                n.nurseries[k].deferred.append(o)
                n.objects[o].entry = .deferred(k)
                put(&n, c2, participant: participant)
                emit("\(tag) sweep: \(name(o)) dead, rem (relaxed) -> \(remName(r)): header slots := 0 (release), rem := 0 (seq_cst), free deferred", n, violation)
            } else {
                n.objects[o].entry = .free
                put(&n, c2, participant: participant)
                emit("\(tag) sweep: \(name(o)) dead: entry freed", n, violation)
            }

        case .bump: // the epoch s; a participant advances its own word first
            guard let old = n.memory.readModifyWrite(t, L.globalEpoch, { $0 + 1 }) else { return }
            c2.s = old
            c2.minEpoch = Int.max
            c2.seen = []
            var did = ""
            if let w = participant {
                n.memory.store(t, L.epoch(w), old + 1, .release)
                did = "; epoch[\(workerName(w))] := \(old + 1) (release)"
            }
            advanceTo(&c2, config.epochRule ? .epochScan : .reuse)
            put(&n, c2, participant: participant)
            emit("\(tag) s = E, E := \(old + 1) (seq_cst fetch_add)\(did)\(config.epochRule ? "" : "; no epoch rule")", n, nil)

        case .epochScan: // epochWait: every participant's word > s
            if c.i < config.workers {
                let e = s.memory.load(t, L.epoch(c.i), .acquire)!
                c2.minEpoch = min(c.minEpoch, e)
                c2.seen.append(e)
                c2.i += 1
                put(&n, c2, participant: participant)
                emit("\(tag) epoch wait: epoch[\(workerName(c.i))] (acquire) -> \(valueName(L.epoch(c.i), e))", n, nil)
            } else if c.minEpoch > c.s {
                advanceTo(&c2, .reuse)
                put(&n, c2, participant: participant)
                emit("\(tag) every epoch word > \(c.s)", n, nil)
            } else {
                advanceTo(&c2, .epochRetry)
                put(&n, c2, participant: participant)
                emit("\(tag) epoch wait: min \(c.minEpoch) <= \(c.s): again", n, nil)
            }

        case .epochRetry:
            // A spin: scanning again only matters once a word it read
            // changed, or the collector (a participant) has something to do.
            if let w = participant {
                if let j = owedRound(s, w) {
                    serviceRound(s, w, j, tag, emit)
                    return
                }
                let mine = s.memory.load(t, L.epoch(w), .relaxed)!
                let e = s.memory.load(t, L.globalEpoch, .acquire)!
                if mine != e {
                    n.memory.store(t, L.epoch(w), e, .release)
                    put(&n, c2, participant: participant)
                    emit("\(tag) epoch wait: epoch[\(workerName(w))] := \(e) (release)", n, nil)
                    return
                }
            }
            let changed = (0..<config.workers).contains { s.memory.load(t, L.epoch($0), .acquire)! != c.seen[$0] }
            guard changed else { return }
            c2.minEpoch = Int.max
            c2.seen = []
            advanceTo(&c2, .epochScan)
            put(&n, c2, participant: participant)
            emit("\(tag) epoch wait: a word changed, scans again", n, nil)

        case .reuse: // the old eden and survivor-from may be reused
            var violation: Violation?
            if config.bodyPointers {
                for o in s.nurseries[k].young {
                    n.objects[o].bodyGone = true
                    for w in 0..<config.workers where holdsOldBody(s, w, o) {
                        violation = Violation(claim: .noPrematureReuse, message: "\(who) reuses the old eden while \(workerName(w)) holds a pointer into \(name(o))'s old body")
                    }
                }
            }
            advanceTo(&c2, .deferredFree)
            put(&n, c2, participant: participant)
            emit("\(tag) old eden and survivor-from may be reused", n, violation)

        case .deferredFree: // a dead holder re-armed meanwhile waits again
            let list = s.nurseries[k].deferred
            guard c.i < list.count else {
                advanceTo(&c2, .done)
                put(&n, c2, participant: participant)
                emit("\(tag) deferred frees done", n, nil)
                return
            }
            let o = list[c.i]
            guard let old = n.memory.readModifyWrite(t, L.rem(o), { _ in 0 }) else { return }
            if old != 0 {
                c2.i += 1
                put(&n, c2, participant: participant)
                emit("\(tag) deferred \(name(o)): exchange rem 0 (seq_cst) -> was \(remName(old)): re-armed, kept for the next collection", n, nil)
                return
            }
            n.nurseries[k].deferred.remove(at: c.i)
            var violation: Violation?
            switch s.objects[o].entry {
            case .deferred(k):
                n.objects[o].entry = .free
            default:
                violation = Violation(claim: .oneOwnerPerEntry, message: "\(who) frees deferred entry \(name(o)), but the old-space collector already freed it\(s.objects[o].entry == .free ? "" : " and it holds a new object")")
                if s.objects[o].entry != .free { n.objects[o].entry = .free }
            }
            put(&n, c2, participant: participant)
            emit("\(tag) deferred \(name(o)): exchange rem 0 (seq_cst) -> was 0: entry freed", n, violation)

        case .done: // under the mutex
            guard s.memory.isDrained(t) else { return }
            n.ycActive -= 1
            n.nurseries[k].done = true
            if let w = participant {
                n.workers[w].collection = nil
                complete(&n, w)
            } else {
                n.collector = nil
            }
            emit("\(tag) collection done", n, nil)
        }
    }

    /// Worker `w` holds a raw pointer into `o`'s old body: between taking it
    /// and the read through it.
    func holdsOldBody(_ s: State, _ w: Int, _ o: Int) -> Bool {
        let ws = s.workers[w]
        guard ws.pc < config.programs[w].count, ws.a == 0 else { return false }
        switch config.programs[w][ws.pc] {
        case let .load(_, from, _): return ws.step == 1 && resolve(s, w, from) == o
        case let .blockingLoad(_, from, _): return ws.step == 2 && resolve(s, w, from) == o
        default: return false
        }
    }

    // MARK: old-space collector (claim 5) and stops

    /// Every worker is at a safepoint (between instructions, waiting, or
    /// outside) with its buffer drained, and no young collection runs: the
    /// world can stop ("stops and collections are not interleaved").
    func worldCanStop(_ s: State) -> Bool {
        guard s.ycActive == 0, s.collector == nil else { return false }
        for w in 0..<config.workers {
            let ws = s.workers[w]
            guard s.memory.isDrained(w) else { return false }
            if ws.pc == config.programs[w].count || !ws.inside || ws.waiting || ws.blocking { continue }
            if ws.step != 0 || ws.collection != nil { return false }
        }
        return true
    }

    func oldSpaceSteps(_ s: State, _ emit: Emit) {
        guard s.oldSpacePc < config.oldSpace.count else { return }
        let step = config.oldSpace[s.oldSpacePc]
        var n = s
        let rule = config.deferredEntriesBelongToTheirNursery
        func next(_ n: inout State) {
            n.oldSpacePc += 1
            n.oldSpaceStep = 0
        }
        func isDeferred(_ o: Int) -> Bool {
            if case .deferred = s.objects[o].entry { return true }
            return false
        }
        switch step {
        case .snapshot, .fullCollection:
            if s.oldSpaceStep == 0 {
                n.stwWanted = true
                n.oldSpaceStep = 1
                emit("O requests a stop (stwWanted): no collection opens", n, nil)
                return
            }
            guard worldCanStop(s) else { return }
            let reach = reachable(s)
            for o in 0..<N where isDeferred(o) { n.objects[o].deferredAcrossPause = true }
            n.stwWanted = false
            next(&n)
            if step == .snapshot {
                var snap: [Int] = []
                for o in 0..<N {
                    let counts = s.objects[o].entry == .old || (!rule && isDeferred(o))
                    n.objects[o].inSnapshot = counts
                    n.objects[o].oldSpaceMarked = counts && reach[o]
                    if counts { snap.append(o) }
                }
                emit("O initial mark (world stopped): snapshot \(names(snap))\(rule ? " (deferred entries excluded)" : ""), marks the reachable ones", n, nil)
            } else {
                var freed: [Int] = []
                for o in 0..<N where !reach[o] && (s.objects[o].entry == .old || (!rule && isDeferred(o))) {
                    n.objects[o].entry = .free
                    freed.append(o)
                }
                emit("O full collection (world stopped): frees \(names(freed))\(rule ? " (deferred entries left to their nursery)" : "")", n, nil)
            }
        case .sweep:
            // One step per unmarked snapshot entry.
            let candidates = (0..<N).filter { s.objects[$0].inSnapshot && !s.objects[$0].oldSpaceMarked }
            guard s.oldSpaceStep < candidates.count else {
                next(&n)
                emit("O sweep done", n, nil)
                return
            }
            let o = candidates[s.oldSpaceStep]
            n.oldSpaceStep += 1
            var violation: Violation?
            if s.objects[o].reusedSinceSnapshot && s.objects[o].entry != .free {
                violation = Violation(claim: .oneOwnerPerEntry, message: "O sweeps snapshot entry \(name(o)), which its nursery freed and a worker reused for a live object")
            } else if s.objects[o].entry == .free {
                violation = Violation(claim: .oneOwnerPerEntry, message: "O sweeps snapshot entry \(name(o)), which its nursery already freed")
            }
            n.objects[o].entry = .free
            n.objects[o].inSnapshot = false
            emit("O sweep: frees unmarked snapshot entry \(name(o))", n, violation)
        }
    }
}

// MARK: - fingerprint

extension Model: ExplorableModel {
    /// Swift's Hasher (SipHash, 64 bits) over the synthesized `Hashable`.
    func fingerprint(_ s: State) -> UInt64 {
        var h = Hasher()
        s.hash(into: &h)
        return UInt64(bitPattern: Int64(h.finalize()))
    }
}
