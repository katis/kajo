// Randomized programs (docs/VERIFICATION.md layer 4): a seed gives a kasm
// program of a root Process and 2 to 6 task Processes that allocate, store,
// load, drop, nest objects, publish them through a global Array, yield,
// signal and wait, with a deterministic join (the root waits on every
// task's exit Semaphore and then sums what they published and answered),
// so the answer does not depend on the schedule. A Swift model of the same
// program computes the expected answer. Every seed runs on one worker, on
// eight, and under each stress flag; answers and heap verifiers must agree.

import Foundation
import Testing
@testable import KajoVM

/// xorshift64*: the generator's only source of choice.
struct SeededRandom {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
}

/// A generated program and the answer its model gives.
struct RandomProgram {
    let seed: UInt64
    let source: String
    let expected: Int64
    let tasks: Int
}

private enum ModelValue { case none, int(Int64), object(Int) }

/// Generate the program for `seed`. Every task Array has 8 slots.
func randomProgram(_ seed: UInt64) -> RandomProgram {
    var rng = SeededRandom(seed)
    let k = 2 + rng.below(5)
    var objects: [[ModelValue]] = []
    var published: [Int?] = Array(repeating: nil, count: k)
    var answers: [Int64] = Array(repeating: 0, count: k)
    var labels = 0
    func label() -> String { labels += 1; return "L\(labels)" }

    // Signals go to the next task's Semaphore in a task's first half,
    // waits on its own in the second: every signal is issued without
    // depending on a wait, so no schedule deadlocks.
    var signalsTo = Array(repeating: 0, count: k)
    var halves: [(first: [String], second: [String])] = []
    var currents: [Int?] = Array(repeating: nil, count: k)
    // Module 8: the block methods each task's closures run, appended to its
    // method.
    var blocks: [[String]] = Array(repeating: [], count: k)

    func sumTree(_ o: Int) -> Int64 {
        objects[o].reduce(Int64(0)) { s, v in
            switch v {
            case .none: s
            case .int(let x): s &+ x
            case .object(let p): s &+ sumTree(p)
            }
        }
    }

    func ops(_ i: Int, _ n: Int, signals: Bool, waits: Int, acc: inout Int64) -> [String] {
        var out: [String] = []
        var waitsLeft = waits
        var current = currents[i]
        for _ in 0..<n {
            if waitsLeft > 0 && rng.chance(25) {
                out += ["push_nil", "push_int 11", "send globalAt: 1", "push_int \(i + 1)", "send at: 1", "send wait 0", "pop"]
                waitsLeft -= 1
                continue
            }
            switch rng.below(14) {
            case 0, 1:  // allocate
                objects.append(Array(repeating: .none, count: 8))
                current = objects.count - 1
                out += ["push_lit @Array", "push_int 8", "send new: 1", "store_temp 2"]
            case 2, 3:  // store an integer
                guard let c = current else { continue }
                let j = rng.below(8), v = Int64(rng.below(201) - 100)
                objects[c][j] = .int(v)
                out += ["push_temp 2", "push_int \(j + 1)", "push_int \(v)", "send at:put: 2", "pop"]
            case 4:  // nest: a new Array holding the current one
                guard let c = current else { continue }
                let j = rng.below(8)
                objects.append(Array(repeating: .none, count: 8))
                let n = objects.count - 1
                objects[n][j] = .object(c)
                current = n
                out += ["push_lit @Array", "push_int 8", "send new: 1", "store_temp 3",
                        "push_temp 3", "push_int \(j + 1)", "push_temp 2", "send at:put: 2", "pop",
                        "push_temp 3", "store_temp 2", "push_nil", "store_temp 3"]
            case 5, 6:  // load (one or two levels)
                guard let c = current else { continue }
                let j = rng.below(8)
                switch objects[c][j] {
                case .int(let v):
                    acc &+= v
                    out += ["push_temp 1", "push_temp 2", "push_int \(j + 1)", "send at: 1", "add", "store_temp 1"]
                case .object(let o):
                    guard let k2 = (0..<8).first(where: { if case .int = objects[o][$0] { return true }; return false }),
                          case .int(let v) = objects[o][k2] else { continue }
                    acc &+= v
                    out += ["push_temp 1", "push_temp 2", "push_int \(j + 1)", "send at: 1", "push_int \(k2 + 1)",
                            "send at: 1", "add", "store_temp 1"]
                case .none: continue
                }
            case 7:  // drop
                current = nil
                out += ["push_nil", "store_temp 2"]
            case 8:
                out += ["push_nil", "send yield 0", "pop"]
            case 9:  // a loop of garbage: backward jumps poll
                let n = 1 + rng.below(30), top = label(), end = label()
                out += ["push_int 0", "store_temp 4", "\(top):", "push_temp 4", "push_int \(n)", "lt", "jump_if_false \(end)",
                        "push_lit @Array", "push_int 4", "send new: 1", "pop",
                        "push_temp 4", "push_int 1", "add", "store_temp 4", "jump \(top)", "\(end):"]
            case 10:  // publish through global 10
                guard let c = current else { continue }
                published[i] = c
                out += ["push_nil", "push_int 10", "send globalAt: 1", "push_int \(i + 1)", "push_temp 2", "send at:put: 2", "pop"]
            case 12:  // module 8: acc += [:x | x + v] value: w (a copied value)
                let v = Int64(rng.below(201) - 100), w = Int64(rng.below(201) - 100)
                acc &+= v &+ w
                let b = "b\(blocks[i].count)"
                blocks[i].append("block \(b) args=1 copied=1 temps=0\n  push_temp 0\n  push_temp 1\n  add\n  block_return")
                out += ["push_temp 1", "push_int \(v)", "push_closure \(b) 1", "push_int \(w)", "value1", "add", "store_temp 1"]
            case 11:  // module 10: a large Array (old at birth, a run of two blocks): an integer stored past
                      // the first block and read back, its size, and the current object stored in it and summed
                let n = 4096 + rng.below(4000), j = 4095 + rng.below(n - 4095), v = Int64(rng.below(201) - 100)
                acc &+= v &+ Int64(n)
                out += ["push_lit @Array", "push_lit \(n)", "send new: 1", "store_temp 3",
                        "push_temp 3", "push_lit \(j + 1)", "push_int \(v)", "send at:put: 2", "pop",
                        "push_temp 1", "push_temp 3", "push_lit \(j + 1)", "send at: 1", "add", "store_temp 1",
                        "push_temp 1", "push_temp 3", "size", "add", "store_temp 1"]
                if let c = current {
                    acc &+= sumTree(c)
                    out += ["push_temp 3", "push_lit \(n)", "push_temp 2", "send at:put: 2", "pop",
                            "push_temp 1", "push_nil", "push_temp 3", "push_lit \(n)", "send at: 1", "send sum: 1", "add",
                            "store_temp 1"]
                }
                out += ["push_nil", "store_temp 3"]
                // Large bytes: a ByteArray (past the header's count field in
                // the configurations whose heap can hold one, `longBytesSource`),
                // a byte stored past 2^24 - 8 and at its end, read back.
                let b = Int64(rng.below(256))
                acc &+= b
                out += ["push_temp 1", "push_nil", "push_lit \(b)", "send longBytes: 1", "add", "store_temp 1"]
            case 13:  // module 8: acc += nil nlr: v (a non-local return from a block two frames up)
                let v = Int64(rng.below(201) - 100)
                acc &+= v
                out += ["push_temp 1", "push_nil", "push_int \(v)", "send nlr: 1", "add", "store_temp 1"]
            default:
                guard signals else { continue }
                signalsTo[(i + 1) % k] += 1
                out += ["push_nil", "push_int 11", "send globalAt: 1", "push_int \((i + 1) % k + 1)", "send at: 1",
                        "send signal 0", "pop"]
            }
        }
        for _ in 0..<waitsLeft {
            out += ["push_nil", "push_int 11", "send globalAt: 1", "push_int \(i + 1)", "send at: 1", "send wait 0", "pop"]
        }
        currents[i] = current
        return out
    }

    for i in 0..<k {
        var acc: Int64 = 0
        let first = ops(i, 10 + rng.below(20), signals: true, waits: 0, acc: &acc)
        answers[i] = acc
        halves.append((first, []))
    }
    for i in 0..<k {
        var acc = answers[i]
        halves[i].second = ops(i, 5 + rng.below(20), signals: false, waits: signalsTo[i], acc: &acc)
        answers[i] = acc
    }

    let expected = answers.reduce(0, &+) &+ published.compactMap { $0 }.map(sumTree).reduce(0, &+)

    // t0 = arg, t1 = acc, t2 = current, t3 = scratch, t4 = loop counter
    var src = sumSource
    for i in 0..<k {
        src += "method UndefinedObject task\(i): temps=4\n  push_int 0\n  store_temp 1\n"
        // A scavenge between the halves (module 4): every program scavenges
        // while the other tasks run, whatever its nursery size.
        let scavenge = ["push_nil", "send scavenge 0", "pop"]
        src += (halves[i].first + scavenge + halves[i].second).map { $0.hasSuffix(":") ? $0 : "  \($0)" }.joined(separator: "\n")
        src += "\n  push_nil\n  push_int 12\n  send globalAt: 1\n  push_int \(i + 1)\n  push_temp 1\n  send at:put: 2\n  pop\n"
        src += "  push_temp 1\n  return_top\n"
        src += blocks[i].map { $0 + "\n" }.joined()
        src += "end\n"
    }
    // The root: shared Arrays (10 published, 11 Semaphores, 12 answers,
    // 13 exit Semaphores), fork every task, join, sum.
    var root = ["push_nil", "push_int 10", "push_lit @Array", "push_int \(k)", "send new: 1", "send globalAt:put: 2", "pop",
                "push_nil", "push_int 11", "push_lit @Array", "push_int \(k)", "send new: 1", "send globalAt:put: 2", "pop",
                "push_nil", "push_int 12", "push_lit @Array", "push_int \(k)", "send new: 1", "send globalAt:put: 2", "pop",
                "push_nil", "push_int 13", "push_lit @Array", "push_int \(k)", "send new: 1", "send globalAt:put: 2", "pop"]
    for i in 0..<k {
        root += ["push_nil", "push_int 11", "send globalAt: 1", "push_int \(i + 1)", "push_nil", "send newSemaphore 0",
                 "send at:put: 2", "pop",
                 "push_nil", "push_int 13", "send globalAt: 1", "push_int \(i + 1)", "push_nil", "send newSemaphore 0",
                 "send at:put: 2", "pop"]
    }
    for i in 0..<k {
        root += ["push_nil", "push_lit #task\(i):", "push_int \(i)", "push_nil", "push_false",
                 "push_nil", "push_int 13", "send globalAt: 1", "push_int \(i + 1)", "send at: 1",
                 "send fork:with:priority:main:exit: 5", "pop"]
    }
    for i in 0..<k {
        root += ["push_nil", "push_int 13", "send globalAt: 1", "push_int \(i + 1)", "send at: 1", "send wait 0", "pop"]
    }
    root += ["push_int 0", "store_temp 0"]
    for i in 0..<k {
        root += ["push_temp 0", "push_nil", "push_int 12", "send globalAt: 1", "push_int \(i + 1)", "send at: 1", "add",
                 "store_temp 0",
                 "push_temp 0", "push_nil", "push_nil", "push_int 10", "send globalAt: 1", "push_int \(i + 1)", "send at: 1",
                 "send sum: 1", "add", "store_temp 0"]
    }
    root += ["push_temp 0", "return_top"]
    src += "method UndefinedObject root temps=1\n" + root.map { "  \($0)" }.joined(separator: "\n") + "\nend\n"
    return RandomProgram(seed: seed, source: src, expected: expected, tasks: k)
}

