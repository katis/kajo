// Headless tests of the Process machinery, copied from
// ../ui-thread-scheduling and run here with a small nursery and the
// collector's verifier on, so every scavenge they cause is checked (SPEC.md
// "Verification"). Threaded ones also run concurrent marking cycles back to
// back, with the mark-set verifier at every final mark. Run also under ThreadSanitizer: `swift test --sanitize=thread`.

import Darwin
import Dispatch
import Kasm
import Synchronization
import Testing
@testable import VMR

/// Tests run generational with 256 KiB nurseries and verification on.
let testNursery = 256 << 10

/// Threaded runtimes run concurrent marking with a 1 percent threshold, so a
/// cycle starts at almost every scavenge and the inherited tests exercise
/// it, with every verifier on, and (this experiment) age N = 2 with
/// survivor spaces and relocation of every live snapshot block in every
/// cycle. Runtimes stepped from the test thread (`start: false`) keep the
/// defaults (N = 1, no relocation): they have no marker thread.
func runtime(_ src: String, background: Int, heap: Int = 64 << 20, sliceMs: Double = 5,
             start: Bool = true, nursery: Int = testNursery, config: CMConfig? = nil) throws -> Runtime {
    let img = try Image.fromSources(try baseSources() + [src], heapSize: heap, nurseryBytes: nursery)
    var cfg = config ?? CMConfig()
    if config == nil && start {
        cfg.threshold = 0.01
        cfg.ageN = 2
        cfg.relocThreshold = 101
    }
    // Threaded runtimes run under a young collector without stopping the
    // world: `KAJO_TEST_YOUNG` (local by default, offload, or stw).
    var y = YCConfig()
    y.verifyYoung = true
    y.verifyEvery = 4
    if start && config == nil { y.mode = testYoungMode() }
    return Runtime(img, background: background, pollEvery: 64, sliceMs: sliceMs, start: start, verify: true, config: cfg, young: y)
}

func testYoungMode() -> Int {
    switch getenv("KAJO_TEST_YOUNG").map({ String(cString: $0) }) ?? "local" {
    case "offload": return YoungMode.offload
    case "stw": return YoungMode.stw
    default: return YoungMode.local
    }
}

extension Worker {
    /// Holders in all of this worker's remembered buffers.
    var remCount: Int { (0..<maxNurseries).reduce(0) { $0 + rem[$1].count } }
}

func result(_ rt: Runtime, _ p: Oop) -> Int64 {
    intVal(rt.vm.pointee.results[Int(processId(rt.vm, p))])
}

func global(_ rt: Runtime, _ i: Int) -> Oop { rt.vm.pointee.globals[i - 1] }

/// Wait (with a timeout) until `cond` holds.
func eventually(_ seconds: Double = 5, _ cond: () -> Bool) -> Bool {
    let end = now() + UInt64(seconds * 1e9)
    while now() < end {
        if cond() { return true }
        usleep(500)
    }
    return cond()
}

/// Log helper in Smalltalk: `nil log: x` appends x to the Array in global 3,
/// using global 4 as the fill count.
private let logSrc = """
method UndefinedObject log: temps=1
  push_nil
  push_int 4
  send globalAt: 1
  push_int 1
  add
  store_temp 1
  push_nil
  push_int 4
  push_temp 1
  send globalAt:put: 2
  pop
  push_nil
  push_int 3
  send globalAt: 1
  push_temp 1
  push_temp 0
  send at:put: 2
  return_top
end
method UndefinedObject makeLog: temps=0
  push_nil
  push_int 3
  push_lit @Array
  push_temp 0
  send new: 1
  send globalAt:put: 2
  pop
  push_nil
  push_int 4
  push_int 0
  send globalAt:put: 2
  return_top
end

"""

private func logValues(_ rt: Runtime) -> [Int64] {
    let om = rt.vm.pointee.om
    let arr = global(rt, 3)
    let n = Int(intVal(global(rt, 4)))
    return (0..<n).map { intVal(om.slot(arr, $0)) }
}

