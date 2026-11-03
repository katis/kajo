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
            switch rng.below(12) {
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

    func sumTree(_ o: Int) -> Int64 {
        objects[o].reduce(Int64(0)) { s, v in
            switch v {
            case .none: s
            case .int(let x): s &+ x
            case .object(let p): s &+ sumTree(p)
            }
        }
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
        src += "  push_temp 1\n  return_top\nend\n"
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
/// 8 slots of an Array.
private let sumSource = """
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

    var testDescription: String { rawValue }

    var workers: Int {
        switch self {
        case .oneWorker, .tinyNurseries: 1
        case .cycleEveryScavenge, .markingAlwaysOn, .relocateEveryLiveBlock: 4
        default: 8
        }
    }

    func runtime(_ p: RandomProgram) throws -> Runtime {
        let verify = [.oneWorker, .eightWorkers, .perturbed, .noNursery, .tinyNurseries, .promoteAll,
                      .cycleEveryScavenge, .markingAlwaysOn, .relocateEveryLiveBlock].contains(self)
        var stress: StressFlags = []
        if self == .collectEveryAllocation { stress = .collectAtEveryAllocation }
        if self == .tinyEntryChunks { stress = .tinyEntryChunks }
        return try Runtime(p.source, background: workers, heapBlocks: 256, stress: stress, verify: verify,
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
                               default: break
                               }
                           })
    }
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
func runRandom(_ p: RandomProgram, _ config: RandomConfig) throws -> Int64? {
    let rt = try config.runtime(p)
    let root = rt.spawn("root")
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
    // the stress really happened
    let c = rt.vm.counters
    #expect(c.forks == UInt64(p.tasks + 1) && c.processErrors == 0)
    switch config {
    case .stopEveryPoll: #expect(c.stops > 10)
    case .preemptEveryPoll: #expect(c.preemptions > 10)
    case .collectEveryAllocation: #expect(rt.image.om.counters.stressCollections > 10)
    case .noNursery: #expect(!rt.vm.hasNursery)
    case .tinyNurseries, .promoteAll: randomScavenges.add(config, rt.vm.nurseryCounters.scavenges)
    case .cycleEveryScavenge, .markingAlwaysOn:
        randomScavenges.add(config, rt.vm.markingCounters.cyclesCompleted)
        #expect(rt.vm.markingCounters.missed == 0)
    case .relocateEveryLiveBlock:
        let r = rt.vm.relocationCounters
        randomScavenges.add(config, r.objectsMoved)
        #expect(rt.vm.markingCounters.missed == 0 && r.parksWhileRelocating == 0 && r.verifierFailures == 0)
    case .scavengeEveryAllocation: #expect(rt.vm.nurseryCounters.scavenges > 10)
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
    var failed: [UInt64] = []
    for s in 0..<UInt64(randomSeedCount(config)) {
        let p = randomProgram(randomSeedBase &+ s)
        let v = try runRandom(p, config)
        if v != p.expected {
            failed.append(p.seed)
            Issue.record("seed \(p.seed) \(config): answered \(String(describing: v)), the model \(p.expected)")
            if failed.count > 3 { break }
        }
    }
    print("random programs \(config): \(randomSeedCount(config)) seeds from \(randomSeedBase), failing \(failed)")
    if [.tinyNurseries, .promoteAll, .cycleEveryScavenge, .markingAlwaysOn, .relocateEveryLiveBlock].contains(config) {
        // Small programs: not every seed scavenges (or completes a marking
        // cycle, or moves an object), the configuration must.
        #expect(randomScavenges.take(config) > 0)
    }
    #expect(failed.isEmpty, "failing seeds: \(failed)")
}

/// The generator is deterministic.
@Test func randomProgramsAreDeterministic() {
    #expect(randomProgram(42).source == randomProgram(42).source)
    #expect(randomProgram(42).source != randomProgram(43).source)
}
