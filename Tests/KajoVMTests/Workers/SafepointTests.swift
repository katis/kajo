// The safepoint protocol and the worker threads: back-to-back stops
// (experiments/generational-gc's regression test), world-stopped
// operations while other workers run (module 2's waiting list), the
// kernels on eight workers, idle cost, QoS.

import Darwin
import Testing
@testable import KajoVM

/// A stop requested right after another must wait for every worker again.
/// The generational-gc experiment decremented `parked` only when a
/// released worker woke up, so the second stop could start while workers
/// still ran. The stop verifier counts any worker that leaves a park while
/// a stop's work runs; the broken protocol is a test switch.
@Test(arguments: [false, true])
func backToBackStopsDoNotLetReleasedWorkersRun(_ broken: Bool) throws {
    // The broken protocol lets a released worker run inside the next stop,
    // which is a data race by construction: ThreadSanitizer reports it
    // (the schedule verifier reading `current` while the worker writes it)
    // and fails the gate. The stop verifier shows the bug in every other
    // build; under the sanitizer only the rule-on case runs.
    if broken && underThreadSanitizer { return }
    let rt = try Runtime(churnSrc, background: 7, heapBlocks: 512, configure: {
        $0.testSwitches.countReleasedAsParked = broken
    })
    for _ in 0..<7 { rt.spawn("churn:", [int(checkedBuild ? 40_000 : 150_000)]) }
    var stops = 0
    while rt.vm.liveProcessCount > 0 && stops < 400 {
        if broken {
            // stops that change nothing, so the broken protocol cannot
            // corrupt the heap while the verifier looks for it
            rt.vm.withWorldStopped { usleep(50) }
            rt.vm.withWorldStopped { usleep(50) }
            if rt.vm.counters.stopVerifierFailures > 0 { break }
        } else {
            rt.vm.withWorldStopped { usleep(50) }
            if stops % 8 == 0 { rt.vm.collect() } else { rt.vm.withWorldStopped { usleep(50) } }
        }
        stops += 2
    }
    if broken {
        #expect(rt.vm.counters.stopVerifierFailures > 0)
        rt.vm.terminateAll()
    } else {
        #expect(stops >= 20)
        #expect(rt.vm.counters.stopVerifierFailures == 0)
    }
    rt.waitAllTerminated()
    rt.stop(verifyHeap: !broken)
}

