// The power scenario's VM side (SPEC.md "Part 2", "Part 3"), without UI so
// the tests can drive it on the Mac: a VMR Runtime over power.kasm with an
// old heap, one Smalltalk frame at a time on the main worker, and the VM's
// threads identified for per-thread CPU accounting.
//
// Frames: `frame(points:mutation:percent:)` forks `nil pwFrame: arg` as a
// main-affine Process and runs it with `runMain`, as a shell turn would;
// `emptyFrame()` enters the VM and leaves with nothing to run.

import Darwin
import Kasm
import PowerKit
import VMR

/// Body bytes of one PPoint (backref word + 2 slots); its table entry is
/// another 16 bytes outside the nursery.
public let pointBodyBytes = 24
public let pointEntryBytes = 16

public struct SessionConfig: Sendable {
    public var oldheapMB = 200
    public var heapMB = 768
    public var nurseryKB = 4096
    public var background = 0
    /// Groups of the old heap replaced every this many mutation iterations
    /// (oldheap.kasm's replaceEvery).
    public var replaceEvery = 256
    public init() {}
}

/// The VM's own threads, by thread id, in creation order (Runtime.start:
/// the young collector if offload, then the markers, then background workers).
public struct VMThreads: Sendable {
    public var collector: [UInt64] = []
    public var markers: [UInt64] = []
    public var background: [UInt64] = []
    public var unexpected: [UInt64] = []
    public var all: [UInt64] { collector + markers + background + unexpected }
}

public final class Session {
    public let rt: Runtime
    public var vm: VMRef { rt.vm }
    public let config: SessionConfig
    public let threads: VMThreads
    public private(set) var pointsAllocated = 0
    public private(set) var mutationIters = 0
    public private(set) var frames = 0
    public let setupMs: Double
    private let frameSel: Oop

    /// Builds the image, starts the Runtime (collector configuration from
    /// the environment: KAJO_GC, KAJO_YOUNG, KAJO_YC_QOS, KAJO_CM_QOS,
    /// KAJO_AGE), builds the old heap on the main worker and promotes it
    /// with one full collection.
    public init(_ c: SessionConfig, buildOldHeap: Bool = true) throws {
        config = c
        kernelFlavor = .concurrentYoung
        let src = try powerSources(oldheapMB: max(1, c.oldheapMB), replaceEvery: c.replaceEvery)
        let img = try Image.fromSources(src, heapSize: c.heapMB << 20, nurseryBytes: c.nurseryKB << 10)
        var cm = cmConfigFromEnv()
        cm.verify = false
        let y = ycConfigFromEnv()
        let before = ThreadCPU.snapshot()
        rt = Runtime(img, background: c.background, config: cm, young: y)
        let after = ThreadCPU.snapshot()
        var t = VMThreads()
        var fresh = ThreadCPU.newThreads(before, after)
        if y.mode == YoungMode.offload, !fresh.isEmpty { t.collector = [fresh.removeFirst()] }
        if cm.concurrent && c.nurseryKB > 0 {
            let m = min(max(1, min(2, cm.markers)), fresh.count)
            t.markers = Array(fresh.prefix(m)); fresh.removeFirst(m)
        }
        let b = min(c.background, fresh.count)
        t.background = Array(fresh.prefix(b)); fresh.removeFirst(b)
        t.unexpected = fresh
        threads = t
        frameSel = rt.symbol("pwFrame:")
        let t0 = now()
        if buildOldHeap {
            spawn(rt.vm, rt.vm.pointee.nilObj, rt.symbol("pwSetup:"), mkInt(Int64(c.oldheapMB)), priority: uiPriority, main: true)
            Session.runToCompletion(rt.vm)
            hostCollect(rt.vm, full: true)
        }
        setupMs = Double(now() &- t0) / 1e6
    }

    /// Run main-affine Processes until none is ready (setup only: no budget).
    private static func runToCompletion(_ vm: VMRef) {
        while true {
            let st = runMain(vm, budgetNs: 10_000_000_000)
            if st.slices == 0 { break }
        }
    }

    /// One frame: `points` PPoints with `percent` kept, then `mutation`
    /// oldheap iterations. Answers the turn's statistics.
    @discardableResult
    public func frame(points: Int, mutation: Int, percent: Int, budgetNs: UInt64 = 1_000_000_000) -> TurnStats {
        precondition(mutation >= 0 && mutation < 4096 && percent >= 0 && percent < 256)
        let arg = Int64(points) * 1_048_576 + Int64(mutation) * 256 + Int64(percent)
        spawn(vm, vm.pointee.nilObj, frameSel, mkInt(arg), priority: uiPriority, main: true)
        var st = runMain(vm, budgetNs: budgetNs)
        // A frame preempted at the budget finishes in further turns (counted).
        while liveProcessCount(vm) > 0 {
            let more = runMain(vm, budgetNs: budgetNs)
            st.ns &+= more.ns; st.parkedNs &+= more.parkedNs; st.slices += more.slices
            st.enterWaitNs &+= more.enterWaitNs; st.leaveWaitNs &+= more.leaveWaitNs
            if more.slices == 0 { break }
        }
        pointsAllocated += points
        mutationIters += mutation
        frames += 1
        return st
    }

    /// Enter the VM, run nothing, leave (Part 3's empty frame).
    @discardableResult
    public func emptyFrame() -> TurnStats {
        frames += 1
        return runMain(vm, budgetNs: 1_000_000)
    }

    /// SmallInteger value of global `g` (1-based), read from the host. Only
    /// for globals that hold SmallIntegers (6..10 in power.kasm: 7, 8, 10).
    public func intGlobal(_ g: Int) -> Int64 {
        let v = vm.pointee.globals[g - 1]
        return isInt(v) ? intVal(v) : -1
    }

    /// Old space in use, bytes.
    public var oldBytes: Int { vm.pointee.heap.blocksInUse() * blockSize }

    public func stop() { rt.stop() }
}
