import Foundation
import Synchronization
@testable import KajoVM

// Gate speed (docs/modules/gate-speed.md, change 3): the native test
// modules a suite compiles, kept on disk between suite runs. Every suite run
// of a gate run compiled the same generated C again (the native random
// programs alone are about 70 percent clang). A module is keyed by a digest
// of everything clang reads and is told: the source (the generated C is one
// file whose only includes are the system's), the `--version` of the clang
// first on PATH, the SDK it compiles against, and the whole argument list
// (`-fsanitize=thread` included). A hit loads the cached dylib; a miss
// compiles beside the cache under a temporary name and renames into place,
// so a reader never sees half a file. A cached file that does not load is
// removed, compiled again and counted as replaced; it never fails or passes
// a test by itself.
//
// The cache is `.build/native-test-cache/` of the package (one place for
// every scratch path: the debug, sanitizer and release suite runs share it
// where their keys agree); `KAJO_NATIVE_CACHE=<dir>` moves it and
// `KAJO_NATIVE_CACHE=off` turns it off (the old behaviour: a temporary
// file per compile, removed after loading). It is bounded: at a process's
// first use, files nobody has used for an hour go, oldest first, until the
// cache is under three quarters of `NativeCache.defaultBound` (2 GiB). A file used
// within the hour is never removed, so a suite running in another process
// keeps what it uses; a file removed under a reader anyway is a failed load,
// which is compiled again. The suite prints its counts once, at the
// process's exit.

final class NativeCache: Sendable {
    /// Bytes past which the oldest files go. Measured (the doc): a plain
    /// suite's modules are 569 files and 195 MiB, a sanitizer suite's 65
    /// and 33 MiB, and the release runs' keys are the plain ones; so 2 GiB
    /// keeps about nine generators' worth of a gate run.
    static let defaultBound = 2 << 30
    /// Files used within this many seconds are never trimmed.
    static let keepRecent: TimeInterval = 3600

    let directory: String
    let bound: Int
    let hits = Atomic<Int>(0)
    let misses = Atomic<Int>(0)
    let replaced = Atomic<Int>(0)
    let trimmed = Atomic<Int>(0)
    /// The temporary file's serial: per process, not per cache, so two
    /// caches over one directory in one process never write one file.
    private static let serial = Atomic<Int>(0)

    init(directory: String, bound: Int = NativeCache.defaultBound) {
        self.directory = directory
        self.bound = bound
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    /// The package's root (this file is Tests/KajoVMTests/Native/).
    static let packageRoot: String = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.path
    }()

    /// The suite's cache, or nil when `KAJO_NATIVE_CACHE=off`. Trimmed once
    /// at first use; its counts are printed at the process's exit.
    static let shared: NativeCache? = {
        let env = ProcessInfo.processInfo.environment["KAJO_NATIVE_CACHE"]
        if env == "off" {
            print("native test cache: off (KAJO_NATIVE_CACHE=off)")
            return nil
        }
        let c = NativeCache(directory: env.flatMap { $0.isEmpty ? nil : $0 } ?? packageRoot + "/.build/native-test-cache")
        c.trim()
        atexit { NativeCache.shared?.report() }
        return c
    }()

    /// One line for the gate's output: whether clang ran.
    func report() {
        let (files, bytes) = contents()
        let line = "native test cache: \(hits.load(ordering: .relaxed)) hits, \(misses.load(ordering: .relaxed)) misses, "
            + "\(replaced.load(ordering: .relaxed)) replaced, \(trimmed.load(ordering: .relaxed)) trimmed at start; "
            + "\(files.count) files, \(bytes >> 20) MiB in \(directory)\n"
        fputs(line, stdout)
        fflush(stdout)
    }

    /// What clang reads besides the source and its arguments, once per clang.
    private static let identities = Mutex<[String: String]>([:])
    static func identity(clang: String) -> String {
        if let s = identities.withLock({ $0[clang] }) { return s }
        let (_, version) = NativeTest.run(clang, ["--version"])
        let env = ProcessInfo.processInfo.environment
        let sdk = env["SDKROOT"] ?? NativeTest.run("/usr/bin/xcrun", ["--show-sdk-path"]).1
        let sdkVersion = NativeTest.run("/usr/bin/xcrun", ["--show-sdk-build-version"]).1
        let s = "\(clang)\n\(version)\n\(sdk)\n\(sdkVersion)"
        identities.withLock { $0[clang] = s }
        return s
    }

