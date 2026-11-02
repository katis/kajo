/// Entry points for fuzzing the two loaders that read untrusted bytes: kasm
/// text and object memory snapshots. The libFuzzer targets
/// (`Sources/fuzz-kasm`, `Sources/fuzz-snapshot`) call these from
/// `LLVMFuzzerTestOneInput`; the seeded-mutation tests call them too.
///
/// Each answers whether the input loaded. A rejected input is the normal
/// outcome; a trap is a finding: a verifier that disagrees after a load
/// traps on purpose.
public enum FuzzEntry {
    private static func config() -> ObjectMemoryConfig {
        var c = ObjectMemoryConfig()
        c.heapBytes = 64 * BlockHeap.blockBytes
        c.entryCapacity = 1 << 14
        c.entryChunk = 64
        c.verify = true
        c.onVerifyFailure = .trap
        return c
    }

    /// Load the bytes as one kasm file into a fresh image.
    @discardableResult
    public static func kasm(_ data: [UInt8]) -> Bool {
        guard let image = try? Image(memory: ObjectMemory(config())) else { return false }
        defer { image.destroy() }
        do {
            try image.load([(file: "fuzz.kasm", text: String(decoding: data, as: UTF8.self))])
        } catch {
            return false
        }
        image.om.retireAllContexts()
        let issues = image.om.verifyHeap() + image.om.verifyFreeLists()
        precondition(issues.isEmpty, "a loaded kasm file left a bad heap: \(issues)")
        return true
    }

    /// Load the bytes as an object memory snapshot (module 1's loader),
    /// then verify and collect.
    @discardableResult
    public static func snapshot(_ data: [UInt8]) -> Bool {
        guard let om = try? ObjectMemory.load(snapshot: data, config: config()) else { return false }
        defer { om.destroy() }
        om.retireAllContexts()
        let issues = om.verifyHeap() + om.verifyFreeLists()
        precondition(issues.isEmpty, "a loaded snapshot failed the verifiers: \(issues)")
        om.collect()
        return true
    }

    /// A valid snapshot to seed the snapshot corpus with: an image with a
    /// small program loaded.
    public static func snapshotSeed() -> [UInt8] {
        let image = try! Image(memory: ObjectMemory(config()))
        defer { image.destroy() }
        try! image.load([(file: "seed.kasm", text: """
        class Node Object 2
        method Node next temps=0
          push_ivar 0
          return_top
        end
        method UndefinedObject run:of: temps=0
          push_lit @Node
          send basicNew 0
          return_top
        end
        """)])
        return image.om.snapshot()
    }
}

import Foundation

/// The driver the fuzz targets use when they are not built with libFuzzer
/// (`-sanitize=fuzzer` is unsupported by the Xcode toolchain, see
/// docs/modules/interpreter.md): replay a corpus, then mutate it without
/// coverage guidance for a while. Before each input runs it is written to
/// `fuzz-current` in the working directory, so a trap leaves its
/// reproducer behind.
public enum FuzzDriver {
    public static func main(_ arguments: [String], entry: ([UInt8]) -> Bool, makeSeed: (() -> [UInt8])? = nil) -> Int32 {
        if arguments.count == 2, arguments[0] == "--write-seed", let makeSeed {
            return FileManager.default.createFile(atPath: arguments[1], contents: Data(makeSeed())) ? 0 : 1
        }
        var seconds = 0.0, seed: UInt64 = 1
        var paths: [String] = []
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--seconds" where i + 1 < arguments.count: seconds = Double(arguments[i + 1]) ?? 0; i += 1
            case "--seed" where i + 1 < arguments.count: seed = UInt64(arguments[i + 1]) ?? 1; i += 1
            default: paths.append(arguments[i])
            }
            i += 1
        }
        var corpus: [[UInt8]] = []
        let fm = FileManager.default
        for p in paths {
            var isDir: ObjCBool = false
            guard unsafe fm.fileExists(atPath: p, isDirectory: &isDir) else { continue }
            let files = isDir.boolValue ? ((try? fm.contentsOfDirectory(atPath: p)) ?? []).sorted().map { "\(p)/\($0)" } : [p]
            for f in files { if let d = fm.contents(atPath: f) { corpus.append(Array(d)) } }
        }
        guard !corpus.isEmpty else {
            print("usage: <target> [--seconds N] [--seed S] <corpus files or directories>")
            return 2
        }
        func attempt(_ input: [UInt8]) -> Bool {
            fm.createFile(atPath: "fuzz-current", contents: Data(input))
            return entry(input)
        }
        var loaded = 0, runs = 0
        for c in corpus where attempt(c) { loaded += 1 }
        runs = corpus.count
        print("replayed \(corpus.count) inputs, \(loaded) loaded")
        var state = seed
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        let deadline = Date().addingTimeInterval(seconds)
        loaded = 0
        while Date() < deadline {
            var b = corpus[Int(next() % UInt64(corpus.count))]
            for _ in 0..<(1 + Int(next() % 4)) where !b.isEmpty {
                let k = Int(next() % UInt64(b.count))
                switch next() % 4 {
                case 0: b[k] ^= UInt8(truncatingIfNeeded: 1 << (next() % 8))
                case 1: b[k] = UInt8(truncatingIfNeeded: next())
                case 2: b.remove(at: k)
                default: b.insert(b[Int(next() % UInt64(b.count))], at: k)
                }
            }
            if attempt(b) { loaded += 1 }
            runs += 1
        }
        if seconds > 0 { print("mutated for \(Int(seconds)) s: \(runs - corpus.count) inputs, \(loaded) loaded, no trap") }
        try? fm.removeItem(atPath: "fuzz-current")
        return 0
    }
}