/// `nil sum: x`: x itself for a SmallInteger, 0 for nil, the sum over the
/// 8 slots of an Array. Module 8: `nil nlr: v` answers v by a non-local
/// return from a block evaluated by `apply:`.
private let sumSource = """
method UndefinedObject nlr: temps=0
  push_nil
  push_temp 0
  push_closure ret 1
  send apply: 1
  pop
  push_int -99
  return_top
block ret args=0 copied=1 temps=0
  push_temp 0
  nonlocal_return
end
method UndefinedObject apply: temps=0
  push_temp 0
  value
  return_top
end
method UndefinedObject sum: temps=2
  push_temp 0
  push_nil
  identical
  jump_if_false notNil
  push_int 0
  return_top
notNil:
  push_temp 0
  send class 0
  push_lit @SmallInteger
  identical
  jump_if_false array
  push_temp 0
  return_top
array:
  push_int 0
  store_temp 2
  push_int 1
  store_temp 1
loop:
  push_temp 1
  push_int 8
  le
  jump_if_false done
  push_temp 2
  push_nil
  push_temp 0
  push_temp 1
  send at: 1
  send sum: 1
  add
  store_temp 2
  push_temp 1
  push_int 1
  add
  store_temp 1
  jump loop
done:
  push_temp 2
  return_top
end

"""

