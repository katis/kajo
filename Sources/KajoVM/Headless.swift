import Darwin
import Foundation

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
        /// Module 6: concurrent relocation (`on`, `off`), its stress flags
        /// (`everyblock`, `everycycle`), the sparse-block threshold and the
        /// to-space cap (fractions).
        public var relocation = "on"
        public var relocationStress = ""
        public var relocationThreshold = 0.5
        public var relocationCap = 0.5
        /// Sample old space in use every this many ms (0: never); the
        /// samples are in the report (`oldSamples`).
        public var sampleMs = 0
        /// Module 7: how nurseries are collected (`stw`, `local`,
        /// `offload`: the policy) and its stress flags (`everyhalf`,
        /// `everypoll`).
        public var young = "offload"
        public var youngStress = ""
        /// Module 7's headless scenarios: for this many ms (0: none; -1:
        /// while the background Processes run) the
        /// calling thread acts as the shell's main thread, one frame every
        /// `frameMs`: a main-affine `nil mainTick: mainAlloc work: mainWork`
        /// (mainload.kasm) run in turns of at most a frame.
        public var mainMs = 0
        public var mainAlloc = 0
        public var mainWork = 0
        public var frameMs = 1000.0 / 120.0
        /// Records each collector log keeps (`VMConfig.logCapacity`): the
        /// default holds every record of a measurement run; an app that
        /// runs for days takes `appLogCapacity` (the shells' demo and
        /// developer modes; `logs=` overrides).
        public var logCapacity = 1 << 16
        public static let appLogCapacity = 4096
        /// Module 8b: where the kernel's events go (NDJSON objects, on the
        /// emitting VM thread); nil drops them.
        public var events: (@Sendable ([UInt8]) -> Void)? = nil
        /// Module 8c: save the image with every Process in it at this slow
        /// poll of the run (0: never), to `snapshotTo`.
        public var snapshotAt = 0
        public var snapshotTo: String? = nil
        /// Module 8e: the directory Smalltalk's file primitives may read
        /// and write under (`--sources`); nil, they fail.
        public var sourcesDirectory: String? = nil

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
        let vc: VMConfig, config: ObjectMemoryConfig
        switch configs(options) {
        case .success(let c): (vc, config) = c
        case .failure(let f): return failed(f)
        }
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
        return run(image, vc, options)
    }

    /// Module 8b: load an image and run its entry point the same way: the
    /// object the image names (special object 7, `Smalltalk` in the kernel)
    /// is sent `setup: workers`, then `run: i of: workers` on each worker.
    public static func run(image bytes: [UInt8], options: Options = Options()) -> Outcome {
        func failed(_ f: Failure) -> Outcome { Outcome(checksum: .failure(f), milliseconds: 0, counters: [], report: []) }
        let vc: VMConfig, config: ObjectMemoryConfig
        switch configs(options) {
        case .success(let c): (vc, config) = c
        case .failure(let f): return failed(f)
        }
        let image: Image
        do { image = try Image.load(image: bytes, config: config) } catch { return failed(.load("\(error)")) }
        defer { image.destroy() }
        let o = run(image, vc, options)
        // Module 8d: the loader's report of the image's kind.
        return Outcome(checksum: o.checksum, milliseconds: o.milliseconds, counters: o.counters,
                       report: o.report + [("image", image.isRelease ? "release" : "development")])
    }

    /// Module 8d: whether an image's header marks it a release image (nil
    /// when the bytes are not an image of this version). The loader reads
    /// the same word; nothing in Smalltalk can change it.
    public static func isReleaseImage(_ bytes: [UInt8]) -> Bool? {
        guard isImage(bytes), bytes.count >= 8 * ImageFile.headerWords else { return nil }
        func word(_ i: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[8 * i + $1]) << (8 * UInt64($1)) } }
        guard word(1) == ImageFile.version else { return nil }
        return word(5) & ImageFile.releaseFlag != 0
    }

    /// Module 8d: `kajo seal`. Load the image (all of the loader's checks),
    /// mark it a release image and save it: Smalltalk can no longer make,
    /// install or remove methods in it. Nothing clears the mark; a release
    /// image is rebuilt from its sources, not unsealed.
    public static func seal(image bytes: [UInt8], options: Options = Options()) -> Result<[UInt8], Failure> {
        let config: ObjectMemoryConfig
        switch configs(options) {
        case .success(let c): config = c.1
        case .failure(let f): return .failure(f)
        }
        let image: Image
        do { image = try Image.load(image: bytes, config: config) } catch { return .failure(.load("\(error)")) }
        defer { image.destroy() }
        image.seal()
        do { return .success(try image.saveImage()) } catch { return .failure(.load("\(error)")) }
    }

    /// Module 8b: `kajo test`. Load an image, send its entry point `test:`
    /// with the arguments (Strings), and hand every event the kernel emits
    /// (NDJSON objects, primitive 140) to `events` as it happens, on the
    /// emitting VM thread; then one `gc` event per collection pause, stamped
    /// with when it began, and a `gc` summary. Answers what `test:`
    /// answered (the number of failed and errored tests).
    public static func test(image bytes: [UInt8], arguments: [String], options: Options = Options(),
                            events: @escaping @Sendable ([UInt8]) -> Void) -> Result<Int64, Failure> {
        let vc: VMConfig, config: ObjectMemoryConfig
        switch configs(options) {
        case .success(let c): (vc, config) = c
        case .failure(let f): return .failure(f)
        }
        let image: Image
        do { image = try Image.load(image: bytes, config: config) } catch { return .failure(.load("\(error)")) }
        defer { image.destroy() }
        guard image.entryPoint != image.nilObject else { return .failure(.unsupported("the image names no entry point")) }
        // Module 8c (provisional, the owner's question 2): a test run starts
        // from the entry point alone.
        guard !image.hasSavedProcesses else {
            return .failure(.unsupported("the image holds saved Processes; kajo test needs an image without (kajo run resumes them)"))
        }
        let sink = EventSink(events)
        let vm = VM(image: image, config: vc)
        var hooks = unsafe vm.hooks
        unsafe hooks.context = Unmanaged.passUnretained(sink).toOpaque()
        unsafe hooks.event = eventHook
        unsafe vm.hooks = hooks
        defer {
            vm.shutdown()
            vm.destroy()
            withExtendedLifetime(sink) {}
        }
        vm.start()
        let args = vm.newStringArray(arguments)
        guard let p = vm.spawn(receiver: image.entryPoint, selector: "test:", arguments: [args]) else {
            return .failure(.unsupported("the entry point does not understand test:"))
        }
        vm.waitUntilTerminated(p)
        let error = vm.error(of: p)
        let answer = vm.result(of: p)
        vm.terminateAll()
        vm.waitUntilAllTerminated()
        // gc events: the pauses, stamped with their start on the wall clock.
        let offsetNs = Int64(clock_gettime_nsec_np(CLOCK_REALTIME)) - Int64(nanoseconds())
        var scavenges = 0, full = 0, other = 0
        for st in vm.stops where st.kind != .other {
            switch st.kind {
            case .scavenge: scavenges += 1
            case .full: full += 1
            default: other += 1
            }
            let ts = (Int64(st.atNs) + offsetNs) / 1000
            events(Array("{\"v\":1,\"kind\":\"gc\",\"ts\":\(ts),\"collection\":\"\(st.kind)\",\"pauseUs\":\(st.pauseNs / 1000),\"ttspUs\":\(st.timeToSafepointNs / 1000),\"slowestWorker\":\(st.slowest)}".utf8))
        }
        let c = image.om.counters
        let ts = clock_gettime_nsec_np(CLOCK_REALTIME) / 1000
        events(Array("{\"v\":1,\"kind\":\"gc\",\"ts\":\(ts),\"collection\":\"summary\",\"pauses\":\(scavenges + full + other),\"scavenges\":\(scavenges),\"full\":\(full),\"collections\":\(c.collections),\"allocations\":\(c.allocations)}".utf8))
        if let error { return .failure(.vm(error)) }
        guard answer.isSmallInteger else { return .failure(.notAnInteger("\(answer)")) }
        return .success(answer.smallIntegerValue)
    }

    /// Whether these bytes start like an image file.
    public static func isImage(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 8 && (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[$1]) << (8 * UInt64($1)) } == ImageFile.magic
    }

    static func configs(_ options: Options) -> Result<(VMConfig, ObjectMemoryConfig), Failure> {
        if options.workers < 1 || options.workers > 255 { return .failure(.unsupported("--workers: 1 to 255")) }
        var vc = VMConfig()
        vc.backgroundWorkers = options.workers
        vc.stackWords = options.stackWords
        vc.stress = VMStress(parsing: options.vmStress)
        vc.sliceNs = UInt64(options.sliceMs * 1e6)
        vc.nursery.bytes = options.nurseryKB << 10
        vc.nursery.survivorBytes = options.survivorKB << 10
        vc.nursery.age = options.age
        vc.nursery.stress = NurseryStress(parsing: options.nurseryStress)
        guard options.gc == "cm" || options.gc == "stw" else { return .failure(.unsupported("--gc: cm or stw")) }
        vc.marking.enabled = options.gc == "cm"
        vc.marking.stress = MarkingStress(parsing: options.markingStress)
        vc.marking.floor = options.floor
        vc.marking.safetyFactor = options.safetyFactor
        vc.marking.escalateBelow = options.escalateBelow
        guard options.relocation == "on" || options.relocation == "off" else { return .failure(.unsupported("--reloc: on or off")) }
        vc.relocation.enabled = options.relocation == "on"
        vc.relocation.stress = RelocationStress(parsing: options.relocationStress)
        vc.relocation.threshold = options.relocationThreshold
        vc.relocation.cap = options.relocationCap
        guard let mode = YoungMode(name: options.young) else { return .failure(.unsupported("--young: stw, local or offload")) }
        vc.young.mode = mode
        vc.young.stress = YoungStress(parsing: options.youngStress)
        vc.young.verify = options.verify
        vc.sourcesDirectory = options.sourcesDirectory
        guard options.logCapacity >= 1 else { return .failure(.unsupported("log capacity: at least 1")) }
        vc.logCapacity = options.logCapacity

        if let problem = vc.nursery.validate(workers: options.workers + 2) { return .failure(.unsupported("nursery: \(problem)")) }
        var config = ObjectMemoryConfig()
        config.heapBytes = options.heapMiB << 20
        config.reserveBytes = vc.nursery.reserveBytes(workers: options.workers + 2)
        config.nurseryRegionBytes = vc.nursery.regionBytes(workers: options.workers + 2)
        config.entryCapacity = options.entries
        config.stress = StressFlags(parsing: options.stress)
        config.verify = options.verify
        config.onVerifyFailure = .trap
        return .success((vc, config))
    }

    private static func run(_ image: Image, _ vc: VMConfig, _ options: Options) -> Outcome {
        func failed(_ f: Failure) -> Outcome { Outcome(checksum: .failure(f), milliseconds: 0, counters: [], report: []) }
        var vc = vc
        vc.snapshotAtPoll = options.snapshotAt
        if image.hasSavedProcesses { return resume(image, vc, options) }
        let vm = VM(image: image, config: vc)
        let sink = options.events.map { EventSink($0) }
        if let sink {
            var hooks = unsafe vm.hooks
            unsafe hooks.context = Unmanaged.passUnretained(sink).toOpaque()
            unsafe hooks.event = eventHook
            unsafe vm.hooks = hooks
        }
        defer { withExtendedLifetime(sink) {} }
        defer {
            vm.shutdown()
            vm.destroy()
        }
        vm.start()
        let n = options.workers
        // A kernel's shared state (`nil setup: workers`, when it has one).
        // An image built from the kernel names its entry point; kasm runs
        // start at nil.
        let entry = image.entryPoint == image.nilObject ? image.nilObject : image.entryPoint
        if let s = vm.spawn(receiver: entry, selector: "setup:", arguments: [Oop(smallInteger: Int64(n))]) {
            vm.waitUntilAllTerminated()
            vm.release(s)
        }
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var processes: [Oop] = []
        for i in 0..<n {
            guard let p = vm.spawn(receiver: entry, selector: "run:of:",
                                   arguments: [Oop(smallInteger: Int64(i)), Oop(smallInteger: Int64(n))]) else {
                return failed(.unsupported("no method UndefinedObject>>run:of:"))
            }
            processes.append(p)
        }
        var samples: [(ms: Double, mb: Double)] = []
        var main: MainLoad? = nil
        if options.mainMs != 0 {
            main = mainLoad(vm, image, options, workers: processes)
            if main == nil { return failed(.unsupported("--main-ms needs mainload.kasm (UndefinedObject>>mainTick:work:)")) }
        }
        if options.sampleMs > 0 {
            while vm.liveProcessCount > 0 {
                usleep(UInt32(options.sampleMs * 1000))
                let t = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6
                samples.append((t, Double(vm.inspect { $0.blocksInUse } * BlockHeap.blockBytes) / 1e6))
            }
        }
        vm.waitUntilAllTerminated()
        let ms = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6
        vm.shutdown()
        if let path = options.snapshotTo {
            guard let b = vm.takeSavedImages().first else { return failed(.unsupported("--snapshot-at \(options.snapshotAt): the run ended first")) }
            guard FileManager.default.createFile(atPath: path, contents: Data(b)) else { return failed(.unsupported("cannot write \(path)")) }
        }
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
        report += relocationReport(vm)
        report += youngReport(vm, ms: ms)
        if let main { report += main.report() }
        if !samples.isEmpty {
            report.append(("oldSamples", samples.map { unsafe String(format: "%.0f:%.1f", $0.ms, $0.mb) }.joined(separator: ",")))
        }
        return Outcome(checksum: checksum, milliseconds: ms, counters: [
            ("sends", c.sends), ("cacheMisses", c.cacheMisses), ("cacheFlushes", c.cacheFlushes),
            ("primitiveCalls", c.primitiveCalls), ("primitiveFailures", c.primitiveFailures),
            ("specialSendFallbacks", c.specialSendFallbacks), ("errors", c.errors),
            ("safepointPolls", c.safepointPolls), ("collectionsTriggered", c.collectionsTriggered),
            ("collections", m.collections), ("compactions", m.compactions), ("allocations", m.allocations),
            ("allocatedBytes", m.allocatedBytes), ("weakSlotsNiled", m.weakSlotsNiled), ("ephemeronsQueued", m.ephemeronsQueued),
        ] + v.named.filter { ["slices", "preemptions", "stops", "schedLocks", "schedContended", "schedWaitNs",
                              "parkNs", "enterWaitNs", "stopNs", "timeToSafepointNs", "processErrors",
                              "stopperQoSRaises"].contains($0.name) },
        report: report)
    }
}

