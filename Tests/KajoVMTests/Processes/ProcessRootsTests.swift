// The rules about what a stop scans, each with a test that fails when its
// rule is switched off (concurrent-young SPEC amendment 8 and the
// scheduling SPEC's "GC roots"; docs/modules/workers.md).

import Darwin
import Testing
@testable import KajoVM

/// A Process suspended mid-method resumes after a compaction moved its
/// method's bytecodes and literals: resume re-derives both bases from the
/// method oop (module 2's `restore`).
@Test func resumeReDerivesBasesAfterACompaction() throws {
    let src = """
    ; t0 = acc. Computes before and after the wait with literals.
    method UndefinedObject moveMe temps=1
      push_lit 1000
      store_temp 0
      push_nil
      push_int 6
      send globalAt: 1
      send wait 0
      pop
      push_temp 0
      push_lit 234
      add
      push_lit 1000000
      add
      return_top
    end
    """
    var garbage: [RootHandle] = []
    // Module 6 pins methods for good; an image without pins (no relocation)
    // keeps module 2's re-derivation after a compaction tested.
    let rt = try Runtime(src, background: 1, start: false, pinsForGood: false, before: { image in
        // garbage below the methods, so a compaction slides them down
        for _ in 0..<2000 {
            let o = image.om.allocate(image.context, classIndex: WellKnown.array, slots: 30, fill: image.nilObject)!
            garbage.append(image.om.addRoot(o))
        }
    })
    for h in garbage { rt.image.om.removeRoot(h) }
    let sem = rt.vm.newSemaphore()
    rt.vm.setGlobal(6, sem)
    let p = rt.spawn("moveMe")
    #expect(rt.vm.runOneSlice(worker: 1))
    #expect(rt.state(p) == .waiting)
    let method = rt.image.lookup(WellKnown.undefinedObject, rt.image.symbol("moveMe")!)!
    let before = rt.vm.inspect { om in om.bodyOffset(om.load(method, MethodLayout.bytecodes)) }
    rt.vm.compact()
    let after = rt.vm.inspect { om in om.bodyOffset(om.load(method, MethodLayout.bytecodes)) }
    #expect(after < before)
    rt.vm.signal(sem)
    #expect(rt.vm.runOneSlice(worker: 1))
    #expect(rt.result(p) == 1_001_234)
    rt.stop()
}

/// The worker's `result` register is cleared when the Process terminates:
/// a stale one keeps a dead object alive (concurrent-young amendment 8).
@Test(arguments: [false, true])
func theResultRegisterIsClearedAtTermination(_ keep: Bool) throws {
    let src = """
    class Cell Object 1
    method UndefinedObject makeCell temps=0
      push_lit @Cell
      send basicNew 0
      return_top
    end
    """
    let rt = try Runtime(src, background: 1, start: false, configure: { $0.testSwitches.keepResultRegister = keep })
    let p = rt.spawn("makeCell")
    #expect(rt.vm.runOneSlice(worker: 1))
    let cell = rt.vm.result(of: p)
    let cls = rt.image.classIndex(named: "Cell")!
    #expect(rt.vm.inspect { $0.classIndex(of: cell) } == cls)
    rt.vm.release(p)  // the host drops the Process, which held the result
    rt.vm.collect()
    let live = rt.vm.inspect { $0.allInstances(of: cls).count }
    #expect(live == (keep ? 1 : 0))
    rt.stop()
}

/// A Process nobody references is kept by its record while it lives.
@Test func processesAreRootsThroughTheirRecords() throws {
    let src = """
    method UndefinedObject orphan: temps=0
      push_nil
      push_int 6
      send globalAt: 1
      send wait 0
      pop
      push_nil
      push_int 7
      push_temp 0
      send globalAt:put: 2
      return_top
    end
    """
    let rt = try Runtime(src, background: 1, start: false)
    let sem = rt.vm.newSemaphore()
    rt.vm.setGlobal(6, sem)
    #expect(rt.vm.spawn(receiver: rt.image.nilObject, selector: "orphan:", arguments: [int(31)], keep: false) != nil)
    #expect(rt.vm.runOneSlice(worker: 1))
    let processes = WellKnown.process
    for _ in 0..<3 {
        rt.vm.collect()
        rt.vm.compact()
    }
    #expect(rt.vm.inspect { $0.allInstances(of: processes).count } == 1)
    rt.vm.signal(sem)
    #expect(rt.vm.runOneSlice(worker: 1))
    #expect(rt.global(7) == int(31))
    rt.vm.collect()
    #expect(rt.vm.inspect { $0.allInstances(of: processes).count } == 0)
    rt.stop()
}