/// The configurations every seed runs under. Module 3's seven run with the
/// default nursery (4 MiB per worker, N = 2); module 4 adds the oracle
/// without a nursery, tiny nurseries (one worker, every verifier), tiny
/// nurseries that promote everything (eight workers), and a scavenge before
/// every young allocation (eight workers). Module 5 adds a marking cycle at
/// every scavenge (four workers, tiny nurseries, a marker thread, every
/// verifier) and the same with the barrier's flag never cleared, and
/// perturbation reaches the marker. Module 6 adds relocation of every live
/// snapshot block in every such cycle (four workers, tiny nurseries,
/// perturbation reaching the relocator between objects and inside copies).
/// Every answer is the model's, which is also the no-nursery oracle's.
enum RandomConfig: String, CaseIterable, CustomTestStringConvertible {
    case oneWorker, eightWorkers, collectEveryAllocation, tinyEntryChunks, stopEveryPoll, preemptEveryPoll, perturbed
    case noNursery, tinyNurseries, promoteAll, scavengeEveryAllocation
    case cycleEveryScavenge, markingAlwaysOn
    case relocateEveryLiveBlock
    /// Module 7: the stop-the-world scavenge (the oracle; every other
    /// configuration runs the default offload policy), every nursery
    /// collected locally, the offload policy with even tasks on the main
    /// worker (driven by the test thread's turns), and a round at every
    /// poll; tiny nurseries, perturbation, the young verifier after every
    /// collection.
    case stwScavenge, localCollection, offloadCollection, roundEveryPoll
    /// The promotion reserve's fallback (docs/modules/reserve-and-depth.md):
    /// a heap one block larger than the image, no promotion reserve, no
    /// concurrent marking (only full collections free old space), tiny
    /// nurseries; the stop-the-world scavenge keeps what finds no block,
    /// and local collection is refused its promotion room and stops the
    /// world for that scavenge.
    case exhaustedReserve, exhaustedReserveLocal
    /// Collectors review, finding 4: the young stress flag `barrierAlwaysOn`
    /// (every store takes the young deletion barrier's slow path) with a
    /// marking cycle at every scavenge, local young collections, tiny
    /// nurseries; the stop verifier checks the shared barrier word at every
    /// stop, and the slow path must still be taken.
    case youngBarrierAlwaysOn
    /// Interpreter speed: the programs made without the fusion peephole
    /// (every other configuration runs them fused), eight workers: the
    /// plain bytecodes keep their own runs against the same model.
    case plainBytecodes

    var testDescription: String { rawValue }

    var workers: Int {
        switch self {
        case .oneWorker, .tinyNurseries: 1
        case .cycleEveryScavenge, .markingAlwaysOn, .relocateEveryLiveBlock: 4
        case .localCollection, .offloadCollection, .roundEveryPoll: 4
        case .exhaustedReserve, .exhaustedReserveLocal, .youngBarrierAlwaysOn: 4
        default: 8
        }
    }

