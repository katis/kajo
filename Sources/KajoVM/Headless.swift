import Darwin

/// The VM's public surface for headless runs (`kajo run`): load kasm files
/// into a fresh image and send `run:of:` to nil, as the experiments' bench
/// drivers did. Everything behind it is internal.
public enum Headless {
    public struct Options: Sendable {
        /// Heap reservation; the object memory commits what it touches.
        public var heapMiB = 1024
        public var entries = 1 << 24
        /// `KAJO_STRESS` syntax: `every`, `oneblock`, `tiny`, `all`.
        public var stress = ""
        public var verify = false
        /// Background workers; one Process per worker runs `run: i of: n`.
        public var workers = 1
        public var stackWords = 1 << 16
        /// Module 3's stress flags: `preempt`, `stop`.
        public var vmStress = ""
        /// 0: no background time slice (kernel cost isolation).
        public var sliceMs = 5.0
        /// Module 4: nursery per worker in KiB (0: none, every object old),
        /// one survivor half in KiB (0: an eighth), the age N.
        public var nurseryKB = 4096
        public var survivorKB = 0
        public var age = 2
        /// Module 4's stress flags: `tinynursery`, `promoteall`, `scavenge`.
        public var nurseryStress = ""
        /// Module 5: `cm` (concurrent marking, the default with a nursery)
        /// or `stw` (module 1's full collections only: the oracle).
        public var gc = "cm"
        /// Module 5's stress flags: `cycle`, `alwayson`, `neverapply`.
        public var markingStress = ""
        /// Cycle trigger: occupancy floor (fraction of the soft limit) and
        /// the predictor's safety factor (0: off).
        public var floor = 0.6
        public var safetyFactor = 2.0
        /// The marker is raised to user-initiated below this headroom (0:
        /// always utility, above 1: always user-initiated).
        public var escalateBelow = 0.25

        public init() {}
    }

    public struct Outcome: Sendable {
        /// The SmallInteger `run:of:` answered, or the failure.
        public let checksum: Result<Int64, Failure>
        /// Wall time of the run, load excluded.
        public let milliseconds: Double
        /// Interpreter, object memory and scheduler counters, in a stable order.
        public let counters: [(name: String, value: UInt64)]
        /// Per-worker QoS, stop percentiles with the slowest participant.
        public let report: [(name: String, value: String)]
    }

    public enum Failure: Error, CustomStringConvertible, Sendable {
        case load(String)
        case vm(VMError)
        case notAnInteger(String)
        case unsupported(String)

        public var description: String {
            switch self {
            case .load(let s): "load error: \(s)"
            case .vm(let e): "error: \(e)"
            case .notAnInteger(let s): "run:of: answered \(s), not a SmallInteger"
            case .unsupported(let s): s
            }
        }
    }

