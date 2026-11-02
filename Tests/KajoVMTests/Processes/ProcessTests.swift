// Ported from experiments/ui-thread-scheduling/swift/Tests/VMPTests/ProcessTests.swift
// (and its copy in concurrent-young), against module 3's VM. Run also under
// ThreadSanitizer and under CPU load.

import Darwin
import Testing
@testable import KajoVM

@Test func forkRunsToCompletion() throws {
    let rt = try Runtime("method UndefinedObject twice: temps=0\n push_temp 0\n push_temp 0\n add\n return_top\nend\n", background: 2)
    let p = rt.spawn("twice:", [int(21)])
    rt.waitAllTerminated()
    #expect(rt.result(p) == 42)
    #expect(rt.state(p) == .terminated)
    #expect(rt.vm.counters.forks == 1 && rt.vm.counters.terminations == 1)
    rt.stop()
}

@Test func smalltalkForkAndExitSemaphore() throws {
    // parent forks a child that computes 7*6 into global 5, waits on the child's exit Semaphore
    let src = """
    method UndefinedObject child: temps=0
      push_nil
      push_int 5
      push_temp 0
      push_int 6
      mul
      send globalAt:put: 2
      return_top
    end
    method UndefinedObject parent temps=1
      push_nil
      send newSemaphore 0
      store_temp 0
      push_nil
      push_lit #child:
      push_int 7
      push_nil
      push_false
      push_temp 0
      send fork:with:priority:main:exit: 5
      pop
      push_temp 0
      send wait 0
      pop
      push_nil
      push_int 5
      send globalAt: 1
      push_int 1
      add
      return_top
    end
    """
    let rt = try Runtime(src, background: 3)
    let p = rt.spawn("parent")
    rt.waitAllTerminated()
    #expect(rt.result(p) == 43)
    #expect(rt.vm.counters.forks == 2)
    rt.stop()
}

@Test func yieldInterleavesOnOneWorker() throws {
    let src = logSrc + """
    ; t0 = tag, t1 = i
    method UndefinedObject yielder: temps=1
      push_int 0
      store_temp 1
    loop:
      push_temp 1
      push_int 3
      lt
      jump_if_false done
      push_nil
      push_temp 0
      send log: 1
      pop
      push_nil
      send yield 0
      pop
      push_temp 1
      push_int 1
      add
      store_temp 1
      jump loop
    done:
      push_temp 0
      return_top
    end
    method UndefinedObject setup temps=0
      push_nil
      push_int 10
      send makeLog: 1
      return_top
    end
    """
    let rt = try Runtime(src, background: 1, start: false)
    rt.spawn("setup")
    rt.spawn("yielder:", [int(1)])
    rt.spawn("yielder:", [int(2)])
    rt.start()
    rt.waitAllTerminated()
    #expect(logValues(rt) == [1, 2, 1, 2, 1, 2])
    #expect(rt.vm.counters.yields == 6)
    rt.stop()
}

/// consumer waits 3 times on global 6 and logs; producer logs and signals 3 times
let semaphoreSrc = logSrc + """
method UndefinedObject consumer temps=1
  push_int 0
  store_temp 0
loop:
  push_temp 0
  push_int 3
  lt
  jump_if_false done
  push_nil
  push_int 6
  send globalAt: 1
  send wait 0
  pop
  push_nil
  push_int 100
  send log: 1
  pop
  push_temp 0
  push_int 1
  add
  store_temp 0
  jump loop
done:
  push_temp 0
  return_top
end
method UndefinedObject producer temps=1
  push_int 0
  store_temp 0
loop:
  push_temp 0
  push_int 3
  lt
  jump_if_false done
  push_nil
  push_int 1
  send log: 1
  pop
  push_nil
  push_int 6
  send globalAt: 1
  send signal 0
  pop
  push_nil
  send yield 0
  pop
  push_temp 0
  push_int 1
  add
  store_temp 0
  jump loop
done:
  push_temp 0
  return_top
end
method UndefinedObject setup temps=0
  push_nil
  push_int 10
  send makeLog: 1
  pop
  push_nil
  push_int 6
  push_nil
  send newSemaphore 0
  send globalAt:put: 2
  return_top
end
"""