extension Headless {
    /// Module 8c: `kajo run` of an image with saved Processes resumes them
    /// instead of sending the entry point, and runs until nothing can happen
    /// without the host (every Process ended, or waiting with no timer or
    /// signal outstanding; main-affine ones get turns on this thread). The
    /// checksum is the sum of what the resumed Processes that ended answered.
    static func resume(_ image: Image, _ vc: VMConfig, _ options: Options) -> Outcome {
        let vm = VM(image: image, config: vc)
        let sink = options.events.map { EventSink($0) }
        if let sink {
            var hooks = unsafe vm.hooks
            unsafe hooks.context = Unmanaged.passUnretained(sink).toOpaque()
            unsafe hooks.event = eventHook
            unsafe vm.hooks = hooks
        }
        defer { withExtendedLifetime(sink) {} }
        defer { vm.destroy() }
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        vm.start()
        var calm = 0
        while calm < 2 {
            if vm.liveProcessCount == 0 { break }
            if vm.runMain(budgetNs: 2_000_000).slices == 0 { usleep(10_000) }
            calm = vm.isQuiescent ? calm + 1 : 0
        }
        let ms = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6
        let waiting = vm.liveProcessCount
        vm.terminateAll()
        vm.waitUntilAllTerminated()
        vm.shutdown()
        var sum: Int64 = 0, ended = 0
        var checksum: Result<Int64, Failure> = .success(0)
        for p in vm.resumedProcesses {
            if let e = vm.error(of: p) { checksum = .failure(.vm(e)); break }
            let v = vm.result(of: p)
            if v.isSmallInteger { sum = sum &+ v.smallIntegerValue; ended += 1 }
            checksum = .success(sum)
        }
        if case .success = checksum, ended == 0 { checksum = .success(0) }
        let v = vm.counters
        return Outcome(checksum: checksum, milliseconds: ms, counters: v.named.filter {
            ["processesResumed", "slices", "preemptions", "stops", "snapshots"].contains($0.name)
        }, report: [("resumed", "\(vm.resumedProcesses.count)"), ("answered", "\(ended)"), ("leftWaiting", "\(waiting)")])
    }
}