    /// Large bytes: the configurations whose random programs make byte
    /// objects past the header's count field (16 MiB + 1003 bytes) in their
    /// large-object step, with a heap of 128 MiB to hold a few at once: one
    /// and eight workers (the ordinary paths), a cycle at every scavenge
    /// (marking and the lazy sweep over them) and local young collection
    /// (module 7 beside them). The others keep the step's ByteArray at 4100
    /// bytes: their heaps (8 MiB, or the exhausted reserve's few blocks)
    /// cannot hold one, and the stress modes (a collection at every
    /// allocation, a stop at every poll) would spend their time zeroing.
    var longBytes: Bool { [.oneWorker, .eightWorkers, .cycleEveryScavenge, .localCollection].contains(self) }

    func runtime(_ p: RandomProgram, native: Bool = false) throws -> Runtime {
        let verify = [.oneWorker, .eightWorkers, .perturbed, .noNursery, .tinyNurseries, .promoteAll,
                      .cycleEveryScavenge, .markingAlwaysOn, .relocateEveryLiveBlock,
                      .stwScavenge, .localCollection, .offloadCollection, .roundEveryPoll,
                      .exhaustedReserve, .exhaustedReserveLocal, .youngBarrierAlwaysOn].contains(self)
        let source = (self == .offloadCollection ? mainTasks(p.source) : p.source) + longBytesSource(long: longBytes)
        var stress: StressFlags = []
        if self == .collectEveryAllocation { stress = .collectAtEveryAllocation }
        if self == .tinyEntryChunks { stress = .tinyEntryChunks }
        var switches = TestSwitches()
        switches.noFusion = self == .plainBytecodes
        let exhausted = self == .exhaustedReserve || self == .exhaustedReserveLocal
        return try Runtime(source, background: workers, heapBlocks: exhausted ? exhaustedHeapBlocks + 2 * p.tasks + 2 : longBytes ? 4096 : 256,
                           reserveBlocks: exhausted ? 0 : nil, stress: stress, verify: verify,
                           configure: { c in
                               // Programs allocate tens of KiB: 512 KiB
                               // nurseries keep the promotion reserve (and
                               // with it each full collection's block walk)
                               // small.
                               c.nursery.bytes = 512 << 10
                               switch self {
                               case .stopEveryPoll: c.stress = .stopEveryPoll
                               case .preemptEveryPoll: c.stress = .preemptEveryPoll
                               case .perturbed: c.perturb = Perturbation(seed: p.seed, probability: 0.02, maxSleepUs: 30)
                               case .noNursery: c.nursery.bytes = 0
                               case .tinyNurseries, .promoteAll, .cycleEveryScavenge, .markingAlwaysOn, .relocateEveryLiveBlock:
                                   // Smaller than `tinyNurseries`: these programs
                                   // allocate tens of KiB in all.
                                   c.nursery.bytes = 24 << 10
                                   c.nursery.survivorBytes = 2 << 10
                                   if self == .promoteAll { c.nursery.stress = .promoteAll }
                                   if self == .cycleEveryScavenge { c.marking.stress = .cycleAtEveryScavenge }
                                   if self == .relocateEveryLiveBlock {
                                       c.marking.stress = .cycleAtEveryScavenge
                                       c.relocation.stress = [.relocateEveryLiveBlock, .relocateAtEveryCycle]
                                       c.relocation.cap = 1
                                       c.perturb = Perturbation(seed: p.seed, probability: 0.02, maxSleepUs: 30)
                                   }
                                   if self == .markingAlwaysOn {
                                       c.marking.stress = [.cycleAtEveryScavenge, .markingAlwaysOn]
                                       c.perturb = Perturbation(seed: p.seed, probability: 0.02, maxSleepUs: 30)
                                   }
                               case .scavengeEveryAllocation: c.nursery.stress = .scavengeAtEveryAllocation
                               case .stwScavenge: c.young.mode = .stw
                               case .localCollection, .offloadCollection, .roundEveryPoll:
                                   c.nursery.bytes = 24 << 10
                                   c.nursery.survivorBytes = 2 << 10
                                   c.young.mode = self == .offloadCollection ? .offload : .local
                                   c.young.verify = true
                                   if self == .roundEveryPoll { c.young.stress = .roundAtEveryPoll }
                                   c.perturb = Perturbation(seed: p.seed, probability: 0.02, maxSleepUs: 30)
                               case .exhaustedReserve, .exhaustedReserveLocal:
                                   c.nursery.bytes = 24 << 10
                                   c.nursery.survivorBytes = 2 << 10
                                   c.nursery.testSwitches.promotionReserveBlocks = 0
                                   c.nursery.stress = .promoteAll
                                   c.marking.enabled = false
                                   c.young.mode = self == .exhaustedReserve ? .stw : .local
                                   c.young.verify = true
                               case .youngBarrierAlwaysOn:
                                   c.nursery.bytes = 24 << 10
                                   c.nursery.survivorBytes = 2 << 10
                                   c.young.mode = .local
                                   c.young.verify = true
                                   c.young.stress = .barrierAlwaysOn
                                   c.marking.stress = .cycleAtEveryScavenge
                                   c.perturb = Perturbation(seed: p.seed, probability: 0.02, maxSleepUs: 30)
                               default: break
                               }
                           }, switches: switches, after: { img in
                               // Module 8's image ends in a block with pinned
                               // classes and symbols, which no relocation moves:
                               // fill it (and part of the next, as garbage) so
                               // promotions land in blocks a cycle can evacuate.
                               guard self == .relocateEveryLiveBlock else { return }
                               for _ in 0..<80 {
                                   _ = img.om.allocate(img.context, classIndex: WellKnown.array, slots: 62,
                                                       fill: img.nilObject, extraRoots: [])
                               }
                           }, native: native)
    }
}