@Test func semaphoreWaitAndSignal() throws {
    let rt = try Runtime(semaphoreSrc, background: 1, start: false)
    rt.spawn("setup")
    let c = rt.spawn("consumer")
    let p = rt.spawn("producer")
    rt.start()
    rt.waitAllTerminated()
    #expect(rt.result(c) == 3 && rt.result(p) == 3)
    // the consumer blocks first, so every signal hands over directly
    #expect(logValues(rt) == [1, 100, 1, 100, 1, 100])
    #expect(rt.vm.excessSignals(rt.global(6)) == 0)
    rt.stop()
}

/// Waiters are woken in the order they waited.
@Test func semaphoreWaitersAreFIFO() throws {
    let src = logSrc + """
    method UndefinedObject waitThenLog: temps=0
      push_nil
      push_int 6
      send globalAt: 1
      send wait 0
      pop
      push_nil
      push_temp 0
      send log: 1
      return_top
    end
    """
    let rt = try Runtime(src, background: 1, start: false)
    let sem = rt.vm.newSemaphore()
    rt.vm.setGlobal(6, sem)
    rt.vm.setGlobal(3, rt.vm.newArray(10))
    rt.vm.setGlobal(4, int(0))
    for tag in [5, 3, 9, 1, 7] {
        rt.spawn("waitThenLog:", [int(Int64(tag))])
        #expect(rt.vm.runOneSlice(worker: 1))  // runs until it waits
    }
    #expect(rt.vm.waiterCount(sem) == 5)
    for _ in 0..<5 { rt.vm.signal(sem) }
    while rt.vm.runOneSlice(worker: 1) {}
    #expect(logValues(rt) == [5, 3, 9, 1, 7])
    #expect(rt.vm.excessSignals(sem) == 0 && rt.vm.liveProcessCount == 0)
    rt.stop()
}

let hogSrc = """
method UndefinedObject hog temps=0
loop:
  push_true
  jump_if_true loop
  return_self
end
method UndefinedObject finisher temps=0
  push_nil
  push_int 7
  push_int 99
  send globalAt:put: 2
  return_top
end

"""

@Test func budgetPreemptsAnInfiniteLoop() throws {
    let rt = try Runtime(hogSrc, background: 1, sliceMs: 2, start: false)
    let hog = rt.spawn("hog")
    let fin = rt.spawn("finisher")
    rt.start()
    #expect(eventually { rt.state(fin) == .terminated })
    #expect(rt.global(7) == int(99))
    #expect(rt.vm.counters.preemptions >= 1)
    rt.vm.terminate(hog)
    rt.waitAllTerminated()
    rt.stop()
}

@Test func processMigratesBetweenWorkersMidMethod() throws {
    // t0 = a temp computed before the yield and used after it
    let src = """
    method UndefinedObject migrate temps=1
      push_nil
      push_int 3
      push_nil
      send workerId 0
      send globalAt:put: 2
      pop
      push_int 40
      store_temp 0
      push_nil
      send yield 0
      pop
      push_nil
      push_int 4
      push_nil
      send workerId 0
      send globalAt:put: 2
      pop
      push_temp 0
      push_int 2
      add
      return_top
    end
    ; preempted by budget on one worker, finished on another; t0 = i
    method UndefinedObject count: temps=1
      push_int 0
      store_temp 1
    loop:
      push_temp 1
      push_temp 0
      lt
      jump_if_false done
      push_temp 1
      push_int 1
      add
      store_temp 1
      jump loop
    done:
      push_nil
      send workerId 0
      push_lit 1000000000
      mul
      push_temp 1
      add
      return_top
    end
    """
    let rt = try Runtime(src, background: 2, start: false)
    let p = rt.spawn("migrate")
    #expect(rt.vm.runOneSlice(worker: 1))          // runs until the yield
    #expect(rt.state(p) == .ready)
    #expect(rt.vm.runOneSlice(worker: 2))          // resumes mid-method on another worker
    #expect(rt.global(3) == int(1) && rt.global(4) == int(2))
    #expect(rt.result(p) == 42)

    let n: Int64 = checkedBuild ? 5_000_000 : 20_000_000
    let q = rt.spawn("count:", [int(n)])
    #expect(rt.vm.runOneSlice(worker: 1, budgetNs: 1_000_000)) // preempted after ~1 ms
    #expect(rt.state(q) == .ready)
    while rt.vm.runOneSlice(worker: 2) {}
    #expect(rt.result(q) == 2 * 1_000_000_000 + n)
    #expect(rt.vm.counters.preemptions >= 1)
    rt.stop()
}

