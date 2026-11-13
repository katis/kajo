import Foundation
import Synchronization
import Testing
@testable import KajoVM

// Gate speed (docs/modules/gate-speed.md, change 3): the disk cache of
// compiled native test modules. Each test has a cache directory of its own.

/// The smallest source `NativeModule.load` accepts: a descriptor symbol.
private func tinySource(_ value: Int) -> String {
    "__attribute__((visibility(\"default\"))) const unsigned long long kajo_native_module[16] = { \(value) };\n"
}

private func freshCache(_ name: String) -> NativeCache {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("kajo-native-cache-\(name)-\(getpid())").path
    try? FileManager.default.removeItem(atPath: d)
    return NativeCache(directory: d)
}

private let flags = ["-O1", "-shared", "-fPIC", "-w"]

@Test func theNativeCacheHitsOnlyForTheSameSourceAndFlags() throws {
    let cc = try #require(NativeTest.clang, "no clang on PATH")
    let c = freshCache("keys")
    defer { try? FileManager.default.removeItem(atPath: c.directory) }
    _ = try c.module(source: tinySource(1), clang: cc, arguments: flags, name: "t")
    #expect(c.misses.load(ordering: .relaxed) == 1 && c.hits.load(ordering: .relaxed) == 0)
    // the same source and flags: a hit that loads
    let m = try c.module(source: tinySource(1), clang: cc, arguments: flags, name: "t")
    #expect(c.hits.load(ordering: .relaxed) == 1)
    #expect(m.word(0) == 1)
    // a changed source misses
    let m2 = try c.module(source: tinySource(2), clang: cc, arguments: flags, name: "t")
    #expect(c.misses.load(ordering: .relaxed) == 2)
    #expect(m2.word(0) == 2)
    // a changed flag misses
    _ = try c.module(source: tinySource(1), clang: cc, arguments: ["-O2"] + flags.dropFirst(), name: "t")
    #expect(c.misses.load(ordering: .relaxed) == 3 && c.hits.load(ordering: .relaxed) == 1)
    #expect(c.key(source: tinySource(1), clang: cc, arguments: flags) != c.key(source: tinySource(1), clang: cc, arguments: ["-fsanitize=thread"] + flags))
    #expect(c.contents().files.count == 3)
    #expect(c.replaced.load(ordering: .relaxed) == 0)
}

@Test func aTruncatedCachedModuleIsReplaced() throws {
    let cc = try #require(NativeTest.clang, "no clang on PATH")
    let c = freshCache("truncated")
    defer { try? FileManager.default.removeItem(atPath: c.directory) }
    // a file under the key that is not a dylib (a writer cut off), never loaded before
    let k = c.key(source: tinySource(3), clang: cc, arguments: flags)
    let path = "\(c.directory)/\(k).dylib"
    FileManager.default.createFile(atPath: path, contents: Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C]))
    let m = try c.module(source: tinySource(3), clang: cc, arguments: flags, name: "t")
    #expect(m.word(0) == 3)
    #expect(c.replaced.load(ordering: .relaxed) == 1 && c.misses.load(ordering: .relaxed) == 0 && c.hits.load(ordering: .relaxed) == 0)
    #expect(((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0) > 1000)
}

@Test func twoThreadsCompilingOneSourceBothGetAModule() throws {
    let cc = try #require(NativeTest.clang, "no clang on PATH")
    // Two caches over one directory stand for two processes (each has its
    // own in-process locks, so they can compile one source at the same
    // time and rename over each other); four threads of each ask at once.
    let a = freshCache("race")
    let b = NativeCache(directory: a.directory)
    defer { try? FileManager.default.removeItem(atPath: a.directory) }
    let got = Mutex<[UInt64]>([])
    let failures = Mutex<[String]>([])
    for round in 0..<2 {
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            do {
                let m = try (i % 2 == 0 ? a : b).module(source: tinySource(40 + round), clang: cc, arguments: flags, name: "t")
                got.withLock { $0.append(m.word(0)) }
            } catch {
                failures.withLock { $0.append("\(error)") }
            }
        }
    }
    #expect(failures.withLock { $0 }.isEmpty, "\(failures.withLock { $0 })")
    #expect(got.withLock { $0 }.sorted() == [UInt64](repeating: 40, count: 8) + [UInt64](repeating: 41, count: 8))
    // within one cache the threads wait for one compile: at most one miss
    // per source each, the rest hits
    for c in [a, b] {
        #expect(c.misses.load(ordering: .relaxed) <= 2 && c.hits.load(ordering: .relaxed) >= 6,
                "misses \(c.misses.load(ordering: .relaxed)) hits \(c.hits.load(ordering: .relaxed))")
        #expect(c.misses.load(ordering: .relaxed) + c.hits.load(ordering: .relaxed) == 8)
    }
    // no temporary file is left, one dylib per source
    let names = (try? FileManager.default.contentsOfDirectory(atPath: a.directory)) ?? []
    #expect(names.filter { $0.contains(".tmp-") }.isEmpty, "\(names)")
    #expect(a.contents().files.count == 2)
}

@Test func theNativeCacheIsTrimmedOldestFirstAndKeepsRecentFiles() throws {
    let c0 = freshCache("trim")
    defer { try? FileManager.default.removeItem(atPath: c0.directory) }
    let fm = FileManager.default
    let now = Date()
    // five old files of 1000 bytes (hours apart), one recent, a dead writer's temporary
    for k in 0..<5 {
        let p = "\(c0.directory)/old\(k).dylib"
        fm.createFile(atPath: p, contents: Data(count: 1000))
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-Double(10 - k) * 3600)], ofItemAtPath: p)
    }
    fm.createFile(atPath: "\(c0.directory)/recent.dylib", contents: Data(count: 1000))
    let tmp = "\(c0.directory)/x.dylib.tmp-1-1"
    fm.createFile(atPath: tmp, contents: Data(count: 10))
    try fm.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: tmp)
    let c = NativeCache(directory: c0.directory, bound: 4000)
    c.trim(now: now)
    let left = Set(try fm.contentsOfDirectory(atPath: c.directory))
    // 6000 bytes against a bound of 4000: down to 3000, the oldest three go
    #expect(left == ["old3.dylib", "old4.dylib", "recent.dylib"], "\(left.sorted())")
    #expect(c.trimmed.load(ordering: .relaxed) == 3)
    // under a bound nothing a reader used within the hour goes
    let tight = NativeCache(directory: c0.directory, bound: 10)
    tight.trim(now: now)
    #expect(Set(try fm.contentsOfDirectory(atPath: c.directory)) == ["recent.dylib"])
}