    /// Load `files` (path, text) in order and run `nil run: 0 of: workers`.
    public static func run(_ files: [(path: String, text: String)], options: Options = Options()) -> Outcome {
        func failed(_ f: Failure) -> Outcome { Outcome(checksum: .failure(f), milliseconds: 0, counters: [], report: []) }
        if options.workers < 1 || options.workers > 255 { return failed(.unsupported("--workers: 1 to 255")) }
        var vc = VMConfig()
        vc.backgroundWorkers = options.workers
        vc.stackWords = options.stackWords
        vc.stress = VMStress(parsing: options.vmStress)
        vc.sliceNs = UInt64(options.sliceMs * 1e6)
        vc.nursery.bytes = options.nurseryKB << 10
        vc.nursery.survivorBytes = options.survivorKB << 10
        vc.nursery.age = options.age
        vc.nursery.stress = NurseryStress(parsing: options.nurseryStress)
        guard options.gc == "cm" || options.gc == "stw" else { return failed(.unsupported("--gc: cm or stw")) }
        vc.marking.enabled = options.gc == "cm"
        vc.marking.stress = MarkingStress(parsing: options.markingStress)
        vc.marking.floor = options.floor
        vc.marking.safetyFactor = options.safetyFactor
        vc.marking.escalateBelow = options.escalateBelow

        if let problem = vc.nursery.validate(workers: options.workers + 2) { return failed(.unsupported("nursery: \(problem)")) }
        var config = ObjectMemoryConfig()
        config.heapBytes = options.heapMiB << 20
        config.reserveBytes = vc.nursery.reserveBytes(workers: options.workers + 2)
        config.entryCapacity = options.entries
        config.stress = StressFlags(parsing: options.stress)
        config.verify = options.verify
        config.onVerifyFailure = .trap
        let image: Image
        do {
            image = try Image(memory: ObjectMemory(config))
        } catch let e as LoadError {
            return failed(.load("\(e)"))
        } catch {
            return failed(.load("\(error)"))
        }
        defer { image.destroy() }
        do {
            try image.load(files.map { (file: $0.path, text: $0.text) })
        } catch {
            return failed(.load("\(error)"))
        }
        let vm = VM(image: image, config: vc)
        defer {
            vm.shutdown()
            vm.destroy()
        }
        vm.start()
        let n = options.workers
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var processes: [Oop] = []
        for i in 0..<n {
            guard let p = vm.spawn(receiver: image.nilObject, selector: "run:of:",
                                   arguments: [Oop(smallInteger: Int64(i)), Oop(smallInteger: Int64(n))]) else {
                return failed(.unsupported("no method UndefinedObject>>run:of:"))
            }
            processes.append(p)
        }
        vm.waitUntilAllTerminated()
        let ms = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6
        vm.shutdown()
        var sum: Int64 = 0
        var checksum: Result<Int64, Failure> = .success(0)
        for p in processes {
            if let e = vm.error(of: p) { checksum = .failure(.vm(e)); break }
            let v = vm.result(of: p)
            guard v.isSmallInteger else { checksum = .failure(.notAnInteger("\(v)")); break }
            sum = sum &+ v.smallIntegerValue
            checksum = .success(sum)
        }
        let c = vm.interpreterCounters, m = image.om.counters, v = vm.counters
        let stops = vm.stops
        let pauses = stops.map(\.pauseNs).sorted()
        func pct(_ q: Double) -> String {
            unsafe pauses.isEmpty ? "-" : String(format: "%.3f", Double(pauses[min(pauses.count - 1, Int(Double(pauses.count) * q))]) / 1e6)
        }
        let worst = stops.max { $0.pauseNs < $1.pauseNs }
        let qos = (1...n).map { "\(vm.workerQoS($0).rawValue)" }.joined(separator: ",")
        var report: [(String, String)] = [
            ("qos", qos), ("stops", "\(stops.count)"), ("pauseP50ms", pct(0.5)), ("pauseP99ms", pct(0.99)),
            ("pauseMaxMs", pauses.last.map { unsafe String(format: "%.3f", Double($0) / 1e6) } ?? "-"),
            ("slowestParticipant", worst.map { "\($0.slowest)" } ?? "-"),
        ]
        report += nurseryReport(vm, stops: stops, ms: ms)
        report += markingReport(vm, stops: stops)
        return Outcome(checksum: checksum, milliseconds: ms, counters: [
            ("sends", c.sends), ("cacheMisses", c.cacheMisses), ("cacheFlushes", c.cacheFlushes),
            ("primitiveCalls", c.primitiveCalls), ("primitiveFailures", c.primitiveFailures),
            ("specialSendFallbacks", c.specialSendFallbacks), ("errors", c.errors),
            ("safepointPolls", c.safepointPolls), ("collectionsTriggered", c.collectionsTriggered),
            ("collections", m.collections), ("compactions", m.compactions), ("allocations", m.allocations),
            ("allocatedBytes", m.allocatedBytes), ("weakSlotsNiled", m.weakSlotsNiled), ("ephemeronsQueued", m.ephemeronsQueued),
        ] + v.named.filter { ["slices", "preemptions", "stops", "schedLocks", "schedContended", "schedWaitNs",
                              "parkNs", "enterWaitNs", "stopNs", "timeToSafepointNs", "processErrors"].contains($0.name) },
        report: report)
    }
}

