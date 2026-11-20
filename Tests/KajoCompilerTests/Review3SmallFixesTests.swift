// The third review's small fixes, part 1 (docs/modules/review-3-small-fixes.md):
// the verifier level a Headless run reports (item 1), the Monitor's two
// terminations and a SharedQueue with a consumer terminated (item 2), and
// the late reply a client must drop (item 7).

import Darwin
import Foundation
import Synchronization
import Testing
@testable import KajoCompiler
@testable import KajoDev
@testable import KajoVM

// MARK: - item 1: the verifier level

/// The `gc` summary event of a `Headless.test` run of one kernel test that
/// collects (`WeakTest>>testWeakArrayLosesItsReferent` calls `Smalltalk
/// garbageCollect`): its fields as strings.
private func verifySummary(_ verify: Bool?) throws -> [String: String] {
    var o = Headless.Options()
    o.heapMiB = 256
    if let verify { o.verify = verify }
    let lines = Lines()
    let r = Headless.test(image: kernelImage, arguments: ["--test", "WeakTest>>testWeakArrayLosesItsReferent"], options: o) { lines.add($0) }
    #expect((try? r.get()) == 0, "the test run answered \(r)")
    let summary = try #require(lines.all.compactMap { l -> [String: Any]? in
        guard let d = try? JSONSerialization.jsonObject(with: Data(l)) as? [String: Any],
              d["kind"] as? String == "gc", d["collection"] as? String == "summary" else { return nil }
        return d
    }.last, "no gc summary")
    var out: [String: String] = [:]
    for (k, v) in summary { out[k] = "\(v)" }
    return out
}

/// A checked build verifies at every pause by default and says so; a run
/// told not to says off and ran no verifier; a run told to verifies in any
/// build. On 0b33ed3 the summary had no `verify` field and the default
/// overwrote the checked build's (no verifier ran).
@Test func aHeadlessRunReportsItsVerifierLevel() throws {
    let byDefault = try verifySummary(nil)
    #expect(byDefault["verify"] == (checkedBuild ? "on" : "off"), "default: \(byDefault)")
    if checkedBuild { #expect(Int(byDefault["verifies"] ?? "") ?? 0 > 0, "default: \(byDefault)") }
    let off = try verifySummary(false)
    #expect(off["verify"] == "off", "off: \(off)")
    #expect(off["verifies"] == "0", "off: \(off)")
    let on = try verifySummary(true)
    #expect(on["verify"] == "on", "on: \(on)")
    #expect(Int(on["verifies"] ?? "") ?? 0 > 0, "on: \(on)")
}

// MARK: - item 2: Monitor and SharedQueue under termination

private let monitorDirectory: String = {
    var url = URL(fileURLWithPath: #filePath)
    url.deleteLastPathComponent()
    return url.appendingPathComponent("Fixtures/monitor").path
}()

private let monitorImage: [UInt8] = {
    try! KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, monitorDirectory])).image
}()

/// The image driven slice by slice on one worker, as the review fixes'
/// item 14 tests drive `critical:` (`ReviewFixesKernelTests`), so each
/// termination lands exactly where the test puts it.
private final class MonitorStepped {
    let img: Image
    let vm: VM
    let cls: Oop

    init() throws {
        var o = Headless.Options()
        o.heapMiB = 256
        o.workers = 2
        let (vc, c) = try Headless.configs(o).get()
        var oc = c
        oc.onVerifyFailure = .record
        img = try Image.load(image: monitorImage, config: oc)
        vm = VM(image: img, config: vc)
        cls = img.om.classOop(img.classIndex(named: "MonitorProbe")!)
    }

    func spawn(_ selector: String) throws -> Oop { try #require(vm.spawn(receiver: cls, selector: selector)) }

    /// Run slices on worker 1 until nothing is ready (bounded).
    func settle() {
        for _ in 0..<10_000 where vm.runOneSlice(worker: 1) {}
    }

    /// `MonitorProbe selector` run to its end: its SmallInteger answer.
    func answer(_ selector: String) throws -> Int64? {
        let p = try spawn(selector)
        settle()
        #expect(vm.state(of: p) == .terminated, "\(selector) did not end")
        defer { vm.release(p) }
        let v = vm.result(of: p)
        return v.isSmallInteger ? v.smallIntegerValue : nil
    }

    /// `answer(selector)` is `want`; the message names what it was.
    func expect(_ selector: String, _ want: Int64, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let got = try answer(selector)
        #expect(got == want, "\(selector) answered \(got.map(String.init) ?? "nil"), not \(want)", sourceLocation: sourceLocation)
    }

    func end() {
        vm.terminateAll()
        settle()
        #expect(img.om.counters.verifierFailures == 0)
        vm.destroy()
        img.destroy()
    }
}

@Suite(.serialized) struct MonitorTerminationTests {
    /// Terminated while it waits to enter (the VM unlinks it from the
    /// mutex): nothing comes back, and the test's release leaves the
    /// mutex's one signal.
    @Test func aProcessTerminatedWhileItWaitsToEnterGivesNothingBack() throws {
        let t = try MonitorStepped()
        try t.expect("setUp", 0)
        let p = try t.spawn("enter")
        t.settle()
        #expect(t.vm.state(of: p) == .waiting)
        #expect(t.vm.interruptProcess(p, kind: 1))
        t.settle()
        #expect(t.vm.state(of: p) == .terminated)
        try t.expect("release", 0)
        try t.expect("excess", 1)
        try t.expect("entered", 0)
        t.vm.release(p)
        t.end()
    }