@Test func forkRunsToCompletion() throws {
    let rt = try runtime("method UndefinedObject twice: temps=0\n push_temp 0\n push_temp 0\n add\n return_top\nend\n", background: 2)
    let p = spawn(rt.vm, rt.vm.pointee.nilObj, rt.symbol("twice:"), mkInt(21))
    waitAllTerminated(rt.vm)
    #expect(result(rt, p) == 42)
    #expect(rt.vm.metric(.forks) == 1 && rt.vm.metric(.terminations) == 1)
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
    let rt = try runtime(src, background: 3)
    let p = spawn(rt.vm, rt.vm.pointee.nilObj, rt.symbol("parent"), rt.vm.pointee.nilObj)
    waitAllTerminated(rt.vm)
    #expect(result(rt, p) == 43)
    #expect(rt.vm.metric(.forks) == 2)
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
    let rt = try runtime(src, background: 1, start: false)
    let vm = rt.vm, nilObj = vm.pointee.nilObj
    spawn(vm, nilObj, rt.symbol("setup"), nilObj)
    spawn(vm, nilObj, rt.symbol("yielder:"), mkInt(1))
    spawn(vm, nilObj, rt.symbol("yielder:"), mkInt(2))
    rt.start()
    waitAllTerminated(vm)
    #expect(logValues(rt) == [1, 2, 1, 2, 1, 2])
    #expect(vm.metric(.yields) == 6)
    rt.stop()
}

@Test func semaphoreWaitAndSignal() throws {
    // consumer waits 3 times on global 6 and logs; producer logs and signals 3 times
    let src = logSrc + """
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
    let rt = try runtime(src, background: 1, start: false)
    let vm = rt.vm, nilObj = vm.pointee.nilObj
    spawn(vm, nilObj, rt.symbol("setup"), nilObj)
    let c = spawn(vm, nilObj, rt.symbol("consumer"), nilObj)
    let p = spawn(vm, nilObj, rt.symbol("producer"), nilObj)
    rt.start()
    waitAllTerminated(vm)
    #expect(result(rt, c) == 3 && result(rt, p) == 3)
    // the consumer blocks first, so every signal hands over directly
    #expect(logValues(rt) == [1, 100, 1, 100, 1, 100])
    #expect(intVal(vm.pointee.om.slot(global(rt, 6), sExcess)) == 0)
    rt.stop()
}

private let hogSrc = """
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
    let rt = try runtime(hogSrc, background: 1, sliceMs: 2, start: false)
    let vm = rt.vm, nilObj = vm.pointee.nilObj
    let hog = spawn(vm, nilObj, rt.symbol("hog"), nilObj)
    let fin = spawn(vm, nilObj, rt.symbol("finisher"), nilObj)
    rt.start()
    // termination happens under the scheduler lock, after the global write
    #expect(eventually { processState(vm, fin) == stTerminated })
    #expect(global(rt, 7) == mkInt(99))
    #expect(vm.metric(.preemptions) >= 1)
    hostTerminate(vm, hog)
    waitAllTerminated(vm)
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
    let rt = try runtime(src, background: 2, start: false)
    let vm = rt.vm, nilObj = vm.pointee.nilObj
    let w1 = rt.workers[1], w2 = rt.workers[2]
    let p = spawn(vm, nilObj, rt.symbol("migrate"), nilObj)
    #expect(runOneSlice(vm, w1))          // runs until the yield
    #expect(processState(vm, p) == stReady)
    #expect(runOneSlice(vm, w2))          // resumes mid-method on another worker
    #expect(global(rt, 3) == mkInt(1) && global(rt, 4) == mkInt(2))
    #expect(result(rt, p) == 42)

    let q = spawn(vm, nilObj, rt.symbol("count:"), mkInt(20_000_000))
    #expect(runOneSlice(vm, w1, budgetNs: 1_000_000)) // preempted after ~1 ms
    #expect(processState(vm, q) == stReady)
    while runOneSlice(vm, w2) {}
    #expect(result(rt, q) == 2 * 1_000_000_000 + 20_000_000)
    #expect(vm.metric(.preemptions) >= 1)
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
    let rt = try runtime(src, background: 2)
    let vm = rt.vm, nilObj = vm.pointee.nilObj
    let p = spawn(vm, nilObj, rt.symbol("waiter"), nilObj)
    #expect(eventually { processState(vm, p) == stWaiting })
    let sem = global(rt, 1), bits = UInt(bitPattern: vm)
    let t = Thread { signalFromOutside(UnsafeMutablePointer<VMCore>(bitPattern: bits)!, sem, handle: -1) }
    t.join()
    waitAllTerminated(vm)
    #expect(result(rt, p) == 77)
    #expect(vm.metric(.extSignals) == 1)
    rt.stop()
}

