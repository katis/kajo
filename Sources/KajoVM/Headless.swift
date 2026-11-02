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
        var config = ObjectMemoryConfig()
        config.heapBytes = options.heapMiB << 20
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
        var vc = VMConfig()
        vc.backgroundWorkers = options.workers
        vc.stackWords = options.stackWords
        vc.stress = VMStress(parsing: options.vmStress)
        vc.sliceNs = UInt64(options.sliceMs * 1e6)
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
            pauses.isEmpty ? "-" : String(format: "%.3f", Double(pauses[min(pauses.count - 1, Int(Double(pauses.count) * q))]) / 1e6)
        }
        let worst = stops.max { $0.pauseNs < $1.pauseNs }
        let qos = (1...n).map { "\(vm.workerQoS($0).rawValue)" }.joined(separator: ",")
        let report: [(String, String)] = [
            ("qos", qos), ("stops", "\(stops.count)"), ("pauseP50ms", pct(0.5)), ("pauseP99ms", pct(0.99)),
            ("pauseMaxMs", pauses.last.map { String(format: "%.3f", Double($0) / 1e6) } ?? "-"),
            ("slowestParticipant", worst.map { "\($0.slowest)" } ?? "-"),
        ]
        return Outcome(checksum: checksum, milliseconds: ms, counters: [
            ("sends", c.sends), ("cacheMisses", c.cacheMisses), ("cacheFlushes", c.cacheFlushes),
            ("primitiveCalls", c.primitiveCalls), ("primitiveFailures", c.primitiveFailures),
            ("specialSendFallbacks", c.specialSendFallbacks), ("errors", c.errors),
            ("safepointPolls", c.safepointPolls), ("collectionsTriggered", c.collectionsTriggered),
            ("collections", m.collections), ("compactions", m.compactions), ("allocations", m.allocations),
            ("allocatedBytes", m.allocatedBytes),
        ] + v.named.filter { ["slices", "preemptions", "stops", "schedLocks", "schedContended", "schedWaitNs",
                              "parkNs", "enterWaitNs", "stopNs", "timeToSafepointNs", "processErrors"].contains($0.name) },
        report: report)
    }
}