@Test func externalSignalFromANonVMThread() throws {
    let src = """
    method UndefinedObject waiter temps=0
      push_nil
      push_int 1
      send globalAt: 1
      send wait 0
      pop
      push_int 77
      return_top
    end
    """
    let rt = try Runtime(src, background: 2)
    let sem = rt.vm.newSemaphore()
    rt.vm.setGlobal(1, sem)
    let p = rt.spawn("waiter")
    #expect(eventually { rt.state(p) == .waiting })
    let ref = rt.vm.ref
    let t = TestThread { ref.signalFromOutside(sem, handle: nil) }
    t.join()
    rt.waitAllTerminated()
    #expect(rt.result(p) == 77)
    #expect(rt.vm.counters.externalSignals == 1)
    rt.stop()
}

let sleeperSrc = """
method UndefinedObject sleeper: temps=1
  push_nil
  send newSemaphore 0
  store_temp 1
  push_nil
  push_temp 0
  push_temp 1
  send delay:signal: 2
  pop
  push_temp 1
  send wait 0
  pop
  push_int 5
  return_top
end
"""

@Test func delayWaitUsesAGCDTimerAndPendingRoot() throws {
    let rt = try Runtime(sleeperSrc, background: 1)
    let t0 = now()
    for _ in 0..<20 { rt.spawn("sleeper:", [int(30)]) }
    rt.waitAllTerminated()
    let ms = Double(now() - t0) / 1e6
    // A GCD timer's callback can wait long for a GCD thread under
    // ThreadSanitizer and load (concurrent-young: up to 25 s).
    #expect(ms >= 29 && ms < 60_000)
    #expect(rt.vm.counters.externalSignals == 20)
    #expect(rt.vm.pendingRootCount == 0)
    rt.stop()
}

/// Semaphores held only by the pending-root table survive collections and
/// are signalled when their timers fire. (1.5 s timers: with 80 ms ones the
/// suite under load fired some before the count was read.)
@Test func pendingRootsSurviveACollection() throws {
    let src = """
    ; t0 = n, t1 = i
    method UndefinedObject armTimers: temps=1
      push_int 0
      store_temp 1
    loop:
      push_temp 1
      push_temp 0
      lt
      jump_if_false done
      push_nil
      push_lit 1500
      push_nil
      send newSemaphore 0
      send delay:signal: 2
      pop
      push_temp 1
      push_int 1
      add
      store_temp 1
      jump loop
    done:
      push_temp 1
      return_top
    end
    """
    let rt = try Runtime(src, background: 2)
    rt.spawn("armTimers:", [int(20)])
    rt.waitAllTerminated()
    #expect(rt.vm.pendingRootCount == 20)
    rt.vm.collect()
    rt.vm.compact()
    rt.vm.collect()
    #expect(eventually(60) { rt.vm.counters.externalSignals == 20 })
    #expect(eventually { rt.vm.pendingRootCount == 0 })
    #expect(rt.vm.counters.staleExternalSignals == 0)
    rt.stop()
}