/// Module 4's line: scavenge pauses (p50, p99, max and the slowest
/// participant of the longest), promotion, survival, overflow, full
/// collections, the copy rate per participant, the barrier's slow path.
func nurseryReport(_ vm: VM, stops: [StopRecord], ms: Double) -> [(String, String)] {
    guard vm.hasNursery else { return [("nursery", "off")] }
    let c = vm.nurseryCounters
    // Percentiles over the records the log kept, sums over every scavenge.
    let log = vm.scavengeLog
    let totals = vm.scavengeTotals
    let scav = stops.filter { $0.kind == .scavenge }
    let fulls = stops.filter { $0.kind == .full }
    let p = scav.map(\.pauseNs).sorted()
    func f(_ v: Double) -> String { unsafe String(format: "%.3f", v) }
    func pct(_ q: Double) -> String { p.isEmpty ? "-" : f(Double(p[min(p.count - 1, Int(Double(p.count) * q))]) / 1e6) }
    let worst = scav.max { $0.pauseNs < $1.pauseNs }
    let mb = { (b: UInt64) in f(Double(b) / 1e6) }
    let copied = totals.copiedBytes, busy = totals.busyNs
    let rate = busy == 0 ? "-" : f(Double(copied) / Double(busy) * 1e3)  // MB/s per participant
    let sweeps = log.map(\.maxSweepNs).sorted()
    let sweepP50 = sweeps.isEmpty ? "-" : f(Double(sweeps[sweeps.count / 2]) / 1e6)
    let ttsp = scav.map(\.timeToSafepointNs).sorted()
    let ttspP50 = ttsp.isEmpty ? "-" : f(Double(ttsp[ttsp.count / 2]) / 1e6)
    let fullMax = fulls.map(\.pauseNs).max().map { f(Double($0) / 1e6) } ?? "-"
    return [
        ("scavenges", "\(c.scavenges)"), ("scavP50ms", pct(0.5)), ("scavP99ms", pct(0.99)),
        ("scavMaxMs", p.last.map { f(Double($0) / 1e6) } ?? "-"), ("scavSlowest", worst.map { "\($0.slowest)" } ?? "-"),
        ("participantsMean", totals.scavenges == 0 ? "-" : f(Double(totals.participants) / Double(totals.scavenges))),
        ("promotedMB", mb(c.promotedBytes)), ("promotedMBs", ms > 0 ? f(Double(c.promotedBytes) / 1e3 / ms) : "-"),
        ("survivedMB", mb(c.survivedBytes)), ("overflowMB", mb(c.overflowBytes)),
        ("fullCollections", "\(fulls.count)"), ("fullMaxMs", fullMax), ("fullRequested", "\(c.fullCollectionsRequested)"),
        ("fullCompactions", "\(c.fullCompactions)"),
        ("reserveExhaustions", "\(vm.image.om.reserveExhaustions)"), ("exhaustedScavenges", "\(c.exhaustedScavenges)"),
        ("keptObjects", "\(c.keptObjects)"), ("keptMB", mb(c.keptBytes)), ("keptAcross", "\(c.keptMovedAcross)"),
        ("reclaimsAroundYoung", "\(c.reclaimsAroundYoung)"),
        ("copyMBsPerParticipant", rate), ("sweepP50ms", sweepP50), ("ttspP50ms", ttspP50), ("youngAllocations", "\(c.youngAllocations)"),
        ("largeAllocations", "\(c.largeAllocations)"), ("barrierSlow", "\(c.barrierSlowCalls)"),
        ("remHolders", "\(c.rememberedHolders)"), ("entriesFreed", "\(c.entriesFreed)"),
        ("scavLogDropped", "\(totals.dropped)"),
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
    // Percentiles and the QoS tally over the records the log kept; sums,
    // means and maxima over every cycle.
    let log = vm.cycleLog
    let totals = vm.cycleTotals
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
    let mean = { (sum: UInt64) -> String in totals.completed == 0 ? "-" : ms(sum / totals.completed) }
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
        ("imAddP50ms", pct(im, 0.5)), ("imAddMaxMs", totals.cycles == 0 ? "-" : ms(totals.imAddMaxNs)),
        ("imSnapshotP50ms", pct(log.map(\.snapshotNs), 0.5)), ("imRootsP50ms", pct(log.map(\.rootsNs), 0.5)),
        ("imSurvivorsP50ms", pct(log.map(\.survivorsNs), 0.5)),
        ("snapshotEntries", log.last.map { "\($0.snapshotEntries)" } ?? "-"),
        ("applyP50ms", pct(done.map(\.applyNs), 0.5)), ("applyStops", "\(stops.filter { $0.kind == .apply }.count)"),
        ("markCpuMsPerCycle", mean(totals.markCpuNs)), ("markWallMsPerCycle", mean(totals.markWallNs)),
        ("sweepMsPerCycle", mean(totals.sweepNs)), ("cycleMsMean", mean(totals.durationNs)),
        ("markedMBPerCycle", totals.completed == 0 ? "-" : f(Double(totals.markedBytes) / Double(totals.completed) / 1e6)),
        ("freedMB", f(Double(totals.bytesFreed) / 1e6)),
        ("floatingMB", f(Double(c.floatingBytes) / 1e6)), ("satbPushed", "\(c.satbPushed)"), ("satbBuffers", "\(c.satbBuffers)"),
        ("markerQoS", qosList.isEmpty ? "-" : qosList), ("qosEscalations", "\(c.qosEscalations)"), ("qosLowerings", "\(c.qosLowerings)"),
        ("promotionMBs", f(c.lastPromotionBytesPerSecond / 1e6)), ("predictedFillMs", ms(c.lastPredictedFillNs)),
        ("markVerifies", "\(c.verifierRuns)"), ("missed", "\(c.missed)"),
        ("cycleLogDropped", "\(totals.dropped)"),
        ("fallbacksEntries", "\(c.fallbacksEntries)"), ("fallbacksSoftLimit", "\(c.fallbacksSoftLimit)"),
        ("fallbacksOld", "\(c.fallbacksOldAllocation)"), ("fallbackLog", fallbackSummary(vm.fallbackLog)),
        ("sweepsForEntries", "\(c.sweepsFinishedForEntries)"), ("sweepsForOld", "\(c.sweepsFinishedForOld)"),
        ("sweepsInStopMs", ms(c.sweepsFinishedForEntriesNs)),
        ("triggersNotStarted", "\(vm.counters[.triggersNotStarted])"), ("largeTriggersUnrooted", "\(vm.counters[.largeTriggersUnrooted])"),
        ("qosRaisedCycles", "\(log.filter { $0.completed && $0.markerQoS == QOS_CLASS_USER_INITIATED.rawValue }.count)"),
    ]
}

