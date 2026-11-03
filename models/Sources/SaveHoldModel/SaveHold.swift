// The save's hold on the scheduler (module 8c, docs/models/save-hold.md).
//
// A saver (on worker 0, running its own Process, inside the VM) holds the
// scheduler, waits until no other worker that runs Processes is inside the
// VM, stops the world, checks that no other Process runs, saves, releases
// the hold in the stop and broadcasts the idle workers' condition. The other
// workers run Processes made of instructions; at a poll a worker parks if a
// stop is requested, then, if it reads the hold set, puts its Process back
// at the end of the ready queue and runs nothing; a worker with nothing to
// run leaves the VM and waits untimed until a ready Process exists and the
// scheduler is not held (the wait is woken by a broadcast under the
// scheduler lock). Mutex-protected state is sequentially consistent here;
// the hold's mirror, which polls read without the lock, is a relaxed atomic
// that a reader may see late (a poll may read the old value once).
//
// Claims:
//  1. clean save: when the saver saves, no other Process is running on a
//     worker (each is ready or finished: its registers are in its object);
//  2. no deadlock and no lost wakeup: every run ends with the saver done and
//     every Process finished.

import ModelKit

public enum Claim: Int, Hashable, Sendable, CaseIterable, CustomStringConvertible {
    case cleanSave, everyoneFinishes
    public var description: String {
        switch self {
        case .cleanSave: "1 clean save"
        case .everyoneFinishes: "2 every Process finishes"
        }
    }
}

public struct Configuration: Sendable {
    /// Workers besides the saver's.
    public var workers: Int
    /// Processes besides the saver, each `instructions` long, all ready at
    /// the start.
    public var processes: Int
    public var instructions: Int
    /// The rules, each on by default and off in one negative test.
    /// A poll that reads the hold puts its Process back.
    public var leaveAtPoll = true
    /// The saver waits for the other workers to be outside before stopping.
    public var waitOutside = true
    /// The stop checks that no other Process runs (else it retries).
    public var checkInStop = true
    /// The release broadcasts the idle workers' condition.
    public var broadcastOnRelease = true
    /// Dequeue refuses while the scheduler is held.
    public var dequeueRespectsHold = true

    public init(workers: Int, processes: Int, instructions: Int) {
        self.workers = workers
        self.processes = processes
        self.instructions = instructions
    }

    public static let standard = Configuration(workers: 2, processes: 2, instructions: 2)
    public static let three = Configuration(workers: 3, processes: 3, instructions: 1)
}

/// A worker's place.
enum Place: UInt8, Hashable {
    /// Outside the VM, waiting untimed (`asleep`) or about to look again.
    case outside, asleep
    /// Inside, holding no Process.
    case idle
    /// Inside, running its Process between polls.
    case running
    /// Inside, at a poll, parked in a stop.
    case parked
}

struct Worker: Hashable {
    var place = Place.outside
    var process: Int8 = -1
    /// It parked in the current stop while running (its Process is
    /// mid-slice, registers at a poll).
    var parkedRunning = false
}

/// The saver's phase.
enum Saver: UInt8, Hashable {
    case start, held, waiting, waited, requested, saved, done
}

public struct State: Hashable {
    var workers: [Worker]
    /// Instructions left per Process; -1 finished.
    var left: [Int8]
    /// Process -> running on a worker.
    var running: [Bool]
    var ready: [Int8]
    var hold = false
    /// The mirror as each worker last read it (a relaxed atomic: a read
    /// may return the value before the latest write once).
    var mirrorSeen: [Bool]
    var mirror = false
    var requested = false
    var saver = Saver.start
}

struct Model: ExplorableModel {
    typealias Claim = SaveHoldModel.Claim
    let c: Configuration
    init(_ c: Configuration) { self.c = c }

    func initialState() -> State {
        State(workers: Array(repeating: Worker(), count: c.workers), left: Array(repeating: Int8(c.instructions), count: c.processes),
              running: Array(repeating: false, count: c.processes), ready: (0..<c.processes).map { Int8($0) },
              mirrorSeen: Array(repeating: false, count: c.workers))
    }

    func fingerprint(_ s: State) -> UInt64 { UInt64(bitPattern: Int64(s.hashValue)) }