@Test func stackOverflowTerminatesTheProcessAndSignalsExit() throws {
    let src = """
    method UndefinedObject down: temps=0
      push_nil
      push_temp 0
      push_int 1
      add
      send down: 1
      return_top
    end
    method UndefinedObject watcher temps=1
      push_nil
      send newSemaphore 0
      store_temp 0
      push_nil
      push_lit #down:
      push_int 0
      push_nil
      push_false
      push_temp 0
      send fork:with:priority:main:exit: 5
      pop
      push_temp 0
      send wait 0
      pop
      push_int 1
      return_top
    end
    method UndefinedObject sum: temps=2
      push_int 0
      store_temp 1
      push_int 0
      store_temp 2
    loop:
      push_temp 1
      push_temp 0
      lt
      jump_if_false done
      push_temp 2
      push_temp 1
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
    let rt = try Runtime(src, background: 2)
    let other = rt.spawn("sum:", [int(200_000)])
    let p = rt.spawn("watcher")
    let direct = rt.spawn("down:", [int(0)])
    rt.waitAllTerminated()
    #expect(rt.result(p) == 1)
    #expect(rt.result(other) == 199_999 * 200_000 / 2)  // only the overflowing Processes ended
    #expect(rt.vm.counters.stackOverflows == 2)
    #expect(rt.vm.error(of: direct)?.kind == .stackOverflow)
    #expect(rt.vm.error(of: direct)?.selector == "down:")
    #expect(rt.vm.result(of: direct) == rt.image.nilObject)
    #expect(rt.vm.error(of: p) == nil)
    rt.stop()
}

/// Terminating a Process that is ready, waiting, running on another
/// worker, the current one, and already terminated.
@Test func terminateInEachState() throws {
    let src = hogSrc + """
    method UndefinedObject waitOn6 temps=0
      push_nil
      push_int 6
      send globalAt: 1
      send wait 0
      return_top
    end
    method UndefinedObject suicide temps=0
      push_nil
      push_int 8
      push_int 1
      send globalAt:put: 2
      pop
      push_nil
      send activeProcess 0
      send terminate 0
      pop
      push_nil
      push_int 8
      push_int 2
      send globalAt:put: 2
      return_top
    end
    """
    let rt = try Runtime(src, background: 1, start: false)
    let sem = rt.vm.newSemaphore()
    rt.vm.setGlobal(6, sem)
    func exitSem() -> Oop { rt.vm.newSemaphore() }

    // ready
    let e1 = exitSem()
    let ready = rt.spawn("hog", exit: e1)
    rt.vm.terminate(ready)
    #expect(rt.state(ready) == .terminated && rt.vm.excessSignals(e1) == 1)

    // waiting
    let e2 = exitSem()
    let waiting = rt.spawn("waitOn6", exit: e2)
    #expect(rt.vm.runOneSlice(worker: 1))
    #expect(rt.state(waiting) == .waiting && rt.vm.waiterCount(sem) == 1)
    rt.vm.terminate(waiting)
    #expect(rt.state(waiting) == .terminated && rt.vm.waiterCount(sem) == 0 && rt.vm.excessSignals(e2) == 1)

    // the current Process terminates itself
    let e3 = exitSem()
    let suicide = rt.spawn("suicide", exit: e3)
    #expect(rt.vm.runOneSlice(worker: 1))
    #expect(rt.state(suicide) == .terminated && rt.global(8) == int(1) && rt.vm.excessSignals(e3) == 1)

    // already terminated: nothing happens
    rt.vm.terminate(suicide)
    #expect(rt.vm.excessSignals(e3) == 1)

    // running on another worker: a request honoured at its next budget check
    rt.start()
    let e4 = exitSem()
    let running = rt.spawn("hog", exit: e4)
    #expect(eventually { rt.state(running) == .running })
    rt.vm.terminate(running)
    #expect(eventually { rt.state(running) == .terminated })
    #expect(eventually { rt.vm.excessSignals(e4) == 1 })
    #expect(rt.vm.liveProcessCount == 0)
    #expect(rt.vm.counters.terminations == 4)
    rt.stop()
}

/// 10,000 Processes parked on one Semaphore, then released.
@Test func tenThousandParkedProcesses() throws {
    let src = """
    method UndefinedObject parked: temps=0
      push_nil
      push_int 6
      send globalAt: 1
      send wait 0
      pop
      push_temp 0
      return_top
    end
    """
    let n = 10_000
    let rt = try Runtime(src, background: 4, heapBlocks: 4096, configure: { $0.recordCapacity = 16_384 })
    let sem = rt.vm.newSemaphore()
    rt.vm.setGlobal(6, sem)
    for i in 0..<n {
        guard rt.vm.spawn(receiver: rt.image.nilObject, selector: "parked:", arguments: [int(Int64(i))],
                          keep: false) != nil else {
            Issue.record("spawn \(i) failed")
            break
        }
    }
    #expect(eventually(60) { rt.vm.waiterCount(sem) == n })
    #expect(rt.vm.liveProcessCount == n)
    rt.vm.collect()
    for _ in 0..<n { rt.vm.signal(sem) }
    rt.waitAllTerminated()
    #expect(rt.vm.counters.terminations == UInt64(n))
    #expect(rt.vm.liveRecordCount == 0)
    rt.stop()
}

@Test func gcKeepsParkedProcessStacksAlive() throws {
    // 40 Processes each build a 200-node list held only in a temp, wait,
    // then sum it. Meanwhile churners allocate enough to force GCs.
    let src = """
    class Cell Object 2
    ; t0 = n, t1 = head, t2 = i, t3 = sum
    method UndefinedObject keeper: temps=3
      push_nil
      store_temp 1
      push_int 0
      store_temp 2
    build:
      push_temp 2
      push_temp 0
      lt
      jump_if_false built
      push_lit @Cell
      send basicNew 0
      dup
      push_temp 1
      send setNext: 1
      pop
      dup
      push_temp 2
      send setVal: 1
      pop
      store_temp 1
      push_temp 2
      push_int 1
      add
      store_temp 2
      jump build
    built:
      push_nil
      push_int 6
      send globalAt: 1
      send wait 0
      pop
      push_int 0
      store_temp 3
    walk:
      push_temp 1
      push_nil
      identical
      jump_if_true done
      push_temp 3
      push_temp 1
      send val 0
      add
      store_temp 3
      push_temp 1
      send next 0
      store_temp 1
      jump walk
    done:
      push_temp 3
      return_top
    end
    method Cell setNext: temps=0
      push_temp 0
      store_ivar 0
      return_self
    end
    method Cell setVal: temps=0
      push_temp 0
      store_ivar 1
      return_self
    end
    method Cell next temps=0
      push_ivar 0
      return_top
    end
    method Cell val temps=0
      push_ivar 1
      return_top
    end
    """ + "\n" + churnSrc
    let rt = try Runtime(src, background: 4, heapBlocks: 64)
    let sem = rt.vm.newSemaphore()
    rt.vm.setGlobal(6, sem)
    var keepers: [Oop] = []
    for _ in 0..<40 { keepers.append(rt.spawn("keeper:", [int(200)])) }
    #expect(eventually { keepers.allSatisfy { rt.state($0) == .waiting } })
    // Module 4: with a nursery the churn scavenges (each a stop scanning
    // the parked stacks); without one it collects.
    func pauses() -> UInt64 { rt.image.om.counters.collections + rt.vm.nurseryCounters.scavenges }
    let collections = pauses()
    rt.spawn("churn:", [int(checkedBuild ? 150_000 : 300_000)])
    rt.spawn("churn:", [int(checkedBuild ? 150_000 : 300_000)])
    #expect(eventually(120) { rt.vm.liveProcessCount == 40 })
    #expect(pauses() - collections >= 3, "pauses \(pauses() - collections), errors \(rt.vm.counters.processErrors)")
    for _ in 0..<40 { rt.vm.signal(sem) }
    rt.waitAllTerminated()
    for k in keepers { #expect(rt.result(k) == 199 * 200 / 2) }
    rt.stop()
}

/// allocate n Arrays of 20 slots
let churnSrc = """
method UndefinedObject churn: temps=1
  push_int 0
  store_temp 1
loop:
  push_temp 1
  push_temp 0
  lt
  jump_if_false done
  push_lit @Array
  push_int 20
  send new: 1
  pop
  push_temp 1
  push_int 1
  add
  store_temp 1
  jump loop
done:
  push_temp 1
  return_top
end

"""

@Test func manyProcessesOnManyWorkers() throws {
    // 200 Processes ping-pong on a shared Semaphore, yield and allocate; the
    // counter Semaphore (global 6) must end with exactly 200 * 50 signals.
    let src = """
    ; t0 = rounds, t1 = i
    method UndefinedObject pinger: temps=1
      push_int 0
      store_temp 1
    loop:
      push_temp 1
      push_temp 0
      lt
      jump_if_false done
      push_nil
      push_int 6
      send globalAt: 1
      send signal 0
      pop
      push_lit @Array
      push_int 8
      send new: 1
      pop
      push_nil
      send yield 0
      pop
      push_temp 1
      push_int 1
      add
      store_temp 1
      jump loop
    done:
      push_temp 1
      return_top
    end
    """
    let rt = try Runtime(src, background: 7, heapBlocks: 128)
    let sem = rt.vm.newSemaphore()
    rt.vm.setGlobal(6, sem)
    for _ in 0..<200 { rt.spawn("pinger:", [int(50)]) }
    rt.waitAllTerminated()
    #expect(rt.vm.excessSignals(sem) == 200 * 50)
    #expect(rt.vm.counters.terminations == 200)
    rt.stop()
}