/// Large bytes, part 2: each recorded fallback as
/// cause/phase/trigger/ms since the cycle started/ms since the last
/// apply/cycles started/swept percent/entries
/// used percent (high water)/pool runs/pending runs/old entries percent/
/// blocks percent of the soft limit/marker QoS/raise wanted/large failure,
/// separated by commas; "-" when none.
func fallbackSummary(_ rs: [FallbackRecord]) -> String {
    if rs.isEmpty { return "-" }
    func pc(_ a: Double, _ b: Double) -> String { b > 0 ? unsafe String(format: "%.1f", 100 * a / b) : "-" }
    return rs.map { r in
        let cause = ["soft", "entries", "other", "old"][Int(r.cause.rawValue)]
        let phase = ["idle", "marking", "sweeping", "swept"][Int(r.phase.rawValue)]
        let trig = r.trigger.map { ["floor", "entries", "predictor", "forced"][Int($0.rawValue)] } ?? "-"
        return [cause, phase, trig, unsafe String(format: "%.1f", Double(r.sinceCycleStartNs) / 1e6),
                unsafe String(format: "%.1f", Double(r.sinceLastApplyNs) / 1e6), "\(r.cyclesStarted)",
                unsafe String(format: "%.0f", r.sweptFraction * 100), pc(Double(r.highWater), Double(r.entryCapacity)),
                "\(r.poolRuns)", "\(r.pendingRuns)", pc(Double(r.oldEntries), Double(r.entryCapacity)),
                pc(Double(r.blocksInUse), Double(r.softLimitBlocks)), "\(r.markerQoS)", r.wantUserInitiated ? "1" : "0",
                "\(r.largeFailure)"].joined(separator: "/")
    }.joined(separator: ",")
}

