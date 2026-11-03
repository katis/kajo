import Darwin
import Synchronization
import Testing
@testable import KajoVM

/// An image with the prelude, lib, processes and the test's source, and a VM
/// over it with `background` workers plus the main worker (index 0). With
/// `start: false` no thread runs: the test drives workers itself
/// (`runOneSlice`, `runMain`).
final class Runtime {
    let image: Image
    let vm: VM

    init(_ src: String, background: Int, heapBlocks: Int = 2048, entries: Int = 1 << 20, sliceMs: Double = 5,
         pollEvery: Int = 64, start: Bool = true, stress: StressFlags = [], verify: Bool = true, pinsForGood: Bool = true,
         configure: (inout VMConfig) -> Void = { _ in }, switches: TestSwitches = TestSwitches(),
         before: (Image) -> Void = { _ in }) throws {
        var vc = VMConfig()
        vc.backgroundWorkers = background
        vc.sliceNs = UInt64(sliceMs * 1e6)
        vc.pollEvery = pollEvery
        vc.verifyStops = true  // the stop and schedule verifiers, in release builds too
        configure(&vc)
        var c = ObjectMemoryConfig()
        c.heapBytes = heapBlocks * BlockHeap.blockBytes
        c.reserveBytes = vc.nursery.reserveBytes(workers: background + 2)
        c.nurseryRegionBytes = vc.nursery.regionBytes(workers: background + 2)
        c.entryCapacity = entries
        c.entryChunk = 256
        c.stress = stress
        c.verify = verify
        c.onVerifyFailure = .record
        c.testSwitches = switches
        image = try Image(memory: ObjectMemory(c), pinsForGood: pinsForGood)
        before(image)
        try image.load(["prelude", "lib", "processes", "nursery"].map { (file: "\($0).kasm", text: kernel($0)) }
                       + [(file: "test.kasm", text: src)])
        vm = VM(image: image, config: vc)
        if start { vm.start() }
    }

    func start() { vm.start() }

    /// `nil selector args` as a new Process, rooted for the test.
    @discardableResult
    func spawn(_ selector: String, _ args: [Oop] = [], priority: Int = Priority.normal, main: Bool = false,
               exit: Oop = .none) -> Oop {
        guard let p = vm.spawn(receiver: image.nilObject, selector: selector, arguments: args, priority: priority,
                               main: main, exit: exit) else {
            Issue.record("spawn \(selector) failed")
            return .none
        }
        return p
    }

    /// The SmallInteger a terminated Process answered.
    func result(_ p: Oop) -> Int64 {
        let v = vm.result(of: p)
        guard v.isSmallInteger else {
            Issue.record("result \(v) is not a SmallInteger (error: \(String(describing: vm.error(of: p))))")
            return Int64.min
        }
        return v.smallIntegerValue
    }

    func global(_ i: Int) -> Oop { vm.global(i) }
    func state(_ p: Oop) -> ProcessState { vm.state(of: p) }

    /// Wait until every Process has terminated (a test-side poll, so a hang
    /// is a failure, not a stuck suite).
    @discardableResult
    func waitAllTerminated(_ seconds: Double = 60) -> Bool {
        let ok = eventually(seconds) { vm.liveProcessCount == 0 }
        if !ok { Issue.record("\(vm.liveProcessCount) Processes still live") }
        return ok
    }

    /// Joins the workers, checks the heap, and releases everything.
    func stop(verifyHeap: Bool = true) {
        vm.shutdown()
        if verifyHeap {
            image.om.retireAllContexts()  // the verifiers read blocks' used bytes
            let reports = image.om.verifyHeap() + image.om.verifyFreeLists()
            #expect(reports == [], "\(reports.prefix(3))")
            #expect(image.om.counters.verifierFailures == 0, "\(image.om.verifierReports.prefix(3))")
        }
        vm.destroy()
        image.destroy()
    }
}

/// The suite runs under ThreadSanitizer as a gate; a few timing bounds and
/// seed counts depend on it.
let underThreadSanitizer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") != nil

func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// Wait (with a timeout) until `cond` holds.
func eventually(_ seconds: Double = 10, _ cond: () -> Bool) -> Bool {
    let end = now() + UInt64(seconds * 1e9)
    while now() < end {
        if cond() { return true }
        usleep(500)
    }
    return cond()
}


/// `nil log: x` appends x to the Array in global 3, using global 4 as the
/// fill count.
let logSrc = """
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

func logValues(_ rt: Runtime) -> [Int64] {
    let arr = rt.global(3)
    let n = Int(rt.global(4).smallIntegerValue)
    return rt.vm.inspect { om in (0..<n).map { om.load(arr, $0).smallIntegerValue } }
}

/// Minimal joinable thread for tests: not a VM worker.
final class TestThread: @unchecked Sendable {
    var tid: pthread_t? = nil
    let body: () -> Void
    init(_ body: @escaping () -> Void) {
        self.body = body
        pthread_create(&tid, nil, { arg in
            Unmanaged<TestThread>.fromOpaque(arg).takeUnretainedValue().body()
            return nil
        }, Unmanaged.passUnretained(self).toOpaque())
    }
    func join() { pthread_join(tid!, nil) }
}
