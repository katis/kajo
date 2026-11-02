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
        /// One until module 3 brings workers.
        public var workers = 1
        public var stackWords = 1 << 16

        public init() {}
    }

    public struct Outcome: Sendable {
        /// The SmallInteger `run:of:` answered, or the failure.
        public let checksum: Result<Int64, Failure>
        /// Wall time of the run, load excluded.
        public let milliseconds: Double
        /// Interpreter and object memory counters, in a stable order.
        public let counters: [(name: String, value: UInt64)]
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
        func failed(_ f: Failure) -> Outcome { Outcome(checksum: .failure(f), milliseconds: 0, counters: []) }
        if options.workers != 1 { return failed(.unsupported("--workers: only 1 until module 3 (workers and safepoints)")) }
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
        let interpreter = Interpreter(image: image)
        let stack = Stack(words: options.stackWords)
        defer {
            stack.destroy()
            interpreter.destroy()
        }
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let r = interpreter.run(on: stack, receiver: image.nilObject, selector: "run:of:",
                                arguments: [Oop(smallInteger: 0), Oop(smallInteger: Int64(options.workers))])
        let ms = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6
        let checksum: Result<Int64, Failure> = switch r {
        case .success(let v): v.isSmallInteger ? .success(v.smallIntegerValue) : .failure(.notAnInteger("\(v)"))
        case .failure(let e): .failure(.vm(e))
        }
        let c = interpreter.counters, m = image.om.counters
        return Outcome(checksum: checksum, milliseconds: ms, counters: [
            ("sends", c.sends), ("cacheMisses", c.cacheMisses), ("cacheFlushes", c.cacheFlushes),
            ("primitiveCalls", c.primitiveCalls), ("primitiveFailures", c.primitiveFailures),
            ("specialSendFallbacks", c.specialSendFallbacks), ("errors", c.errors),
            ("safepointPolls", c.safepointPolls), ("collectionsTriggered", c.collectionsTriggered),
            ("collections", m.collections), ("compactions", m.compactions), ("allocations", m.allocations),
            ("allocatedBytes", m.allocatedBytes),
        ])
    }
}