/// Module 6's line: cycles that planned and selected a relocation, what
/// was selected (candidates, blocks, capped, bytes to move, expected
/// reclaim) and moved (objects, bytes, evacuated blocks), objects skipped
/// (pinned, hazarded), stores redone and spins (all workers and the main
/// worker), hazard slots taken, frame pins, pending blocks and the delay
/// from switch to free, blocks freed by epoch and at pauses, the
/// relocator's CPU and wall time, the verifier, and old space at the end
/// and its peak at a pause.
func relocationReport(_ vm: VM) -> [(String, String)] {
    let blockBytes = UInt64(BlockHeap.blockBytes)
    let endMB = Double(UInt64(vm.inspect { $0.blocksInUse }) &* blockBytes) / 1e6
    guard vm.hasRelocation else { return [("reloc", "off"), ("oldEndMB", unsafe String(format: "%.1f", endMB))] }
    let c = vm.relocationCounters
    // Cycles that selected a block, over every cycle (the log keeps the
    // last ones only).
    let totals = vm.relocationTotals
    func f(_ v: Double) -> String { unsafe String(format: "%.3f", v) }
    func ms(_ ns: UInt64) -> String { f(Double(ns) / 1e6) }
    let freed = c.freedByEpoch &+ c.freedAtPause
    let selecting = totals.selecting
    return [
        ("reloc", "on"), ("relocPlanned", "\(c.cyclesPlanned)"), ("relocCycles", "\(c.cyclesSelected)"),
        ("relocCandidates", "\(c.candidates)"), ("relocSelected", "\(c.blocksSelected)"), ("relocCapped", "\(c.capped)"),
        ("relocToMoveMB", f(Double(c.bytesToMove) / 1e6)), ("relocExpectedMB", f(Double(c.expectedReclaimBytes) / 1e6)),
        ("relocMovedObjects", "\(c.objectsMoved)"), ("relocMovedMB", f(Double(c.bytesMoved) / 1e6)),
        ("relocEvacuated", "\(c.blocksEvacuated)"), ("relocActualMB", f(Double(freed &* blockBytes) / 1e6)),
        ("relocSkipPinned", "\(c.skippedPinned)"), ("relocSkipHazard", "\(c.skippedHazard)"), ("relocNoSpace", "\(c.noSpace)"),
        ("relocAborted", "\(c.passesAborted)"), ("storesRedone", "\(c.storesRedone)"), ("spinEpisodes", "\(c.spinEpisodes)"),
        ("spinMs", ms(c.spinNs)), ("spinMaxMs", ms(c.spinMaxNs)), ("mainSpinEpisodes", "\(c.mainSpinEpisodes)"),
        ("mainSpinMaxMs", ms(c.mainSpinMaxNs)), ("hazardsTaken", "\(c.hazardsTaken)"), ("hazardWaits", "\(c.hazardWaits)"),
        ("framePins", "\(c.framePins)"), ("framePinsPerCycle", selecting == 0 ? "-" : f(Double(c.framePins) / Double(selecting))),
        ("pendingMax", "\(c.pendingMax)"), ("freedByEpoch", "\(c.freedByEpoch)"), ("freedAtPause", "\(c.freedAtPause)"),
        ("freeDelayMeanMs", freed == 0 ? "-" : ms(c.freeDelayNs / freed)), ("freeDelayMaxMs", ms(c.freeDelayMaxNs)),
        ("relocCpuMs", ms(c.passCpuNs)), ("relocWallMs", ms(c.passWallNs)),
        ("relocMovedMBPerCycle", selecting == 0 ? "-" : f(Double(c.bytesMoved) / 1e6 / Double(selecting))),
        ("relocVerifies", "\(c.verifierRuns)"), ("relocVerifyFailures", "\(c.verifierFailures)"),
        ("parksWhileRelocating", "\(c.parksWhileRelocating)"),
        ("oldEndMB", unsafe String(format: "%.1f", endMB)),
        ("oldPeakMB", unsafe String(format: "%.1f", Double(c.peakBlocksInUse &* blockBytes) / 1e6)),
        ("relocLogDropped", "\(totals.dropped)"),
    ]
}