/// Become, compaction and reshape run in stops while seven workers
/// allocate and compute; every worker's checksum is the model's.
@Test func operationsWhileOtherWorkersRun() throws {
    let src = """
    class Pair Object 2
    method Pair x:y: temps=0
      push_temp 0
      store_ivar 0
      push_temp 1
      store_ivar 1
      return_self
    end
    method Pair x temps=0
      push_ivar 0
      return_top
    end
    method Pair y temps=0
      push_ivar 1
      return_top
    end
    ; t0 = n, t1 = i, t2 = acc, t3 = keep (an Array of 64 Pairs)
    method UndefinedObject pairs: temps=3
      push_int 0
      store_temp 1
      push_int 0
      store_temp 2
      push_lit @Array
      push_int 64
      send new: 1
      store_temp 3
    loop:
      push_temp 1
      push_temp 0
      lt
      jump_if_false done
      push_temp 3
      push_temp 1
      push_int 64
      send \\\\ 1
      push_int 1
      add
      push_lit @Pair
      send basicNew 0
      push_temp 1
      push_int 2
      send x:y: 2
      send at:put: 2
      pop
      push_temp 2
      push_temp 3
      push_temp 1
      push_int 64
      send \\\\ 1
      push_int 1
      add
      send at: 1
      send x 0
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
    // Verifiers once at the end (rt.stop); 30 operations a millisecond
    // apart, so the workers run between them even under ThreadSanitizer.
    let rt = try Runtime(src, background: 7, heapBlocks: 512, verify: false)
    let n: Int64 = checkedBuild ? 20_000 : 200_000
    var ps: [Oop] = []
    for _ in 0..<7 { ps.append(rt.spawn("pairs:", [int(n)])) }
    let a = rt.vm.newArray(3), b = rt.vm.newArray(5)
    let pair = rt.image.classIndex(named: "Pair")!
    var ops = 0
    while rt.vm.liveProcessCount > 0 && ops < 30 {
        switch ops % 3 {
        case 0: #expect(rt.vm.become(a, b))
        case 1: rt.vm.compact()
        default:
            if ops == 2 {  // once: Pair gains a third instance variable
                // Reshape allocates every new body and does not collect: a
                // collection first, in the same stop, gives it room.
                rt.vm.withWorldStopped(roots: true) { om, roots in
                    om.collect(extraRoots: roots)
                    #expect(throws: Never.self) {
                        try om.reshape(classIndex: pair, namedSlots: 2, layout: [0, 1, nil], fill: rt.image.nilObject)
                    }
                    om.store(om.classOop(pair), ClassLayout.instSize, int(3))
                }
            } else {
                rt.vm.collect()
            }
        }
        ops += 1
        usleep(1000)
    }
    rt.waitAllTerminated()
    #expect(ops >= 3)
    for p in ps { #expect(rt.result(p) == (n - 1) * n / 2) }
    #expect(rt.vm.inspect { om in om.allInstances(of: pair).allSatisfy { om.count(of: $0) == 3 } })
    rt.stop()
}

/// The six kernels, scaled down, as eight Processes on eight workers: the
/// sum of their answers is the sum of the models' (and the models
/// reproduce the single-worker checksums).
@Test(arguments: goldenKernels.map(\.name))
func kernelsOnEightWorkersMatchTheirModels(_ name: String) throws {
    let n = scaledWorkers[name]!
    // Verifiers once at the end (rt.stop): at every collection they made
    // the allocating kernels take minutes in a debug build. Eight depth-16
    // trees at once need about a million live entries.
    let rt = try Runtime(kernel(name), background: 8, heapBlocks: 2048, entries: 1 << 22, verify: false)
    var ps: [Oop] = []
    for w in 0..<8 { ps.append(rt.spawn("run:of:", [int(Int64(w)), int(n)])) }
    rt.waitAllTerminated(300)
    let sum = ps.reduce(Int64(0)) { $0 &+ rt.result($1) }
    let model = (0..<8).reduce(Int64(0)) { $0 &+ KernelModel.checksum(name, w: Int64($1), n: n) }
    #expect(sum == model)
    rt.stop()
}

/// Eight idle workers and no Processes: under 1 ms of CPU per worker over
/// a second, and a handful of wakeups at most (experiments/power: a timed
/// wait was the VM's whole idle cost).
@Test func idleWorkersCostNothing() throws {
    let spinSrc = """
    method UndefinedObject spinUntil: temps=0
    loop:
      push_nil
      push_int 9
      send globalAt: 1
      push_nil
      identical
      jump_if_true loop
      push_int 1
      return_top
    end
    """
    let rt = try Runtime(spinSrc, background: 8)
    #expect(eventually { rt.vm.idleWorkerCount == 8 })
    usleep(100_000)
    let cpu0 = rt.vm.workerCPUNanoseconds(), wakes0 = rt.vm.counters.idleWakeups
    usleep(1_000_000)
    let cpu = zip(rt.vm.workerCPUNanoseconds(), cpu0).map { $0 &- $1 }
    let wakes = rt.vm.counters.idleWakeups &- wakes0
    print("idle: cpu ns per worker \(cpu) wakeups \(wakes)")
    for c in cpu.dropFirst() { #expect(c < 1_000_000) }  // worker 0 is the main worker: no thread of its own
    #expect(wakes <= 5)
    // The probe reads real CPU time (microsecond grained: a worker can
    // reach its wait in less): a Process that spins 50 ms shows up in it.
    let before = rt.vm.workerCPUNanoseconds().reduce(0, +)
    let p = rt.spawn("spinUntil:", [int(0)])
    usleep(50_000)
    rt.vm.setGlobal(9, int(1))
    #expect(eventually { rt.state(p) == .terminated })
    let spun = rt.vm.workerCPUNanoseconds().reduce(0, +) &- before
    #expect(spun > 30_000_000, "\(spun) ns")
    rt.stop()
}

/// The other side of an untimed wait: work that arrives after idling
/// completes within a bound, by fork from the host and by an external
/// signal.
@Test func workAfterIdlingCompletesPromptly() throws {
    let src = """
    method UndefinedObject waiter temps=0
      push_nil
      push_int 1
      send globalAt: 1
      send wait 0
      pop
      push_int 5
      return_top
    end
    """
    let rt = try Runtime(src, background: 4)
    let sem = rt.vm.newSemaphore()
    rt.vm.setGlobal(1, sem)
    for _ in 0..<3 {
        #expect(eventually { rt.vm.idleWorkerCount == 4 })
        usleep(200_000)
        let t0 = now()
        let p = rt.spawn("waiter")
        #expect(eventually(5) { rt.state(p) == .waiting })
        usleep(100_000)
        let ref = rt.vm.ref
        let t1 = now()
        TestThread { ref.signalFromOutside(sem, handle: nil) }.join()
        #expect(eventually(5) { rt.state(p) == .terminated })
        let forkMs = Double(t1 - t0) / 1e6, signalMs = Double(now() - t1) / 1e6
        print("after idling: fork to waiting \(forkMs) ms (incl. 100 ms sleep), signal to done \(signalMs) ms")
        #expect(signalMs < 1000)
        #expect(rt.result(p) == 5)
    }
    rt.stop()
}

/// Background workers ask for user-initiated QoS and record what they got
/// (AGENTS.md: default attributes give `default`).
@Test func backgroundWorkersRunAtUserInitiatedQoS() throws {
    let rt = try Runtime("", background: 3)
    #expect(eventually { rt.vm.idleWorkerCount == 3 })
    for i in 1...3 { #expect(rt.vm.workerQoS(i) == QOS_CLASS_USER_INITIATED) }
    rt.stop()
}
