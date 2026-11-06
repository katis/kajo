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
        // Large bytes: 1024 blocks (32 MiB, reserved, touched only as used)
        // so the seed with a byte object past 16 MiB loads; it was 64.
        c.heapBytes = 1024 * BlockHeap.blockBytes
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

    /// Load the bytes as an image (module 8: the snapshot plus the method
    /// table and the object-model rules), then run the heap verifiers and a
    /// collection. Snapshot-format bytes go to `snapshot`, so the one fuzz
    /// target covers both loaders.
    @discardableResult
    public static func image(_ data: [UInt8]) -> Bool {
        guard let image = try? Image.load(image: data, config: config()) else { return false }
        defer { image.destroy() }
        image.om.retireAllContexts()
        let issues = image.om.verifyHeap() + image.om.verifyFreeLists()
        precondition(issues.isEmpty, "a loaded image failed the verifiers: \(issues)")
        if image.hasSavedProcesses {
            // Module 8c: the resume up to, not including, running Smalltalk:
            // a VM installs the saved Processes (records, stacks, queues),
            // then goes away without starting (which frees the stacks).
            var vc = VMConfig()
            vc.backgroundWorkers = 1
            vc.nursery.bytes = 0
            vc.marking.enabled = false
            vc.relocation.enabled = false
            vc.young.mode = .stw
            let vm = VM(image: image, config: vc)
            precondition(vm.resumedProcesses.count == vm.liveProcessCount, "a resumed VM lost a Process")
            vm.destroy()
        }
        image.om.collect()
        return true
    }

    /// Module 8d: the syntax fuzzer's make-and-run mode. A method the
    /// bootstrap compiler compiled (for a class with instance variables a
    /// and b), in the form the compiler in Smalltalk hands over, goes
    /// through the make primitive (143, the trust boundary: the one
    /// bytecode verifier on what it made), and a method it made runs once
    /// through primitive 85 on a standalone interpreter, with 3 for every
    /// argument, then again with an extreme SmallInteger for every argument
    /// (minVal, maxVal, -1 or 0, chosen by the bytecodes' length: a
    /// primitive answers failure for such an argument and never traps,
    /// docs/modules/collectors-review.md, finding 2). A method whose code loops (a backward jump in it or in a
    /// block) is made but not run: the standalone interpreter has no
    /// preemption to end it. Answers whether the method was made. A refusal
    /// is the normal outcome of what the assembler let through (it is the
    /// verifier's own check, so it should not happen); a trap is a finding.
    @discardableResult
    package static func makeAndRun(_ m: AssembledMethod) -> Bool {
        guard let image = try? Image(memory: ObjectMemory(config())) else { return false }
        defer { image.destroy() }
        do {
            try image.load([(file: "make.kasm", text: makePrelude)])
        } catch {
            preconditionFailure("the make prelude: \(error)")
        }
        guard let codeClass = image.classIndex(named: "FuzzCode"), let target = image.classIndex(named: "FuzzTarget"),
              let (code, root) = try? image.codeObject(m, codeClass: codeClass) else { return false }
        defer { image.om.removeRoot(root) }
        let interp = Interpreter(image: image)
        defer { interp.destroy() }
        let stack = Stack(words: 1 << 14)
        defer { stack.destroy() }
        guard case .success(let made) = interp.run(on: stack, receiver: code, selector: "makeIn:",
                                                   arguments: [image.om.classOop(target)]) else { return false }
        guard made.isObject, image.om.classIndex(of: made) == WellKnown.method else {
            precondition(made == image.nilObject || image.om.classIndex(of: made) == WellKnown.string,
                         "the make primitive answered neither a method nor a reason")
            return false
        }
        let mh = image.om.addRoot(made)
        defer { image.om.removeRoot(mh) }
        precondition(verifyHeapMethod(image.om, made, classIndex: target, nilObject: image.nilObject) == nil,
                     "a made method the verifier refuses")
        if loops(image.om, made, depth: 0) { return true }
        let extreme = [Oop.smallIntegerMin, Oop.smallIntegerMax, -1, 0][m.bytecodes.count % 4]
        for value in [3, extreme] {
            guard let rcv = image.om.allocate(image.context, classIndex: target, slots: 2, fill: image.nilObject),
                  let args = image.om.allocate(image.context, classIndex: WellKnown.array, slots: m.argc,
                                               fill: Oop(smallInteger: value), extraRoots: [rcv]) else { return true }
            let rh = image.om.addRoot(rcv), ah = image.om.addRoot(args)
            defer { image.om.removeRoot(rh); image.om.removeRoot(ah) }
            _ = interp.run(on: stack, receiver: made, selector: "valueWithReceiver:arguments:", arguments: [rcv, args])
        }
        image.om.retireAllContexts()
        let issues = image.om.verifyHeap() + image.om.verifyFreeLists()
        precondition(issues.isEmpty, "a made method's run left a bad heap: \(issues)")
        return true
    }

    /// The make-and-run mode's image: the code class (the kernel's
    /// CompiledCode layout), the class methods are made for, the two
    /// primitives as methods.
    static let makePrelude = """
    class FuzzCode Object 9 fixed
    class FuzzTarget Object 2 fixed
    method FuzzCode makeIn: temps=0 prim=143
      push_nil
      return_top
    end
    method CompiledMethod valueWithReceiver:arguments: temps=0 prim=85
      push_nil
      return_top
    end
    """

    /// A backward jump in the method or one of its block methods.
    private static func loops(_ om: ObjectMemory, _ method: Oop, depth: Int) -> Bool {
        if depth > 64 { return true }
        let bytes = om.bytes(of: om.load(method, MethodLayout.bytecodes))
        var off = 0
        while off < bytes.count, let d = decodeInstruction(bytes, at: off) {
            if d.op.isJump && d.a < 0 { return true }
            off += d.length
        }
        let lits = om.load(method, MethodLayout.literals)
        for k in 0..<Int(om.count(of: lits)) {
            let l = om.load(lits, k)
            if l.isObject, om.classIndex(of: l) == WellKnown.method, loops(om, l, depth: depth + 1) { return true }
        }
        return false
    }

    /// The snapshot target's entry: an image when the bytes start with the
    /// image magic, else a module 1 snapshot.
    @discardableResult
    public static func snapshotOrImage(_ data: [UInt8]) -> Bool {
        if data.count >= 8 && data[0..<8].elementsEqual([0x4B, 0x41, 0x4A, 0x4F, 0x49, 0x4D, 0x47, 0]) { return image(data) }
        return snapshot(data)
    }

    /// A valid image to seed the snapshot corpus with: a small program with
    /// a class, a closure and a temp vector.
    public static func imageSeed() -> [UInt8] {
        let image = try! Image(memory: ObjectMemory(config()))
        defer { image.destroy() }
        try! image.load([(file: "seed.kasm", text: """
        class Node Object 2
        method Node next temps=0
          push_ivar 0
          return_top
        end
        method UndefinedObject run:of: temps=1
          push_new_array 1
          store_temp 2
          push_temp 2
          push_closure b 1
          value
          return_top
        block b args=0 copied=1 temps=0
          push_tv_slot 0 0
          push_lit 'añ'
          push_lit 1.5
          push_lit $x
          pop
          pop
          pop
          block_return
        end
        """)])
        return try! image.saveImage()
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
