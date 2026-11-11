import Foundation
import Synchronization
import Testing
import KajoAOT
@testable import KajoVM

// AOT 1 (docs/modules/aot.md, Tests): the native engine in the tests. The
// generator reads the very image a test loaded (so the oops it folds are
// the image's), the C is compiled with the clang first on PATH into a
// dylib in a temporary directory (with ThreadSanitizer when the suite runs
// under it) and `dlopen`ed. A test that finds no compiler fails.

enum NativeTest {
    /// Modules by the image's method hashes: two images with the same
    /// methods (and so the same oops folded) share one compiled module.
    private static let cache = Mutex<[String: NativeModule]>([:])

    /// The generated C for an image's methods.
    static func source(for image: Image, options: AOTOptions = AOTOptions()) -> AOTOutput {
        AOTGenerator.generate(image.nativeMethodInfos(), nilOop: image.nilObject.raw, trueOop: image.trueObject.raw,
                              falseOop: image.falseObject.raw, options: options)
    }

    /// The compiled module for an image's methods.
    static func module(for image: Image, options: AOTOptions = AOTOptions()) throws -> NativeModule {
        let out = source(for: image, options: options)
        let h = nativeDigest(Array(out.source.utf8))
        let key = "\(h.0)-\(h.1)"
        if let m = cache.withLock({ $0[key] }) { return m }
        let m = try compile(out.source, name: "kajo-native-test")
        cache.withLock { $0[key] = m }
        return m
    }

    /// The temporary directory every compiled module goes to.
    static let directory: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("kajo-native-\(getpid())")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static let counter = Atomic<Int>(0)

    /// The clang first on PATH.
    static var clang: String? {
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let p = "\(dir)/clang"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    struct CompileError: Error, CustomStringConvertible {
        let description: String
    }

    /// Compile C into a dylib and load it. `flags` add to `-O1 -shared
    /// -fPIC` (and `-fsanitize=thread` under the sanitizer).
    static func compile(_ source: String, name: String, flags: [String] = ["-O1"]) throws -> NativeModule {
        guard let cc = clang else { throw CompileError(description: "no clang on PATH") }
        let n = counter.add(1, ordering: .relaxed).newValue
        let c = directory.appendingPathComponent("\(name)-\(n).c")
        let lib = directory.appendingPathComponent("\(name)-\(n).dylib")
        try source.write(to: c, atomically: true, encoding: .utf8)
        var args = flags + ["-shared", "-fPIC", "-w", "-o", lib.path, c.path]
        if underThreadSanitizer { args.insert("-fsanitize=thread", at: 0) }
        let (status, output) = run(cc, args)
        guard status == 0 else { throw CompileError(description: "clang failed (\(status)): \(output.prefix(2000))") }
        switch NativeModule.load(dylib: lib.path) {
        case .success(let m): return m
        case .failure(let e): throw CompileError(description: "\(e)")
        }
    }

    /// Run a tool; its status and its combined output.
    static func run(_ tool: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