// MARK: - module 7: the main thread's load and the young report

/// What the main thread did in a headless scenario (`--main-ms`).
struct MainLoad {
    var ms = 0.0
    var frames = 0
    var turns = 0
    var late = 0
    var inVMNs: UInt64 = 0
    var cpuNs: UInt64 = 0
    var parkNs: UInt64 = 0
    var stopNs: UInt64 = 0
    var waitNs: UInt64 = 0
    var collectorNs: UInt64 = 0
    var young = YoungWorkerCounters()

    func report() -> [(String, String)] {
        func f(_ v: Double) -> String { unsafe String(format: "%.3f", v) }
        let per10 = ms > 0 ? 10_000 / ms : 0
        func p10(_ ns: UInt64) -> String { f(Double(ns) / 1e6 * per10) }
        let y = young
        // Stopped because another worker allocated: parked in stops (module
        // 4's scavenges and the cycle's pauses), rounds of other nurseries'
        // collections (and the polls that found none owed), waits before a
        // stop and for a pending stop. Its own: flips or own collections,
        // waits for the collector, eden reuse, own rounds.
        let others = parkNs &+ y.acksOtherNs &+ y.serviceNs &+ y.stopWaitNs &+ y.drainWaitNs
        let own = y.flipNs &+ y.ownNs &+ y.collectorWaitNs &+ y.acksOwnNs
        return [
            ("mainMs", f(ms)), ("mainFrames", "\(frames)"), ("mainTurns", "\(turns)"), ("mainLateFrames", "\(late)"),
            ("mainInVMMsPer10s", p10(inVMNs)), ("mainCpuMsPer10s", p10(cpuNs)),
            ("mainStoppedOthersMsPer10s", p10(others)), ("mainStoppedOwnMsPer10s", p10(own)),
            ("mainParkMsPer10s", p10(parkNs)), ("mainCopyInStopsMsPer10s", p10(collectorNs)),
            ("mainStopMsPer10s", p10(stopNs)), ("mainEnterLeaveWaitMsPer10s", p10(waitNs)),
            ("mainAcksOther", "\(y.acksOther)"), ("mainAcksOtherMsPer10s", p10(y.acksOtherNs)),
            ("mainAckOtherMeanUs", y.acksOther == 0 ? "-" : f(Double(y.acksOtherNs) / Double(y.acksOther) / 1e3)),
            ("mainAcksOwn", "\(y.acksOwn)"), ("mainAcksOwnMsPer10s", p10(y.acksOwnNs)),
            ("mainAckMaxMs", f(Double(y.ackMaxNs) / 1e6)), ("mainServiceMsPer10s", p10(y.serviceNs)),
            ("mainFlips", "\(y.flips)"), ("mainFlipMsPer10s", p10(y.flipNs)), ("mainFlipMaxMs", f(Double(y.flipMaxNs) / 1e6)),
            ("mainOwnCollections", "\(y.ownCollections)"), ("mainOwnMsPer10s", p10(y.ownNs)),
            ("mainOwnMaxMs", f(Double(y.ownMaxNs) / 1e6)),
            ("mainCollectorWaits", "\(y.collectorWaits)"), ("mainCollectorWaitMsPer10s", p10(y.collectorWaitNs)),
            ("mainEdenWaits", "\(y.edenWaits)"), ("mainEdenWaitMsPer10s", p10(y.edenWaitNs)),
            ("mainStopWaitMsPer10s", p10(y.stopWaitNs)), ("mainDrainWaitMsPer10s", p10(y.drainWaitNs)),
        ]
    }
}