@Test func delayWaitUsesAGCDTimerAndPendingRoot() throws {
    let src = """
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
    let rt = try runtime(src, background: 1)
    let vm = rt.vm
    let t0 = now()
    for _ in 0..<20 { spawn(vm, vm.pointee.nilObj, rt.symbol("sleeper:"), mkInt(30)) }
    waitAllTerminated(vm)
    let ms = Double(now() - t0) / 1e6
    // Upper bound 60 s (was 1 s, then 5 s): under ThreadSanitizer with the
    // other tests' VMs, marker threads and (this experiment) the relocation
    // tests running in parallel, the GCD timer's callback waits for a GCD
    // thread for up to 25 s (alone: 45 ms).
    #expect(ms >= 29 && ms < 60000)
    #expect(vm.metric(.extSignals) == 20)
    #expect(vm.pointee.pend.pointee.count == 0)
    rt.stop()
}

@Test func readFileThroughDispatchIO() throws {
    let path = utsKernelsDir + "/lib.kasm"
    let src = """
    method UndefinedObject reader temps=2
      push_nil
      send newSemaphore 0
      store_temp 0
      push_nil
      push_lit #\(path)
      push_temp 0
      send readFile:signal: 2
      store_temp 1
      push_temp 0
      send wait 0
      pop
      push_nil
      push_temp 1
      send ioResult: 1
      return_top
    end
    """
    let rt = try runtime(src, background: 1)
    let vm = rt.vm
    let p = spawn(vm, vm.pointee.nilObj, rt.symbol("reader"), vm.pointee.nilObj)
    waitAllTerminated(vm)
    let ba = vm.pointee.results[Int(intVal(vm.pointee.om.slot(p, pId)))]
    let expected = try readTextFile(path).utf8.count
    #expect(hdrSlots(vm.pointee.om.header(ba)) == expected)
    #expect(vm.pointee.om.bytesPtr(ba)[0] == UInt8(ascii: ";"))
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
    """
    let rt = try runtime(src, background: 2)
    let vm = rt.vm
    let p = spawn(vm, vm.pointee.nilObj, rt.symbol("watcher"), vm.pointee.nilObj)
    waitAllTerminated(vm)
    #expect(result(rt, p) == 1)
    #expect(vm.metric(.overflows) == 1)
    rt.stop()
}

// MARK: - a fake main thread

/// Context for the C hooks: a pthread acting as the main worker.
final class FakeMain: @unchecked Sendable {
    var mutex = pthread_mutex_t()
    var cond = pthread_cond_t()
    var wakes = 0
    var stop = false
    var thread: pthread_t? = nil
    let uiCalls = Atomic<Int>(0)
    let uiOffMain = Atomic<Int>(0)
    var stuck: [(Int64, String)] = []
    let vmBits: UInt