/// Large bytes: `nil longBytes: v` makes a ByteArray of L bytes (16 MiB +
/// 1003, past the header's count field, when `long`; 4100 otherwise),
/// stores v at its end and at byte M (2^24 - 8 + 2 when long, past the
/// count field's sentinel), and answers (b at: L) + (b at: M) - v + (b
/// basicSize - L): v.
func longBytesSource(long: Bool) -> String {
    let L = long ? Int(Header.longBytesFrom) + 1003 : 4100
    let M = long ? Int(Header.longBytesFrom) + 2 : 4000
    return """
    method Object lbSize temps=0 prim=95
      push_nil
      return_top
    end
    method UndefinedObject longBytes: temps=1
      push_lit @ByteArray
      push_lit \(L)
      send new: 1
      store_temp 1
      push_temp 1
      push_lit \(L)
      push_temp 0
      send at:put: 2
      pop
      push_temp 1
      push_lit \(M)
      push_temp 0
      send at:put: 2
      pop
      push_temp 1
      push_lit \(L)
      send at: 1
      push_temp 1
      push_lit \(M)
      send at: 1
      add
      push_temp 0
      sub
      push_temp 1
      send lbSize 0
      push_lit \(L)
      sub
      add
      return_top
    end

    """
}

/// The exhausted-reserve configurations' whole heap (the image takes one
/// block): every program's live data fits, its garbage does not.
/// Module 10: plus two per task and two more (`runtime`), since each task
/// may hold a large Array (a run of two blocks) at once in its large-object
/// step and a run needs two free blocks side by side (the gate's soak saw
/// one seed in 1000 find none with two per task only); their garbage still
/// does not fit.
let exhaustedHeapBlocks = Int(ProcessInfo.processInfo.environment["KAJO_EXHAUSTED_BLOCKS"] ?? "") ?? 3

/// Even tasks forked with main affinity (`offloadCollection`): the main
/// worker's nursery is the offloaded one.
func mainTasks(_ source: String) -> String {
    var lines = source.components(separatedBy: "\n")
    var i = 0
    while i + 4 < lines.count {
        let t = lines[i].trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("push_lit #task"), let n = Int(t.dropFirst("push_lit #task".count).dropLast()), n % 2 == 0,
           lines[i + 3].trimmingCharacters(in: .whitespaces) == "push_false" {
            lines[i + 3] = lines[i + 3].replacingOccurrences(of: "push_false", with: "push_true")
        }
        i += 1
    }
    return lines.joined(separator: "\n")
}

/// Scavenges seen by the current tiny-nursery configuration's seeds.
final class ScavengeTally: @unchecked Sendable {
    private let lock = NSLock()
    private var n: [String: UInt64] = [:]
    func add(_ c: RandomConfig, _ v: UInt64) { lock.lock(); n[c.rawValue, default: 0] += v; lock.unlock() }
    func take(_ c: RandomConfig) -> UInt64 { lock.lock(); defer { n[c.rawValue] = 0; lock.unlock() }; return n[c.rawValue] ?? 0 }
}
let randomScavenges = ScavengeTally()