/// The calling thread acts as the shell's main thread for `--main-ms`: a
/// frame every `frameMs`, each a main-affine `mainTick:work:` run in turns
/// of at most a frame. Then it waits for the background Processes.
private func mainLoad(_ vm: VM, _ image: Image, _ options: Headless.Options, workers: [Oop]) -> MainLoad? {
    var m = MainLoad()
    let frameNs = UInt64(options.frameMs * 1e6)
    let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    // A negative duration: while the background Processes run.
    let end = options.mainMs > 0 ? t0 + UInt64(options.mainMs) * 1_000_000 : UInt64.max
    let y0 = vm.youngWorkerCounters(0)
    var next = t0
    while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < end && (options.mainMs > 0 || workers.contains { vm.state(of: $0) != .terminated }) {
        guard let p = vm.spawn(receiver: image.nilObject, selector: "mainTick:work:",
                               arguments: [Oop(smallInteger: Int64(options.mainAlloc)), Oop(smallInteger: Int64(options.mainWork))],
                               main: true) else { return nil }
        m.frames += 1
        var spent: UInt64 = 0
        repeat {
            let st = vm.runMain(budgetNs: frameNs)
            m.turns += 1
            m.inVMNs &+= st.ns
            m.cpuNs &+= st.cpuNs
            m.parkNs &+= st.parkNs
            m.stopNs &+= st.stopNs
            m.collectorNs &+= st.collectorNs
            m.waitNs &+= st.enterWaitNs &+ st.leaveWaitNs
            spent &+= st.ns
        } while vm.state(of: p) != .terminated && spent < frameNs * 4
        vm.release(p)
        next &+= frameNs
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if now > next { m.late += 1; next = now } else { usleep(UInt32((next - now) / 1000)) }
    }
    m.ms = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6
    let y1 = vm.youngWorkerCounters(0)
    m.young = YoungWorkerCounters(
        acksOwn: y1.acksOwn &- y0.acksOwn, acksOwnNs: y1.acksOwnNs &- y0.acksOwnNs, acksOther: y1.acksOther &- y0.acksOther,
        acksOtherNs: y1.acksOtherNs &- y0.acksOtherNs, ackMaxNs: y1.ackMaxNs, serviceNs: y1.serviceNs &- y0.serviceNs,
        ownCollections: y1.ownCollections &- y0.ownCollections, ownNs: y1.ownNs &- y0.ownNs, ownMaxNs: y1.ownMaxNs,
        flips: y1.flips &- y0.flips, flipNs: y1.flipNs &- y0.flipNs, flipMaxNs: y1.flipMaxNs,
        collectorWaits: y1.collectorWaits &- y0.collectorWaits, collectorWaitNs: y1.collectorWaitNs &- y0.collectorWaitNs,
        collectorWaitMaxNs: y1.collectorWaitMaxNs, edenWaits: y1.edenWaits &- y0.edenWaits,
        edenWaitNs: y1.edenWaitNs &- y0.edenWaitNs, edenWaitMaxNs: y1.edenWaitMaxNs,
        stopWaitNs: y1.stopWaitNs &- y0.stopWaitNs, drainWaitNs: y1.drainWaitNs &- y0.drainWaitNs)
    _ = workers
    return m
}