    /// The key: a digest of the source, the clang's identity and the arguments.
    func key(source: String, clang: String, arguments: [String]) -> String {
        var bytes = Array(source.utf8)
        bytes.append(0)
        bytes += Array(NativeCache.identity(clang: clang).utf8)
        for a in arguments { bytes.append(0); bytes += Array(a.utf8) }
        let (a, b) = nativeDigest(bytes)
        return String(format: "%016llx%016llx", a, b)
    }

    /// One lock per key being looked up in this process: threads asking
    /// for the same module at once (the random programs' configurations
    /// start together and generate the same seed's C) wait for the first
    /// one's compile and hit, instead of each compiling it (a cold plain
    /// suite compiled 1335 modules for 569 keys without this).
    private let inFlight = Mutex<[String: NSLock]>([:])

    /// The module for this source and these arguments, from the cache or
    /// compiled into it.
    func module(source: String, clang: String, arguments: [String], name: String) throws -> NativeModule {
        let k = key(source: source, clang: clang, arguments: arguments)
        let lock = inFlight.withLock { d in
            if let l = d[k] { return l }
            let l = NSLock()
            d[k] = l
            return l
        }
        lock.lock()
        defer { lock.unlock() }
        return try lookUpOrCompile(key: k, source: source, clang: clang, arguments: arguments, name: name)
    }

    private func lookUpOrCompile(key k: String, source: String, clang: String, arguments: [String], name: String) throws -> NativeModule {
        let path = "\(directory)/\(k).dylib"
        if FileManager.default.fileExists(atPath: path) {
            switch NativeModule.load(dylib: path) {
            case .success(let m):
                hits.add(1, ordering: .relaxed)
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
                return m
            case .failure:
                replaced.add(1, ordering: .relaxed)
                try? FileManager.default.removeItem(atPath: path)
            }
        } else {
            misses.add(1, ordering: .relaxed)
        }
        let tmp = "\(path).tmp-\(getpid())-\(NativeCache.serial.add(1, ordering: .relaxed).newValue)"
        do {
            try NativeTest.compileFile(source, clang: clang, arguments: arguments, into: tmp, name: name)
        } catch {
            try? FileManager.default.removeItem(atPath: tmp)
            throw error
        }
        guard rename(tmp, path) == 0 else {
            let e = errno
            try? FileManager.default.removeItem(atPath: tmp)
            throw NativeTest.CompileError(description: "cannot rename \(tmp) into the native test cache: errno \(e)")
        }
        switch NativeModule.load(dylib: path) {
        case .success(let m): return m
        case .failure(let e): throw NativeTest.CompileError(description: "\(e)")
        }
    }

    /// The cache's dylibs with their sizes and modification dates.
    func contents() -> (files: [(path: String, bytes: Int, date: Date)], bytes: Int) {
        let fm = FileManager.default
        var files: [(path: String, bytes: Int, date: Date)] = []
        for n in (try? fm.contentsOfDirectory(atPath: directory)) ?? [] where n.hasSuffix(".dylib") {
            let p = "\(directory)/\(n)"
            guard let a = try? fm.attributesOfItem(atPath: p) else { continue }
            files.append((p, (a[.size] as? Int) ?? 0, (a[.modificationDate] as? Date) ?? .distantPast))
        }
        return (files, files.reduce(0) { $0 + $1.bytes })
    }

    /// Temporary files of writers that died, and the oldest dylibs past the
    /// bound, never one used within `keepRecent`.
    func trim(now: Date = Date()) {
        let fm = FileManager.default
        for n in (try? fm.contentsOfDirectory(atPath: directory)) ?? [] where n.contains(".dylib.tmp-") {
            let p = "\(directory)/\(n)"
            if let d = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date, now.timeIntervalSince(d) > NativeCache.keepRecent {
                try? fm.removeItem(atPath: p)
            }
        }
        var (files, total) = contents()
        guard total > bound else { return }
        files.sort { $0.date < $1.date }
        for f in files {
            if total <= bound / 4 * 3 { break }
            if now.timeIntervalSince(f.date) < NativeCache.keepRecent { break }
            if (try? fm.removeItem(atPath: f.path)) != nil {
                total -= f.bytes
                trimmed.add(1, ordering: .relaxed)
            }
        }
    }
}