    func successors(_ s: State, labels: Bool) -> [Transition<State, Claim>] {
        var out: [Transition<State, Claim>] = []
        func add(_ l: @autoclosure () -> String, _ n: State, _ v: Violation<Claim>? = nil) {
            out.append(Transition(label: labels ? l() : "", next: n, violation: v))
        }
        // Workers.
        for i in 0..<c.workers {
            let w = s.workers[i]
            switch w.place {
            case .asleep:
                break  // woken only by a broadcast
            case .outside:
                // Woken (or not yet asleep) with a Process ready; enterVM
                // waits while a stop is requested.
                if !s.requested && !s.ready.isEmpty {
                    var n = s
                    n.workers[i].place = .idle
                    add("W\(i) enters", n)
                }
            case .idle:
                if s.requested {
                    var n = s
                    n.workers[i].place = .parked
                    add("W\(i) parks idle", n)
                    continue
                }
                var n = s
                if !(c.dequeueRespectsHold && s.hold), let p = s.ready.first {
                    n.ready.removeFirst()
                    n.running[Int(p)] = true
                    n.workers[i].process = p
                    n.workers[i].place = .running
                    add("W\(i) dequeues P\(p)", n)
                } else {
                    // Nothing to run: leave, wait untimed while held or empty
                    // (checked under the lock: a release's broadcast wakes it).
                    n.workers[i].place = (s.hold || s.ready.isEmpty) && !allDone(s) ? .asleep : .outside
                    add("W\(i) leaves", n)
                }
            case .running:
                let p = Int(w.process)
                if s.requested {
                    // A poll parks (registers flushed).
                    var n = s
                    n.workers[i].place = .parked
                    n.workers[i].parkedRunning = true
                    add("W\(i) parks at a poll with P\(p)", n)
                    continue
                }
                // A poll after the stop part: read the hold's mirror (late
                // once at most), then put the Process back if it is held.
                for seen in Set([s.mirror, s.mirrorSeen[i]]) {
                    var n = s
                    n.mirrorSeen[i] = s.mirror
                    if seen && c.leaveAtPoll {
                        n.ready.append(Int8(p))
                        n.running[p] = false
                        n.workers[i].process = -1
                        n.workers[i].place = .idle
                        add("W\(i) poll sees the hold: P\(p) back to ready", n)
                    } else {
                        // An instruction.
                        n.left[p] -= 1
                        if n.left[p] <= 0 {
                            n.left[p] = -1
                            n.running[p] = false
                            n.workers[i].process = -1
                            n.workers[i].place = .idle
                            add("W\(i) P\(p) runs its last instruction", n)
                        } else {
                            add("W\(i) P\(p) runs an instruction (hold read \(seen))", n)
                        }
                    }
                }
            case .parked:
                if !s.requested {
                    var n = s
                    n.workers[i].place = w.parkedRunning ? .running : .idle
                    n.workers[i].parkedRunning = false
                    add("W\(i) leaves its park", n)
                }
            }
        }
        // The saver.
        switch s.saver {
        case .start:
            var n = s
            n.hold = true
            n.saver = .held
            add("S holds the scheduler (lock)", n)
        case .held:
            var n = s
            n.mirror = true
            n.saver = .waiting
            add("S sets the mirror and the flag", n)
        case .waiting:
            let othersInside = s.workers.contains { $0.place == .idle || $0.place == .running || $0.place == .parked }
            if !c.waitOutside || !othersInside {
                var n = s
                n.saver = .waited
                add("S's wait ends (no other worker inside), it unlocks", n)
            }
        case .waited:
            // stopWorld takes the safepoint mutex again: a worker may have
            // entered meanwhile.
            var n = s
            n.requested = true
            n.saver = .requested
            add("S requests the stop", n)
        case .requested:
            // The stop: every worker inside parked.
            let allParked = s.workers.allSatisfy { $0.place == .outside || $0.place == .asleep || $0.place == .parked }
            if allParked {
                let anyRunning = s.running.contains(true)
                if anyRunning && c.checkInStop {
                    var n = s
                    n.requested = false
                    n.saver = .waiting
                    add("S's stop finds a Process running: retry", n)
                } else {
                    var n = s
                    n.hold = false
                    n.mirror = false
                    n.requested = false
                    n.saver = .saved
                    let v = anyRunning ? Violation(claim: Claim.cleanSave, message: "the save ran while a Process was mid-slice") : nil
                    add("S saves, releases the hold, ends the stop", n, v)
                }
            }
        case .saved:
            var n = s
            if c.broadcastOnRelease {
                for i in 0..<c.workers where n.workers[i].place == .asleep { n.workers[i].place = .outside }
            }
            n.saver = .done
            add("S broadcasts the idle condition (lock)", n)
        case .done:
            break
        }
        return out
    }

    func allDone(_ s: State) -> Bool { s.left.allSatisfy { $0 == -1 } }

    func terminalViolation(_ s: State) -> Violation<Claim>? {
        if s.saver != .done { return Violation(claim: .everyoneFinishes, message: "the saver never finished (\(s.saver))") }
        if !allDone(s) { return Violation(claim: .everyoneFinishes, message: "a Process never finished: \(s.left), ready \(s.ready)") }
        return nil
    }
}

public typealias Report = ModelKit.Report<Claim>

public func explore(_ c: Configuration) -> Report { exploreModel(Model(c)) }