/// Module 7's line: collections by mode, rounds per collection and their
/// latency (p50, p99, max, the slowest participant of the worst), each
/// mode's collection time (p50, p99), the copy rate, objects survived and
/// promoted, overflow, eden-reuse waits, carried holders, deletion
/// records, deferred frees pending and released, snapshot exclusions,
/// fallbacks by cause, the young-root scan, the collector's QoS and CPU.
func youngReport(_ vm: VM, ms: Double) -> [(String, String)] {
    guard vm.hasYoungCollection else { return [("young", "stw")] }
    let c = vm.youngCounters
    // Percentiles over the records the logs kept; sums and maxima over
    // every collection and round.
    let log = vm.youngLog
    let rounds = vm.roundLog
    let totals = vm.youngTotals
    func f(_ v: Double) -> String { unsafe String(format: "%.3f", v) }
    func msS(_ ns: UInt64) -> String { f(Double(ns) / 1e6) }
    func pct(_ xs: [UInt64], _ q: Double) -> String {
        let s = xs.sorted()
        return s.isEmpty ? "-" : msS(s[min(s.count - 1, Int(Double(s.count) * q))])
    }
    let local = log.filter { !$0.offloaded }.map(\.totalNs)
    let off = log.filter(\.offloaded).map(\.totalNs)
    let lat = rounds.map(\.latencyNs)
    var edenWaits: UInt64 = 0, edenNs: UInt64 = 0, edenMax: UInt64 = 0, del: UInt64 = 0
    for i in 0..<(vm.config.backgroundWorkers + 2) {
        let w = vm.youngWorkerCounters(i)
        edenWaits &+= w.edenWaits
        edenNs &+= w.edenWaitNs
        edenMax = max(edenMax, w.edenWaitMaxNs)
        del &+= w.deletionRecords
    }
    let copied = totals.copiedBytes
    let cpu = totals.cpuNs
    let fb = c.fallbacks
    return [
        ("young", c.mode.name), ("ycLocal", "\(c.collectionsLocal)"), ("ycOffloaded", "\(c.collectionsOffloaded)"),
        ("ycInline", "\(c.offloadedInline)"),
        ("ycRoundsPerCollection", totals.collections == 0 ? "-" : f(Double(totals.rounds) / Double(totals.collections))),
        ("ackP50ms", pct(lat, 0.5)), ("ackP99ms", pct(lat, 0.99)), ("ackMaxMs", totals.roundRecords == 0 ? "-" : msS(totals.roundMaxNs)),
        ("ackSlowest", totals.roundRecords == 0 ? "-" : "\(totals.roundMaxSlowest)"),
        ("ycLocalP50ms", pct(local, 0.5)), ("ycLocalP99ms", pct(local, 0.99)),
        ("ycOffP50ms", pct(off, 0.5)), ("ycOffP99ms", pct(off, 0.99)),
        ("ycH0P50ms", pct(log.map(\.h0Ns), 0.5)), ("ycH1P50ms", pct(log.map(\.h1Ns), 0.5)),
        ("ycT1P50ms", pct(log.map(\.t1Ns), 0.5)), ("ycDrainRoundsP50ms", pct(log.map(\.drainRoundsNs), 0.5)),
        ("ycSweepP50ms", pct(log.map(\.sweepNs), 0.5)), ("ycEpochWaitP50ms", pct(log.map(\.epochWaitNs), 0.5)),
        ("ycEpochWaitP99ms", pct(log.map(\.epochWaitNs), 0.99)), ("ycCpuP50ms", pct(log.map(\.cpuNs), 0.5)),
        ("ycCopyMBs", cpu == 0 ? "-" : f(Double(copied) / Double(cpu) * 1e3)),
        ("ycSurvived", "\(totals.survivedObjects)"), ("ycPromoted", "\(c.promotedObjects)"),
        ("ycPromotedMB", f(Double(c.promotedBytes) / 1e6)),
        ("ycOverflowMB", f(Double(totals.overflowBytes) / 1e6)),
        ("edenWaits", "\(edenWaits)"), ("edenWaitMs", msS(edenNs)), ("edenWaitMaxMs", msS(edenMax)),
        ("ycCarried", "\(log.last?.carried ?? 0)"), ("ycHolders", "\(totals.holders)"),
        ("deletionRecords", "\(del)"), ("ycCrossRemembered", "\(totals.crossRemembered)"),
        ("deferred", "\(totals.deferred)"), ("deferredFreed", "\(totals.deferredFrees)"),
        ("deferredReleasedAtPauses", "\(vm.nurseryCounters.deferredReleased)"),
        ("snapshotExclusions", "\(c.snapshotExclusions)"),
        ("fallbackStopWanted", "\(fb[0])"), ("fallbackEntries", "\(fb[1])"), ("fallbackSoftLimit", "\(fb[2])"),
        ("fallbackReserve", "\(fb[YoungFallback.reserve.rawValue])"),
        ("hazardRetries", "\(totals.hazardRetries)"),
        ("youngRootScans", "\(c.initialMarks)"),
        ("youngRootScanMeanMs", c.initialMarks == 0 ? "-" : msS(c.youngRootScanNs / c.initialMarks)),
        ("youngRootScanMaxMs", msS(c.youngRootScanMaxNs)),
        ("collectorQoS", "\(c.collectorQoS)"), ("collectorCpuMs", msS(c.collectorCpuNs)),
        ("collectorWakeups", "\(c.collectorWakeups)"),
        ("ycVerifies", "\(c.verifierRuns)"),
        ("ycLogDropped", "\(totals.droppedCollections)"), ("roundLogDropped", "\(totals.droppedRounds)"),
    ]
}

// MARK: - module 8b: the event sink

/// Where primitive 140's events go: the host's closure, reached from the C
/// hook through the hooks' context pointer.
final class EventSink: @unchecked Sendable {
    let emit: @Sendable ([UInt8]) -> Void
    init(_ emit: @escaping @Sendable ([UInt8]) -> Void) { self.emit = emit }
}

private let eventHook: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>, Int) -> Void = { ctx, bytes, count in
    guard let ctx = unsafe ctx else { return }
    let sink = unsafe Unmanaged<EventSink>.fromOpaque(ctx).takeUnretainedValue()
    sink.emit(unsafe Array(UnsafeBufferPointer(start: bytes, count: count)))
}