/// Module 4's line: scavenge pauses (p50, p99, max and the slowest
/// participant of the longest), promotion, survival, overflow, full
/// collections, the copy rate per participant, the barrier's slow path.
func nurseryReport(_ vm: VM, stops: [StopRecord], ms: Double) -> [(String, String)] {
    guard vm.hasNursery else { return [("nursery", "off")] }
    let c = vm.nurseryCounters
    let log = vm.scavengeLog
    let scav = stops.filter { $0.kind == .scavenge }
    let fulls = stops.filter { $0.kind == .full }
    let p = scav.map(\.pauseNs).sorted()
    func f(_ v: Double) -> String { unsafe String(format: "%.3f", v) }
    func pct(_ q: Double) -> String { p.isEmpty ? "-" : f(Double(p[min(p.count - 1, Int(Double(p.count) * q))]) / 1e6) }
    let worst = scav.max { $0.pauseNs < $1.pauseNs }
    let mb = { (b: UInt64) in f(Double(b) / 1e6) }
    var copied: UInt64 = 0, busy: UInt64 = 0, parts = 0
    for r in log {
        copied &+= r.copiedBytesPerParticipant.reduce(0, &+)
        busy &+= r.busyNsPerParticipant.reduce(0, &+)
        parts += r.participants
    }
    let rate = busy == 0 ? "-" : f(Double(copied) / Double(busy) * 1e3)  // MB/s per participant
    let sweeps = log.map(\.maxSweepNs).sorted()
    let sweepP50 = sweeps.isEmpty ? "-" : f(Double(sweeps[sweeps.count / 2]) / 1e6)
    let ttsp = scav.map(\.timeToSafepointNs).sorted()
    let ttspP50 = ttsp.isEmpty ? "-" : f(Double(ttsp[ttsp.count / 2]) / 1e6)
    let fullMax = fulls.map(\.pauseNs).max().map { f(Double($0) / 1e6) } ?? "-"
    return [
        ("scavenges", "\(c.scavenges)"), ("scavP50ms", pct(0.5)), ("scavP99ms", pct(0.99)),
        ("scavMaxMs", p.last.map { f(Double($0) / 1e6) } ?? "-"), ("scavSlowest", worst.map { "\($0.slowest)" } ?? "-"),
        ("participantsMean", log.isEmpty ? "-" : f(Double(parts) / Double(log.count))),
        ("promotedMB", mb(c.promotedBytes)), ("promotedMBs", ms > 0 ? f(Double(c.promotedBytes) / 1e3 / ms) : "-"),
        ("survivedMB", mb(c.survivedBytes)), ("overflowMB", mb(c.overflowBytes)),
        ("fullCollections", "\(fulls.count)"), ("fullMaxMs", fullMax), ("fullRequested", "\(c.fullCollectionsRequested)"),
        ("copyMBsPerParticipant", rate), ("sweepP50ms", sweepP50), ("ttspP50ms", ttspP50), ("youngAllocations", "\(c.youngAllocations)"),
        ("largeAllocations", "\(c.largeAllocations)"), ("barrierSlow", "\(c.barrierSlowCalls)"),
        ("remHolders", "\(c.rememberedHolders)"), ("entriesFreed", "\(c.entriesFreed)"),
    ]
}