    /// Released into the Monitor by the mutex's signal and terminated
    /// before it runs again: it holds the mutex and must give it back. On
    /// 0b33ed3 `critical:` waited before its `ensure:`, the terminate
    /// (left for the first poll, at the `ensure:` send) unwound past no
    /// ensure block, and the Monitor was never free again (excess 0).
    @Test func aProcessReleasedIntoTheMonitorAndTerminatedGivesItBack() throws {
        let t = try MonitorStepped()
        try t.expect("setUp", 0)
        let p = try t.spawn("enter")
        t.settle()
        #expect(t.vm.state(of: p) == .waiting)
        let r = try t.spawn("release")
        #expect(t.vm.runOneSlice(worker: 1))
        #expect(t.vm.state(of: r) == .terminated)
        t.vm.release(r)
        #expect(t.vm.state(of: p) == .ready)
        #expect(t.vm.interruptProcess(p, kind: 1))
        t.settle()
        #expect(t.vm.state(of: p) == .terminated)
        try t.expect("excess", 1)
        t.vm.release(p)
        t.end()
    }

    /// Terminated while it waits on the condition (`Monitor>>wait` gave the
    /// mutex back): its unwinding must not signal the mutex again, and its
    /// condition Semaphore leaves the waiters. On 0b33ed3 `critical:`'s
    /// ensure block signalled a mutex it no longer held (excess 2: two
    /// Processes could be inside) and the dead waiter stayed queued.
    @Test func aProcessTerminatedWhileItWaitsOnTheConditionGivesNothingBack() throws {
        let t = try MonitorStepped()
        try t.expect("setUpFree", 0)
        let p = try t.spawn("waitInside")
        t.settle()
        #expect(t.vm.state(of: p) == .waiting)
        try t.expect("excess", 1)
        try t.expect("waiters", 1)
        #expect(t.vm.interruptProcess(p, kind: 1))
        t.settle()
        #expect(t.vm.state(of: p) == .terminated)
        try t.expect("excess", 1)
        try t.expect("waiters", 0)
        t.vm.release(p)
        t.end()
    }

    /// Two consumers wait in `SharedQueue>>next`, the first is terminated,
    /// one item is put: the live consumer gets it and the queue's Monitor
    /// is free once. On 0b33ed3 the item's signal went to the terminated
    /// consumer's Semaphore, the live one waited for ever, and the mutex
    /// held two signals.
    @Test func aSharedQueueServesItsLiveConsumerAfterOneIsTerminated() throws {
        let t = try MonitorStepped()
        try t.expect("setUpFree", 0)
        let c1 = try t.spawn("consume")
        let c2 = try t.spawn("consume")
        t.settle()
        #expect(t.vm.state(of: c1) == .waiting)
        #expect(t.vm.state(of: c2) == .waiting)
        #expect(t.vm.interruptProcess(c1, kind: 1))
        t.settle()
        #expect(t.vm.state(of: c1) == .terminated)
        try t.expect("produce", 0)
        t.settle()
        #expect(t.vm.state(of: c2) == .terminated, "the live consumer was not woken")
        let v = t.vm.result(of: c2)
        #expect(v.isSmallInteger && v.smallIntegerValue == 5)
        try t.expect("queueExcess", 1)
        try t.expect("queueWaiters", 0)
        t.vm.release(c1)
        t.vm.release(c2)
        t.end()
    }
}

// MARK: - item 7: a reply after its request timed out

/// A Unix socket that accepts one connection, reads the client's first
/// request line, and only after the client's second line writes the reply
/// to request 1 and then an event line: the reply arrives after its
/// request timed out, and the event says it has been read.
final class LateReplyTarget: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var conn: Int32 = -1
    let path: String

    init(path: String) throws {
        self.path = path
        unlink(path)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = ProtocolServer.address(path)
        let r = withUnsafePointer(to: &addr) {
            unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard r == 0, listen(s, 1) == 0 else { throw ProtocolError("late reply target: bind") }
        fd = s
        let t = Thread { [self] in
            let c = accept(s, nil, nil)
            guard c >= 0 else { return }
            var one: Int32 = 1
            _ = unsafe setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            conn = c
            lock.unlock()
            var b = [UInt8](repeating: 0, count: 1)
            var lines = 0
            while lines < 2 {
                let n = unsafe read(c, &b, 1)
                if n != 1 { break }
                if b[0] == 10 { lines += 1 }
            }
            let bytes = Array(#"{"v":1,"kind":"reply","id":1,"ok":true,"result":7}"#.utf8) + [10]
                + Array(#"{"v":1,"kind":"log","text":"after"}"#.utf8) + [10]
            var off = 0
            while off < bytes.count {
                let n = bytes.withUnsafeBytes { unsafe write(c, $0.baseAddress! + off, bytes.count - off) }
                if n <= 0 { break }
                off += n
            }
        }
        t.start()
    }

    func stop() {
        lock.lock()
        let c = conn
        lock.unlock()
        if c >= 0 { close(c) }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(path)
    }
}

/// A reply that comes after its request gave up is dropped, not kept: the
/// client's table of replies is empty once it is read. On 0b33ed3 it was
/// stored under its id for good (one entry, `pendingReplyCount` 1).
@Test func aReplyAfterItsRequestTimedOutIsDropped() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("kajo-late-\(getpid()).sock").path
    let t = try LateReplyTarget(path: path)
    defer { t.stop() }
    let c = try ProtocolClient(path: path)
    defer { c.close() }
    let mark = c.eventMark
    #expect(throws: ProtocolError.self) { _ = try c.send("evaluate", [("source", .string("7"))], timeout: 0.2) }
    try c.write(Array("{}".utf8))
    let after = c.waitForEvent(since: mark, timeout: 120) { $0["text"]?.string == "after" }
    #expect(after != nil, "the target's event did not come")
    #expect(c.pendingReplyCount == 0, "the late reply was kept")
}
