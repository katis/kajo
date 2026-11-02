// The main worker driven by a fake shell: a pthread that runs a turn on
// every wakeMain, with C-convention hooks (ADR 0004). Ported from
// experiments/ui-thread-scheduling, plus the preemption bound of the brief.

import Darwin
import Synchronization
import Testing
@testable import KajoVM

/// Context for the C hooks: a pthread acting as the shell's main thread.
final class FakeMain: @unchecked Sendable {
    var mutex = pthread_mutex_t()
    var cond = pthread_cond_t()
    var wakes = 0
    var stop = false
    var thread: pthread_t? = nil
    let uiCalls = Atomic<Int>(0)
    let uiOffMain = Atomic<Int>(0)
    let stuckMutex = Mutex<[(id: Int64, selector: String, ms: Double)]>([])
    let vm: VM

    init(_ vm: VM, run: Bool = true) {
        self.vm = vm
        pthread_mutex_init(&mutex, nil)
        pthread_cond_init(&cond, nil)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        vm.hooks = VMHooks(
            context: ctx,
            wakeMain: { ctx in
                let m = Unmanaged<FakeMain>.fromOpaque(ctx!).takeUnretainedValue()
                pthread_mutex_lock(&m.mutex)
                m.wakes += 1
                pthread_cond_signal(&m.cond)
                pthread_mutex_unlock(&m.mutex)
            },
            stuck: { ctx, id, selector, ms in
                let m = Unmanaged<FakeMain>.fromOpaque(ctx!).takeUnretainedValue()
                let s = String(cString: selector)
                m.stuckMutex.withLock { $0.append((id, s, ms)) }
            },
            shell: { ctx, kind, value in
                let m = Unmanaged<FakeMain>.fromOpaque(ctx!).takeUnretainedValue()
                m.uiCalls.wrappingAdd(1, ordering: .relaxed)
                if let t = m.thread, pthread_equal(pthread_self(), t) == 0 { m.uiOffMain.wrappingAdd(1, ordering: .relaxed) }
                return value * 2
            })
        guard run else { return }
        pthread_create(&thread, nil, { arg in
            let m = Unmanaged<FakeMain>.fromOpaque(arg).takeUnretainedValue()
            while true {
                pthread_mutex_lock(&m.mutex)
                while m.wakes == 0 && !m.stop { pthread_cond_wait(&m.cond, &m.mutex) }
                let stop = m.stop
                m.wakes = 0
                pthread_mutex_unlock(&m.mutex)
                if stop { return nil }
                _ = m.vm.runMain(budgetNs: 2_000_000)
            }
        }, ctx)
    }

    var stuck: [(id: Int64, selector: String, ms: Double)] { stuckMutex.withLock { $0 } }

    func finish() {
        pthread_mutex_lock(&mutex)
        stop = true
        pthread_cond_signal(&cond)
        pthread_mutex_unlock(&mutex)
        if let t = thread { pthread_join(t, nil) }
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
    let rt = try Runtime(src, background: 1, start: false)
    let fake = FakeMain(rt.vm)
    rt.start()
    let p = rt.spawn("hopper")
    rt.waitAllTerminated()
    fake.finish()
    // 42 from the hook (21 * 2), ran on worker 0 (main), then worker 1 after detaching
    #expect(rt.result(p) == 42 + 0 * 1000 + 10)
    #expect(fake.uiCalls.load(ordering: .relaxed) == 1) // the primitive did not run off main
    #expect(fake.uiOffMain.load(ordering: .relaxed) == 0)
    #expect(rt.vm.counters.hops == 1 && rt.vm.counters.detaches == 1)
    #expect(rt.vm.hopLatencies.count == 1)
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
    let rt = try Runtime(src, background: 1, start: false)
    let fake = FakeMain(rt.vm, run: false) // turns are driven from this thread; hooks installed
    rt.start()
    let hog = rt.spawn("hog", priority: Priority.normal, main: true)
    var turns = 0
    let t0 = now()
    while now() - t0 < 400_000_000 {
        let st = rt.vm.runMain(budgetNs: 1_000_000)
        // CPU, not wall time: under load the OS deschedules the thread for
        // tens of ms (AGENTS.md: a wall-clock assertion fails under load).
        #expect(st.cpuNs &- st.collectorNs < 20_000_000)
        turns += 1
        usleep(2000)
    }
    // A UI-priority Process still gets the main thread.
    let ui = rt.spawn("ui", priority: Priority.ui, main: true)
    _ = rt.vm.runMain(budgetNs: 1_000_000)
    #expect(rt.state(ui) == .terminated)
    rt.vm.checkStuck(limitNs: 300_000_000)
    rt.vm.checkStuck(limitNs: 300_000_000)  // reported once
    #expect(fake.stuck.count == 1 && fake.stuck.first?.selector == "hog")
    #expect(rt.vm.counters.preemptions >= UInt64(turns - 1))
    rt.vm.terminate(hog)
    #expect(rt.vm.liveProcessCount == 0)
    rt.stop()
}

/// The budget bound: an infinite loop at normal priority on the main
/// worker never makes a turn overrun its budget by more than 0.2 ms, except
/// across a stop (whose time the turn reports separately). Background
/// workers allocate so that stops happen during turns.
@Test func aTurnOverrunsItsBudgetByAtMostAFifthOfAMillisecond() throws {
    let rt = try Runtime(hogSrc + churnSrc, background: 3, heapBlocks: 256, pollEvery: 1024)
    let hog = rt.spawn("hog", priority: Priority.normal, main: true)
    for _ in 0..<2 { rt.spawn("churn:", [int(1 << 40)]) }
    var overruns: [Double] = [], cpuOverruns: [Double] = []
    var stopped = 0
    let budget: UInt64 = 1_000_000
    for _ in 0..<300 {
        let st = rt.vm.runMain(budgetNs: budget)
        if st.parkNs > 0 || st.stopNs > 0 || st.enterWaitNs > 1000 { stopped += 1 }
        overruns.append(Double(Int64(bitPattern: st.ns &- st.pausedNs &- budget)) / 1e6)
        // Module 4: a parked main worker copies in a scavenge's parallel
        // phase (until ADR 0008 takes it off the pause): CPU, but the
        // stop's, not the turn's.
        cpuOverruns.append(Double(Int64(bitPattern: st.cpuNs &- st.collectorNs &- budget)) / 1e6)
        usleep(500)
    }
    overruns.sort()
    cpuOverruns.sort()
    func q(_ a: [Double], _ f: Double) -> Double { a[min(a.count - 1, Int(Double(a.count) * f))] }
    print("turn overrun ms wall p50=\(q(overruns, 0.5)) p99=\(q(overruns, 0.99)) max=\(overruns.last!) "
          + "cpu p50=\(q(cpuOverruns, 0.5)) p99=\(q(cpuOverruns, 0.99)) max=\(cpuOverruns.last!) "
          + "turnsWithAStop=\(stopped) collections=\(rt.image.om.counters.collections)")
    // The VM's share is bounded: CPU time past the budget, which excludes
    // stops (blocked) and the OS descheduling the thread (AGENTS.md:
    // maxima depend on it; the wall figures are reported, and alone on the
    // machine their max was 0.064 ms).
    // Under ThreadSanitizer the 1024 polls between clock reads take ten
    // times longer: reported, not asserted.
    #expect(underThreadSanitizer || cpuOverruns.last! <= 0.2)
    #expect(rt.vm.counters.preemptions >= 250)
    rt.vm.terminate(hog)
    rt.vm.terminateAll()
    rt.waitAllTerminated()
    rt.stop()
}