    init(_ vm: VMRef) {
        vmBits = UInt(bitPattern: vm)
        pthread_mutex_init(&mutex, nil)
        pthread_cond_init(&cond, nil)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        vm.pointee.hookCtx = ctx
        vm.pointee.wakeMain = { ctx in
            let m = Unmanaged<FakeMain>.fromOpaque(ctx!).takeUnretainedValue()
            pthread_mutex_lock(&m.mutex)
            m.wakes += 1
            pthread_cond_signal(&m.cond)
            pthread_mutex_unlock(&m.mutex)
        }
        vm.pointee.uiHook = { ctx, kind, value in
            let m = Unmanaged<FakeMain>.fromOpaque(ctx!).takeUnretainedValue()
            m.uiCalls.wrappingAdd(1, ordering: .relaxed)
            if let t = m.thread, pthread_equal(pthread_self(), t) == 0 { m.uiOffMain.wrappingAdd(1, ordering: .relaxed) }
            return value * 2
        }
        vm.pointee.stuckHook = { ctx, id, sel, ms in
            let m = Unmanaged<FakeMain>.fromOpaque(ctx!).takeUnretainedValue()
            m.stuck.append((id, String(cString: sel)))
        }
        pthread_create(&thread, nil, { arg in
            let m = Unmanaged<FakeMain>.fromOpaque(arg).takeUnretainedValue()
            let vm = UnsafeMutablePointer<VMCore>(bitPattern: m.vmBits)!
            while true {
                pthread_mutex_lock(&m.mutex)
                while m.wakes == 0 && !m.stop { pthread_cond_wait(&m.cond, &m.mutex) }
                let stop = m.stop
                m.wakes = 0
                pthread_mutex_unlock(&m.mutex)
                if stop { return nil }
                _ = runMain(vm, budgetNs: 2_000_000)
            }
        }, ctx)
    }

    func finish() {
        pthread_mutex_lock(&mutex)
        stop = true
        pthread_cond_signal(&cond)
        pthread_mutex_unlock(&mutex)
        pthread_join(thread!, nil)
    }
}

@Test func hopToMainRetriesTheUIPrimitiveOnMain() throws {
    let src = """
    ; answers (label result) + 1000 * (worker after the hop) + 10 * (worker after detach)
    method UndefinedObject hopper temps=3
      push_nil
      push_int 21
      send setLabel: 1
      store_temp 0
      push_nil
      send workerId 0
      store_temp 1
      push_nil
      send detachFromMain 0
      pop
      push_nil
      send workerId 0
      store_temp 2
      push_temp 0
      push_temp 1
      push_lit 1000
      mul
      add
      push_temp 2
      push_int 10
      mul
      add
      return_top
    end
    """
    let rt = try runtime(src, background: 1)
    let vm = rt.vm
    let fake = FakeMain(vm)
    let p = spawn(vm, vm.pointee.nilObj, rt.symbol("hopper"), vm.pointee.nilObj)
    waitAllTerminated(vm)
    fake.finish()
    // 42 from the hook (21 * 2), ran on worker 0 (main), then worker 1 after detaching
    #expect(result(rt, p) == 42 + 0 * 1000 + 10)
    #expect(fake.uiCalls.load(ordering: .relaxed) == 1) // the primitive did not run off main
    #expect(fake.uiOffMain.load(ordering: .relaxed) == 0)
    #expect(vm.metric(.hops) == 1 && vm.metric(.detaches) == 1)
    #expect(vm.pointee.hopLatency.pointee.count == 1)
    rt.stop()
}

@Test func mainAffineHogIsPreemptedAndReportedStuck() throws {
    let src = hogSrc + """
    method UndefinedObject ui temps=0
      push_nil
      push_int 5
      send setLabel: 1
      return_top
    end
    """
    let rt = try runtime(src, background: 1)
    let vm = rt.vm, nilObj = vm.pointee.nilObj
    let fake = FakeMain(vm)
    fake.finish() // drive turns from this thread instead; hooks stay installed
    let hog = spawn(vm, nilObj, rt.symbol("hog"), nilObj, priority: 1, main: true)
    var turns = 0
    let t0 = now()
    while now() - t0 < 400_000_000 {
        let st = runMain(vm, budgetNs: 1_000_000)
        // Budget preemption, not collector stops: time parked in a stop (the
        // young verifier's pause after every collection, slow in a debug
        // build beside the other tests) and blocked entering is excluded.
        #expect(st.ns &- st.parkedNs &- st.enterWaitNs &- st.leaveWaitNs < 20_000_000)
        turns += 1
        usleep(2000)
    }
    // A UI-priority Process still gets the main thread.
    let ui = spawn(vm, nilObj, rt.symbol("ui"), nilObj, priority: 2, main: true)
    _ = runMain(vm, budgetNs: 1_000_000)
    #expect(processState(vm, ui) == stTerminated)
    checkStuck(vm, limitNs: 300_000_000)
    #expect(fake.stuck.count == 1 && fake.stuck.first?.1 == "hog")
    #expect(vm.metric(.preemptions) >= UInt64(turns - 1))
    hostTerminate(vm, hog)
    #expect(liveProcessCount(vm) == 0)
    rt.stop()
}