/// Run one program under one configuration: its answer, or nil after
/// recording why not.
@discardableResult
func runRandom(_ p: RandomProgram, _ config: RandomConfig, native: Bool = false) throws -> Int64? {
    let rt = try config.runtime(p, native: native)
    let root = rt.spawn("root")
    if config == .offloadCollection {
        // The shell's part: main turns until everything has terminated.
        let end = now() + UInt64((underThreadSanitizer ? 600.0 : 120.0) * 1e9)
        while rt.vm.liveProcessCount > 0 && now() < end {
            if rt.vm.runMain(budgetNs: 2_000_000).slices == 0 { usleep(200) }
        }
    }
    guard rt.waitAllTerminated(underThreadSanitizer ? 600 : 120) else {
        Issue.record("seed \(p.seed) \(config): did not finish (stops \(rt.vm.counters.stops), scavenges \(rt.vm.nurseryCounters.scavenges), collections \(rt.image.om.counters.collections))")
        rt.vm.terminateAll()
        rt.waitAllTerminated()
        rt.stop()
        return nil
    }
    if ProcessInfo.processInfo.environment["KAJO_RANDOM_STOPS"] != nil {
        print("seed \(p.seed) \(config): stops \(rt.vm.counters.stops)")
    }
    let v = rt.vm.result(of: root)
    if let e = rt.vm.error(of: root) { Issue.record("seed \(p.seed) \(config): \(e)") }
    if native {
        // AOT 1: the native engine bound every method and ran them.
        let r = rt.vm.nativeReport
        #expect(r?.refused == nil && r?.bound == r?.methods && (r?.bound ?? 0) > 0, "seed \(p.seed) \(config): \(String(describing: r))")
        let n = rt.vm.nativeCounters
        #expect(n.entries > 0 && n.nativeSends > 0, "seed \(p.seed) \(config): \(n)")
        randomNative.add(config, n)
    }
    // Module 10: a verifier's report names its seed (an answer can be right
    // while a verifier saw a missed object).
    if rt.image.om.counters.verifierFailures > 0 {
        Issue.record("seed \(p.seed) \(config): \(rt.image.om.verifierReports.prefix(2))")
    }
    // the stress really happened
    let c = rt.vm.counters
    #expect(c.forks == UInt64(p.tasks + 1) && c.processErrors == 0)
    // The stop verifiers (every stop's parked count, the barrier word).
    #expect(c.stopVerifierFailures == 0, "seed \(p.seed) \(config)")
    switch config {
    case .stopEveryPoll: #expect(c.stops > 10)
    case .preemptEveryPoll: #expect(c.preemptions > 10)
    case .collectEveryAllocation: #expect(rt.image.om.counters.stressCollections > 10)
    case .noNursery: #expect(!rt.vm.hasNursery)
    case .tinyNurseries, .promoteAll:
        // Module 7: the `scavenge` primitive collects the caller's nursery
        // without stopping the world.
        let yc = rt.vm.youngCounters
        randomScavenges.add(config, rt.vm.nurseryCounters.scavenges + yc.collectionsLocal + yc.collectionsOffloaded)
    case .cycleEveryScavenge, .markingAlwaysOn:
        // Cycles started: under ThreadSanitizer with busy loops the
        // utility-QoS marker of ten small programs may finish none (module
        // 7's loaded sanitizer run); the verifier checks every final mark
        // that does run.
        randomScavenges.add(config, rt.vm.markingCounters.cycles)
        #expect(rt.vm.markingCounters.missed == 0)
    case .relocateEveryLiveBlock:
        // A selection needs a cycle's final mark, and ten small programs
        // under ThreadSanitizer can end before the utility-QoS marker
        // finishes the cycle their last scavenge started (708e994's gate
        // run): let every cycle started finish before the runtime stops,
        // so each seed's work reaches its selection. A bounded wait on
        // work done, not a time assertion. The counters are read in a stop,
        // so the poll is slow (a host polling every 0.5 ms starves the
        // marker it waits for).
        let started = rt.vm.markingCounters.cycles
        let end = now() + UInt64((underThreadSanitizer ? 600.0 : 120.0) * 1e9)
        while now() < end {
            let m = rt.vm.markingCounters
            if m.cyclesCompleted &+ m.aborts >= started { break }
            usleep(20_000)
        }
        let r = rt.vm.relocationCounters
        if ProcessInfo.processInfo.environment["KAJO_RELOC_DEBUG"] != nil {
            print("RELOC seed \(p.seed) cycles \(rt.vm.markingCounters.cycles) planned \(r.cyclesPlanned) selected \(r.blocksSelected) candidates \(r.candidates) moved \(r.objectsMoved) pinned \(r.skippedPinned) aborted \(r.passesAborted)")
        }
        // Blocks selected and evacuated (every live block of each cycle's
        // snapshot): module 8's image is larger and pinned, so in some runs
        // of 100 seeds every selected block held only pinned image objects
        // and nothing moved (KAJO_RELOC_DEBUG prints both).
        randomScavenges.add(config, r.blocksSelected)
        #expect(rt.vm.markingCounters.missed == 0 && r.parksWhileRelocating == 0 && r.verifierFailures == 0)
    case .scavengeEveryAllocation: #expect(rt.vm.nurseryCounters.scavenges > 10)
    case .stwScavenge: #expect(!rt.vm.hasYoungCollection)
    case .exhaustedReserve, .exhaustedReserveLocal:
        randomScavenges.add(config, rt.vm.nurseryCounters.exhaustedScavenges)
    case .youngBarrierAlwaysOn:
        // Every store took the young slow path, cycles or not.
        let calls = (0..<(config.workers + 2)).reduce(UInt64(0)) { $0 &+ rt.vm.youngWorkerCounters($1).deletionBarrierCalls }
        #expect(calls > 0, "seed \(p.seed)")
        randomScavenges.add(config, rt.vm.markingCounters.cycles)
        #expect(rt.vm.markingCounters.missed == 0)
    case .localCollection, .offloadCollection, .roundEveryPoll:
        let yc = rt.vm.youngCounters
        randomScavenges.add(config, yc.collectionsLocal + yc.collectionsOffloaded)
        if ProcessInfo.processInfo.environment["KAJO_RANDOM_DEBUG"] != nil {
            print("seed \(p.seed) \(config): \(yc) scavenges \(rt.vm.nurseryCounters.scavenges) young \(rt.vm.nurseryCounters.youngAllocations)")
        }
        if config == .offloadCollection { #expect(yc.offloadedInline == 0) }
    default: break
    }
    rt.stop()
    return v.isSmallInteger ? v.smallIntegerValue : nil
}

/// A hundred seeds; under ThreadSanitizer, which makes everything 10 to 50
/// times slower and a stop at every poll on eight workers minutes per
/// seed, ten (two with stopEveryPoll).
func randomSeedCount(_ config: RandomConfig) -> Int {
    if let n = Int(ProcessInfo.processInfo.environment["KAJO_SEEDS"] ?? "") { return n }
    return underThreadSanitizer ? (config == .stopEveryPoll || config == .scavengeEveryAllocation ? 2 : 10) : 100
}
let randomSeedBase = UInt64(ProcessInfo.processInfo.environment["KAJO_SEED_BASE"] ?? "") ?? 1

/// A hundred seeds (KAJO_SEEDS overrides; `just soak` runs a thousand)
/// under every configuration: each answer is the model's.
@Test(arguments: RandomConfig.allCases)
func randomProgramsAgreeWithTheirModel(_ config: RandomConfig) throws {
    // KAJO_RANDOM_ONLY=<configuration> runs one configuration (debugging).
    if let only = ProcessInfo.processInfo.environment["KAJO_RANDOM_ONLY"], only != config.rawValue { return }
    var failed: [UInt64] = []
    for s in 0..<UInt64(randomSeedCount(config)) {
        let p = randomProgram(randomSeedBase &+ s)
        if ProcessInfo.processInfo.environment["KAJO_RANDOM_TRACE"] != nil { print("seed \(p.seed) \(config) starts"); fflush(stdout) }
        let v = try runRandom(p, config)
        if v != p.expected {
            failed.append(p.seed)
            Issue.record("seed \(p.seed) \(config): answered \(String(describing: v)), the model \(p.expected)")
            if failed.count > 3 { break }
        }
    }
    print("random programs \(config): \(randomSeedCount(config)) seeds from \(randomSeedBase), failing \(failed)")
    if [.tinyNurseries, .promoteAll, .cycleEveryScavenge, .markingAlwaysOn, .relocateEveryLiveBlock,
        .localCollection, .offloadCollection, .roundEveryPoll, .exhaustedReserve, .exhaustedReserveLocal,
        .youngBarrierAlwaysOn].contains(config) {
        // Small programs: not every seed scavenges (or completes a marking
        // cycle, or moves an object), the configuration must.
        #expect(randomScavenges.take(config) > 0)
    }
    #expect(failed.isEmpty, "failing seeds: \(failed)")
}

/// AOT 1: the native engine's counters summed over a configuration's seeds.
final class NativeTally: @unchecked Sendable {
    private let lock = NSLock()
    private var c: [String: NativeCounters] = [:]
    func add(_ k: RandomConfig, _ x: NativeCounters) { lock.lock(); c[k.rawValue, default: NativeCounters()].add(x); lock.unlock() }
    func take(_ k: RandomConfig) -> NativeCounters { lock.lock(); defer { c[k.rawValue] = nil; lock.unlock() }; return c[k.rawValue] ?? NativeCounters() }
}
let randomNative = NativeTally()

/// AOT 1 (docs/modules/aot.md, Tests): the same programs under the native
/// engine in every configuration, each image's methods generated, compiled
/// and bound: every answer is the model's, and the engine ran (sends made
/// natively, and in the configurations that preempt, stop or step, the
/// engine switches).
@Test(arguments: RandomConfig.allCases)
func randomProgramsAgreeWithTheirModelNatively(_ config: RandomConfig) throws {
    if let only = ProcessInfo.processInfo.environment["KAJO_RANDOM_ONLY"], only != config.rawValue { return }
    var failed: [UInt64] = []
    let n = Int(ProcessInfo.processInfo.environment["KAJO_NATIVE_SEEDS"] ?? "") ?? randomSeedCount(config)
    _ = randomNative.take(config)
    for s in 0..<UInt64(n) {
        let p = randomProgram(randomSeedBase &+ s)
        let v = try runRandom(p, config, native: true)
        if v != p.expected {
            failed.append(p.seed)
            Issue.record("seed \(p.seed) \(config) native: answered \(String(describing: v)), the model \(p.expected)")
            if failed.count > 3 { break }
        }
    }
    let c = randomNative.take(config)
    print("random programs \(config) native: \(n) seeds from \(randomSeedBase), failing \(failed), \(c.named.map { "\($0.name)=\($0.value)" }.joined(separator: " "))")
    #expect(c.nativeSends > 0 && c.nativeReturns > 0)
    #expect(failed.isEmpty, "failing seeds: \(failed)")
}

/// The generator is deterministic.
@Test func randomProgramsAreDeterministic() {
    #expect(randomProgram(42).source == randomProgram(42).source)
    #expect(randomProgram(42).source != randomProgram(43).source)
}

// MARK: - module 8c: snapshot mode

/// The random programs saved mid-run: the n-th slow poll (VM wide) saves
/// the image with every Process in it (`VMConfig.snapshotAtPoll`), the run
/// goes on to its end, and the saved image is loaded into a fresh VM (with
/// a different worker count) and resumed to its end. Both answers must be
/// the model's: the main oracle of module 8c. With the stress flags the
/// saving and the resumed VM stop the world at every poll, collect at
/// every allocation, or preempt at every poll.
enum SnapshotMode: String, CaseIterable, CustomTestStringConvertible {
    case eightWorkers, oneWorker, stopEveryPoll, collectEveryAllocation, preemptEveryPoll, perturbed
    var testDescription: String { rawValue }

    var workers: (save: Int, resume: Int) {
        switch self {
        case .oneWorker: (1, 3)
        case .eightWorkers, .perturbed: (8, 2)
        default: (4, 1)
        }
    }

    func configure(_ c: inout VMConfig, _ seed: UInt64) {
        c.nursery.bytes = 512 << 10
        switch self {
        case .stopEveryPoll: c.stress = .stopEveryPoll
        case .preemptEveryPoll: c.stress = .preemptEveryPoll
        case .perturbed: c.perturb = Perturbation(seed: seed, probability: 0.02, maxSleepUs: 30)
        default: break
        }
    }

    var stress: StressFlags { self == .collectEveryAllocation ? .collectAtEveryAllocation : [] }
    /// Every verifier at every collection, except where every poll or
    /// allocation collects (as `RandomConfig` does).
    var verify: Bool { self != .stopEveryPoll && self != .collectEveryAllocation }
}

/// The slow poll a seed saves at: early enough that most programs are
/// still running (a program polls slowly every 64 polls, at every poll
/// under the stress flags).
func snapshotPoll(_ p: RandomProgram, _ mode: SnapshotMode) -> Int {
    let range = [.stopEveryPoll, .preemptEveryPoll].contains(mode) ? 400 : [.oneWorker, .collectEveryAllocation].contains(mode) ? 6 : 12
    return 1 + Int(p.seed &* 0x9E37_79B9 % UInt64(range))
}

/// One program in snapshot mode: the saving run's answer, the resumed
/// run's (nil when the poll came after the program's end, so nothing was
/// saved).
func runRandomSnapshot(_ p: RandomProgram, _ mode: SnapshotMode, saveNative: Bool = false,
                       resumeNative: Bool = false) throws -> (saved: Int64?, resumed: Int64?, didSave: Bool) {
    let n = snapshotPoll(p, mode)
    let rt = try Runtime(p.source + longBytesSource(long: false) + snapshotSrc, background: mode.workers.save, heapBlocks: 256, stress: mode.stress,
                         verify: mode.verify, configure: { c in
                             mode.configure(&c, p.seed)
                             c.snapshotAtPoll = n
                         }, native: saveNative)
    let root = rt.spawn("root")
    guard rt.waitAllTerminated(underThreadSanitizer ? 600 : 120) else {
        Issue.record("seed \(p.seed) \(mode): the saving run did not finish")
        rt.vm.terminateAll()
        rt.waitAllTerminated()
        rt.stop()
        return (nil, nil, false)
    }
    let a = rt.vm.result(of: root)
    if let e = rt.vm.error(of: root) { Issue.record("seed \(p.seed) \(mode): \(e)") }
    let rootId = processId(rt, root)
    let images = rt.vm.takeSavedImages()
    rt.stop()
    let saved = a.isSmallInteger ? a.smallIntegerValue : nil
    guard let bytes = images.first else { return (saved, nil, false) }
    let r = try Resumed(bytes, background: mode.workers.resume, heapBlocks: 256, stress: mode.stress,
                        verify: mode.verify, configure: { c in mode.configure(&c, p.seed &+ 1) }, native: resumeNative)
    guard r.waitAllTerminated(underThreadSanitizer ? 600 : 120) else {
        Issue.record("seed \(p.seed) \(mode): the resumed run did not finish")
        r.vm.terminateAll()
        r.waitAllTerminated()
        r.stop()
        return (saved, nil, true)
    }
    var resumed: Int64? = nil
    if let q = r.process(id: rootId) {
        if let e = r.vm.error(of: q) { Issue.record("seed \(p.seed) \(mode) resumed: \(e)") }
        resumed = r.result(q)
    } else {
        Issue.record("seed \(p.seed) \(mode): the root was not saved")
    }
    r.stop()
    return (saved, resumed, true)
}

/// A hundred seeds per mode (KAJO_SEEDS overrides; `just soak` runs a
/// thousand): both runs answer the model's, and most seeds really saved.
@Test(arguments: SnapshotMode.allCases)
func randomProgramsResumeFromASnapshot(_ mode: SnapshotMode) throws {
    let count = Int(ProcessInfo.processInfo.environment["KAJO_SEEDS"] ?? "")
        ?? (underThreadSanitizer ? ([.stopEveryPoll, .collectEveryAllocation].contains(mode) ? 2 : 10) : 100)
    var failed: [UInt64] = []
    var saves = 0
    let t0 = now()
    for s in 0..<UInt64(count) {
        let p = randomProgram(randomSeedBase &+ s)
        let (a, b, didSave) = try runRandomSnapshot(p, mode)
        if didSave { saves += 1 }
        if a != p.expected || (didSave && b != p.expected) {
            failed.append(p.seed)
            Issue.record("seed \(p.seed) \(mode): saved run \(String(describing: a)), resumed \(String(describing: b)), the model \(p.expected)")
            if failed.count > 3 { break }
        }
    }
    print("random programs resumed \(mode): \(count) seeds from \(randomSeedBase), \(saves) saved, failing \(failed), \(Double(now() - t0) / 1e9) s")
    #expect(saves * 2 > count, "only \(saves) of \(count) seeds saved")
    #expect(failed.isEmpty, "failing seeds: \(failed)")
}

/// AOT 1: saved mid-run under one engine and resumed under the other, both
/// ways (the saved stacks carry no native marker; the loader's rules hold).
@Test(arguments: SnapshotMode.allCases, [true, false])
func randomProgramsResumeAcrossEngines(_ mode: SnapshotMode, _ savedNatively: Bool) throws {
    let count = Int(ProcessInfo.processInfo.environment["KAJO_NATIVE_SEEDS"] ?? "")
        ?? (underThreadSanitizer ? ([.stopEveryPoll, .collectEveryAllocation].contains(mode) ? 2 : 6) : 40)
    var failed: [UInt64] = []
    var saves = 0
    for s in 0..<UInt64(count) {
        let p = randomProgram(randomSeedBase &+ s)
        let (a, b, didSave) = try runRandomSnapshot(p, mode, saveNative: savedNatively, resumeNative: !savedNatively)
        if didSave { saves += 1 }
        if a != p.expected || (didSave && b != p.expected) {
            failed.append(p.seed)
            Issue.record("seed \(p.seed) \(mode) saved \(savedNatively ? "natively" : "interpreted"): saved run \(String(describing: a)), resumed \(String(describing: b)), the model \(p.expected)")
            if failed.count > 3 { break }
        }
    }
    print("random programs resumed across engines \(mode) saved \(savedNatively ? "natively" : "interpreted"): \(count) seeds, \(saves) saved, failing \(failed)")
    #expect(saves * 2 > count, "only \(saves) of \(count) seeds saved")
    #expect(failed.isEmpty, "failing seeds: \(failed)")
}