/// Module 5's line: cycles and what started them, fallbacks (a provisioning
/// failure, by the phase they found) and aborts, the final mark's pause
/// (p50, p99, max, its time to safepoint), the initial mark's addition to
/// its scavenge, the apply, marker CPU and wall time per cycle, floating
/// garbage, the SATB volume, the QoS the marker ran at per cycle and its
/// escalations, the promotion rate and predicted time to fill at the last
/// trigger decision, and the verifier.
func markingReport(_ vm: VM, stops: [StopRecord]) -> [(String, String)] {
    guard vm.hasMarking else { return [("gc", "stw")] }
    let c = vm.markingCounters
    let log = vm.cycleLog
    func f(_ v: Double) -> String { unsafe String(format: "%.3f", v) }
    func ms(_ ns: UInt64) -> String { f(Double(ns) / 1e6) }
    func pct(_ xs: [UInt64], _ q: Double) -> String {
        let s = xs.sorted()
        return s.isEmpty ? "-" : ms(s[min(s.count - 1, Int(Double(s.count) * q))])
    }
    let finals = stops.filter { $0.kind == .finalMark }.map(\.pauseNs)
    let ttsp = stops.filter { $0.kind == .finalMark }.map(\.timeToSafepointNs)
    let done = log.filter(\.completed)
    let im = log.map { $0.snapshotNs &+ $0.rootsNs &+ $0.survivorsNs }
    let mean = { (xs: [UInt64]) -> String in xs.isEmpty ? "-" : ms(xs.reduce(0, &+) / UInt64(xs.count)) }
    var qos: [UInt32: Int] = [:]
    for r in done { qos[r.markerQoS, default: 0] += 1 }
    let qosList = qos.keys.sorted().map { "\($0)x\(qos[$0]!)" }.joined(separator: ",")
    return [
        ("gc", "cm"), ("cycles", "\(c.cycles)"), ("cyclesDone", "\(c.cyclesCompleted)"),
        ("byFloor", "\(c.cyclesByFloor)"), ("byPredictor", "\(c.cyclesByPredictor)"), ("byEntries", "\(c.cyclesByEntries)"), ("forced", "\(c.cyclesForced)"),
        ("fallbacks", "\(c.fallbacks)"), ("fallbacksIdle", "\(c.fallbacksIdle)"), ("fallbacksMarking", "\(c.fallbacksMarking)"),
        ("fallbacksSweeping", "\(c.fallbacksSweeping)"), ("fallbacksVerifier", "\(c.fallbacksVerifier)"),
        ("aborts", "\(c.aborts)"), ("sweepsInPause", "\(c.sweepsFinishedInPause)"),
        ("finalP50ms", pct(finals, 0.5)), ("finalP99ms", pct(finals, 0.99)), ("finalMaxMs", finals.max().map(ms) ?? "-"),
        ("finalTtspP50ms", pct(ttsp, 0.5)), ("finalDrainP50ms", pct(done.map(\.drainNs), 0.5)),
        ("imAddP50ms", pct(im, 0.5)), ("imAddMaxMs", im.max().map(ms) ?? "-"),
        ("applyP50ms", pct(done.map(\.applyNs), 0.5)), ("applyStops", "\(stops.filter { $0.kind == .apply }.count)"),
        ("markCpuMsPerCycle", mean(done.map(\.markCpuNs))), ("markWallMsPerCycle", mean(done.map(\.markWallNs))),
        ("sweepMsPerCycle", mean(done.map(\.sweepNs))), ("cycleMsMean", mean(done.map(\.durationNs))),
        ("markedMBPerCycle", done.isEmpty ? "-" : f(Double(done.map(\.markedBytes).reduce(0, &+)) / Double(done.count) / 1e6)),
        ("freedMB", f(Double(done.map(\.bytesFreed).reduce(0, &+)) / 1e6)),
        ("floatingMB", f(Double(c.floatingBytes) / 1e6)), ("satbPushed", "\(c.satbPushed)"), ("satbBuffers", "\(c.satbBuffers)"),
        ("markerQoS", qosList.isEmpty ? "-" : qosList), ("qosEscalations", "\(c.qosEscalations)"), ("qosLowerings", "\(c.qosLowerings)"),
        ("promotionMBs", f(c.lastPromotionBytesPerSecond / 1e6)), ("predictedFillMs", ms(c.lastPredictedFillNs)),
        ("markVerifies", "\(c.verifierRuns)"), ("missed", "\(c.missed)"),
    ]
}