@Test func gcKeepsParkedProcessStacksAlive() throws {
    // 40 Processes each build a 200-node list held only in a temp, wait,
    // then sum it. Meanwhile a churner allocates enough to force GCs.
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
    ; allocate n Arrays of 20 slots
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
    let rt = try runtime(src, background: 4, heap: 64 * blockSize)
    let vm = rt.vm, nilObj = vm.pointee.nilObj
    vm.pointee.globals[5] = hostNewSemaphore(vm)
    var keepers: [Oop] = []
    for _ in 0..<40 { keepers.append(spawn(vm, nilObj, rt.symbol("keeper:"), mkInt(200))) }
    #expect(eventually { keepers.allSatisfy { processState(vm, $0) == stWaiting } })
    spawn(vm, nilObj, rt.symbol("churn:"), mkInt(300_000))
    spawn(vm, nilObj, rt.symbol("churn:"), mkInt(300_000))
    // 60 s (was 20): 12 s alone under ThreadSanitizer, slower beside the
    // other tests, with a cycle and mark-set verification at most scavenges.
    #expect(eventually(60) { liveProcessCount(vm) == 40 })
    #expect(vm.metric(.scavenges) + vm.metric(.ycCollections) >= 3)
    for _ in 0..<40 { hostSignal(vm, global(rt, 6)) }
    waitAllTerminated(vm)
    for k in keepers { #expect(result(rt, k) == 199 * 200 / 2) }
    rt.stop()
    #expect(vm.metric(.verifyRuns) + vm.metric(.youngVerifyRuns) >= 3 && vm.metric(.verifyFailures) == 0)
}

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
    let rt = try runtime(src, background: 7, heap: 128 * blockSize)
    let vm = rt.vm, nilObj = vm.pointee.nilObj
    vm.pointee.globals[5] = hostNewSemaphore(vm)
    for _ in 0..<200 { spawn(vm, nilObj, rt.symbol("pinger:"), mkInt(50)) }
    waitAllTerminated(vm)
    #expect(intVal(vm.pointee.om.slot(global(rt, 6), sExcess)) == 200 * 50)
    // The counter is bumped after the termination is published (inherited);
    // the last one can trail waitAllTerminated.
    #expect(eventually { vm.metric(.terminations) == 200 })
    rt.stop()
    #expect(vm.metric(.verifyFailures) == 0)
}

/// Minimal joinable thread for tests.
final class Thread: @unchecked Sendable {
    var tid: pthread_t? = nil
    let body: () -> Void
    init(_ body: @escaping () -> Void) {
        self.body = body
        pthread_create(&tid, nil, { arg in
            Unmanaged<Thread>.fromOpaque(arg).takeUnretainedValue().body()
            return nil
        }, Unmanaged.passUnretained(self).toOpaque())
    }
    func join() { pthread_join(tid!, nil) }
}

/// The young configuration of a threaded kernel test: the test mode under
/// concurrent marking, stop-the-world for the stop-the-world reference.
func testYoung(_ cfg: CMConfig) -> YCConfig {
    var y = YCConfig()
    y.verifyYoung = true
    if cfg.concurrent { y.mode = testYoungMode() }
    return y
}