/// The registers are flushed to the saved form at every poll before the
/// worker parks or stops the world, so a stop scans the stack through the
/// current sp. The method moves an Array from its argument to the operand
/// stack only, then loops; a stop that scans through the sp saved at the
/// last primitive misses it. The switch `flushAfterStop` (flush after the
/// stop, so only the scan is stale) breaks the rule; in a checked build the
/// next stop then traps in module 1's mark ("marking a reference to a free
/// entry"), so the broken variant is run by hand, not in the suite
/// (docs/modules/workers.md, "Tests").
@Test(arguments: [false])
func registersAreFlushedBeforeEveryStop(_ late: Bool) throws {
    let src = """
    ; t0 = the Array, t1 = i
    method UndefinedObject hold: temps=1
      push_temp 0
      push_nil
      store_temp 0
      push_int 0
      store_temp 1
    loop:
      push_temp 1
      push_int 20
      lt
      jump_if_false done
      push_temp 1
      push_int 1
      add
      store_temp 1
      jump loop
    done:
      push_nil
      push_int 6
      send globalAt: 1
      send wait 0
      pop
      push_int 1
      send at: 1
      return_top
    end
    method UndefinedObject keep temps=0
      push_nil
      push_lit @Array
      push_int 1
      send new: 1
      dup
      push_int 1
      push_lit 4242
      send at:put: 2
      pop
      send hold: 1
      return_top
    end
    """
    let rt = try Runtime(src, background: 1, start: false, configure: {
        $0.stress = .stopEveryPoll
        $0.testSwitches.flushAfterStop = late
    })
    let sem = rt.vm.newSemaphore()
    rt.vm.setGlobal(6, sem)
    let p = rt.spawn("keep")
    #expect(rt.vm.runOneSlice(worker: 1))
    #expect(rt.state(p) == .waiting)
    #expect(rt.vm.counters.stops > 20)
    let survivors = rt.vm.inspect { om in
        om.allInstances(of: WellKnown.array).filter { om.count(of: $0) == 1 && om.load($0, 0) == int(4242) }.count
    }
    if late {
        #expect(survivors == 0)  // collected while the method still held it
        rt.vm.terminate(p)
    } else {
        #expect(survivors == 1)
        rt.vm.signal(sem)
        #expect(rt.vm.runOneSlice(worker: 1))
        #expect(rt.result(p) == 4242)
    }
    rt.stop(verifyHeap: !late)
}

/// A worker clears `current` and the record's `runningOn` before it
/// publishes a suspended Process: otherwise another worker can pick the
/// Process up and the late clear leaves it running with no worker named,
/// so its stack is scanned through the stale saved sp. The schedule
/// verifier at every stop checks that records and workers agree; the
/// window is widened (`perturb`) so the broken order shows quickly.
@Test(arguments: [false, true])
func aSuspendedProcessIsPublishedAfterClearingCurrent(_ broken: Bool) throws {
    let src = """
    ; t0 = n, t1 = i, t2 = acc
    method UndefinedObject yieldLoop: temps=2
      push_int 0
      store_temp 1
      push_int 0
      store_temp 2
    loop:
      push_temp 1
      push_temp 0
      lt
      jump_if_false done
      push_lit @Array
      push_int 2
      send new: 1
      pop
      push_nil
      send yield 0
      pop
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
    let rt = try Runtime(src, background: 3, heapBlocks: 256, configure: {
        $0.testSwitches.publishBeforeClearing = broken
        $0.perturb = Perturbation(seed: 7, probability: broken ? 0.01 : 0.05, maxSleepUs: broken ? 1000 : 300)
    })
    var ps: [Oop] = []
    let n: Int64 = broken ? 3000 : 400
    for _ in 0..<2 { ps.append(rt.spawn("yieldLoop:", [int(n)])) }
    var stops = 0
    while rt.vm.liveProcessCount > 0 && stops < 20_000 {
        rt.vm.collect()
        stops += 1
        if broken && rt.vm.counters.scheduleVerifierFailures > 0 { break }
    }
    if broken {
        // No terminate: with records and workers disagreeing it would free
        // a running Process's record. The Processes finish on their own.
        #expect(rt.vm.counters.scheduleVerifierFailures > 0)
    } else {
        rt.waitAllTerminated()
        for p in ps { #expect(rt.result(p) == (n - 1) * n / 2) }
        #expect(rt.vm.counters.scheduleVerifierFailures == 0)
    }
    rt.waitAllTerminated()
    rt.stop(verifyHeap: !broken)
}
