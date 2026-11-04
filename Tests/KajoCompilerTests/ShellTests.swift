// Module 9a: the public host surface (Sources/KajoVM/Shell/) with a test
// shell in Swift. The test thread is the shell's main thread: it runs the
// turns. The test shell's view host keeps a table of fake native views by
// handle and records every call and the thread it came on.

import Darwin
import Foundation
import Synchronization
import Testing
@testable import KajoCompiler
@testable import KajoVM

let shellFixtureDirectory: String = {
    var url = URL(fileURLWithPath: #filePath)
    url.deleteLastPathComponent()
    return url.appendingPathComponent("Fixtures/shell").path
}()

/// The kernel and the fixture, built once.
let shellImage: [UInt8] = {
    try! KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, shellFixtureDirectory])).image
}()

/// A fake native toolkit: views are property tables by handle.
final class TestShell: Sendable {
    struct State {
        var next = 1
        var views: [Int: [String: ShellValue]] = [:]
        var kinds: [Int: String] = [:]
        var children: [Int: [Int]] = [:]
        var calls: [ViewCall] = []
        var threads: Set<UInt64> = []
        var released: [Int] = []
        var stuck: [StuckReport] = []
        var events: [[UInt8]] = []
        var wakes = 0
    }
    let state = Mutex(State())

    var callbacks: ShellCallbacks {
        var c = ShellCallbacks()
        c.views = { [self] call in self.view(call) }
        c.release = { [self] h in self.state.withLock { $0.released.append(h) } }
        c.stuck = { [self] r in self.state.withLock { $0.stuck.append(r) } }
        c.events = { [self] e in self.state.withLock { $0.events.append(e) } }
        c.wakeMain = { [self] in self.state.withLock { $0.wakes += 1 } }
        return c
    }

    func view(_ call: ViewCall) -> ShellValue? {
        var tid: UInt64 = 0
        unsafe pthread_threadid_np(nil, &tid)
        return state.withLock { s -> ShellValue? in
            s.calls.append(call)
            s.threads.insert(tid)
            let a = call.arguments
            switch call.op {
            case "create":
                guard case .string(let kind)? = a.first else { return nil }
                let h = s.next
                s.next += 1
                s.views[h] = [:]
                s.kinds[h] = kind
                return .int(Int64(h))
            default: break
            }
            guard s.views[call.handle] != nil else { return nil }
            switch call.op {
            case "set":
                guard a.count == 2, case .string(let k) = a[0] else { return nil }
                s.views[call.handle]![k] = a[1]
                return a[1]
            case "get":
                guard a.count == 1, case .string(let k) = a[0] else { return nil }
                return s.views[call.handle]![k] ?? .nil
            case "frame":
                guard a.count == 4 else { return nil }
                for (k, v) in zip(["x", "y", "width", "height"], a) { s.views[call.handle]![k] = v }
                return .nil
            case "origin":
                guard a.count == 2 else { return nil }
                s.views[call.handle]!["x"] = a[0]
                s.views[call.handle]!["y"] = a[1]
                return .nil
            case "add":
                guard case .int(let c)? = a.first, s.views[Int(c)] != nil else { return nil }
                s.children[call.handle, default: []].append(Int(c))
                return .nil
            case "call":
                guard case .string(let m)? = a.first else { return nil }
                switch m {
                case "appendLine":
                    let old = s.views[call.handle]!["text"]?.string ?? ""
                    let line = a.count > 1 ? a[1].string ?? "" : ""
                    s.views[call.handle]!["text"] = .string(old.isEmpty ? line : old + "\n" + line)
                case "clear": s.views[call.handle]!["text"] = .string("")
                case "show", "close": s.views[call.handle]!["shown"] = .bool(m == "show")
                default: return nil
                }
                return .nil
            default:
                return nil
            }
        }
    }

    func property(_ h: Int, _ k: String) -> ShellValue? { state.withLock { $0.views[h]?[k] } }
    var calls: [ViewCall] { state.withLock { $0.calls } }
    var threads: Set<UInt64> { state.withLock { $0.threads } }
    var released: [Int] { state.withLock { $0.released } }
    var stuck: [StuckReport] { state.withLock { $0.stuck } }
    var events: [[UInt8]] { state.withLock { $0.events } }
}

func openShell(_ shell: TestShell, image: [UInt8] = shellImage, workers: Int = 2) throws -> ShellVM {
    var o = Headless.Options()
    o.heapMiB = 256
    o.workers = workers
    let vm = try ShellVM(image: image, options: o, callbacks: shell.callbacks)
    vm.start()
    return vm
}

/// Turns on this thread until `cond` holds (a bound in seconds, for a hang
/// only; the assertions are on what happened, not when).
@discardableResult
func drive(_ vm: ShellVM, seconds: Double = 30, until cond: () -> Bool) -> Bool {
    let end = ShellVM.now() + UInt64(seconds * 1e9)
    while !cond() {
        if ShellVM.now() > end { return false }
        if vm.runTurn(budgetNs: 2_000_000).slices == 0 { usleep(500) }
    }
    return true
}

/// Spawn and run to the end with turns on this thread; the answer.
func run(_ vm: ShellVM, _ selector: String, on receiver: String? = "ShellFixture", _ args: [ShellValue] = [],
         main: Bool = true) throws -> ShellValue? {
    let p = try #require(vm.spawn(selector, receiver: receiver, arguments: args, main: main))
    defer { vm.release(p) }
    #expect(drive(vm) { vm.state(of: p) == .terminated })
    if let f = vm.failure(of: p) { Issue.record("\(selector): \(f)") }
    return vm.result(of: p)
}

func myThread() -> UInt64 {
    var tid: UInt64 = 0
    unsafe pthread_threadid_np(nil, &tid)
    return tid
}

@Suite(.serialized) struct ShellTests {
    @Test func aTurnRunsMainAffineSmalltalkAndViewCallsReachTheHostOnThisThread() throws {
        let shell = TestShell()
        let vm = try openShell(shell)
        defer { vm.close() }
        let button = try #require(try run(vm, "buildCounter")?.int)
        let label = try #require(try run(vm, "labelHandle")?.int)
        #expect(shell.property(Int(label), "text") == .string("0"))
        #expect(shell.property(Int(button), "title") == .string("Press"))
        #expect(shell.property(Int(label), "width") == .int(200))
        #expect(shell.calls.first?.op == "create" && shell.calls.first?.arguments == [.string("window")])
        #expect(shell.threads == [myThread()])
        #expect(vm.counters.first { $0.name == "viewCalls" }!.value == UInt64(shell.calls.count))
    }

    @Test func eventsAreHandledInSmalltalkInTheTurnThatFollows() throws {
        let shell = TestShell()
        let vm = try openShell(shell)
        defer { vm.close() }
        let button = Int(try #require(try run(vm, "buildCounter")?.int))
        let label = Int(try #require(try run(vm, "labelHandle")?.int))
        // Events posted before the loop starts are counted by its
        // registration.
        vm.post(ShellEvent(kind: .click, target: button, timeNs: ShellVM.now()))
        #expect(try run(vm, "start", on: "UIEventLoop") == .bool(true))
        for _ in 0..<2 { vm.post(ShellEvent(kind: .click, target: button, timeNs: ShellVM.now())) }
        #expect(drive(vm) { shell.property(label, "text") == .string("3") })
        #expect(vm.queuedEvents == 0)
        // Synthetic events carry the time they happened.
        _ = try run(vm, "listen")
        let stamp = ShellVM.now() - 5_000_000
        vm.post(ShellEvent(kind: .synthetic, value: .int(77), timeNs: stamp))
        #expect(drive(vm) { shell.property(label, "text") == .string("77") })
        #expect(try run(vm, "lastTime") == .int(Int64(stamp / 1000)))
        // A frame event moves the probe through the view primitive.
        let probe = Int(try #require(try run(vm, "listen")?.int))
        vm.post(ShellEvent(kind: .frame, value: .int(123), timeNs: ShellVM.now()))
        #expect(drive(vm) { shell.property(probe, "x") == .int(123) })
        #expect(vm.counters.first { $0.name == "shellEvents" }!.value == 5)
        #expect(shell.threads == [myThread()])
    }

    @Test func aViewCallOffMainHopsToTheMainThread() throws {
        let shell = TestShell()
        let vm = try openShell(shell)
        defer { vm.close() }
        let worker = try run(vm, "fromBackground", main: false)
        // The Process ended on the main worker (0), where its call ran.
        #expect(worker == .int(0))
        #expect(shell.calls.contains { $0.op == "set" && $0.arguments == [.string("text"), .string("from the background")] })
        #expect(shell.threads == [myThread()])
        #expect(vm.counters.first { $0.name == "viewHops" }!.value >= 1)
    }

    @Test func deadWrappersReleaseTheirHandles() throws {
        let shell = TestShell()
        let vm = try openShell(shell)
        defer { vm.close() }
        #expect(try run(vm, "dropViews:", [.int(10)]) == .int(10))
        // The finalization Process releases them; no turn is needed.
        #expect(drive(vm) { shell.released.count >= 10 })
        #expect(Set(shell.released).count == shell.released.count)
    }

    @Test func aHogOnMainIsPreemptedAndReportedStuck() throws {
        let shell = TestShell()
        let vm = try openShell(shell)
        defer { vm.close() }
        let hog = try #require(vm.spawn("hog", receiver: "ShellFixture", main: true))
        var preempted = 0
        // Turns of 1 ms until the report (bounded for a hang only).
        let end = ShellVM.now() + 30_000_000_000
        while shell.stuck.isEmpty && ShellVM.now() < end {
            let t = vm.runTurn(budgetNs: 1_000_000)
            if t.preempted { preempted += 1 }
            vm.checkStuck(limitNs: 100_000_000)
            usleep(1000)
        }
        #expect(shell.stuck.count == 1)
        #expect(shell.stuck.first?.method == "hog" && shell.stuck.first?.process == hog.id)
        #expect(preempted > 0)
        // The event loop still gets the thread.
        #expect(try run(vm, "hasShell", on: "View") == .bool(true))
        vm.terminate(hog)
        vm.release(hog)
    }

    @Test func theKernelsViewTestsPassAgainstTheShell() throws {
        let shell = TestShell()
        let vm = try openShell(shell)
        defer { vm.close() }
        let p = try #require(vm.spawn("runViewTests", receiver: "ShellFixture", main: false))
        defer { vm.release(p) }
        #expect(drive(vm, seconds: 120) { vm.state(of: p) == .terminated })
        let report = TestReport(shell.events)
        #expect(report.total == 11 && report.passed == 11, "\(report.summary)")
        // The events are the v1 protocol, in time order.
        let ts = report.events.compactMap { $0["ts"] as? Int }
        #expect(ts == ts.sorted())
        #expect(report.events.allSatisfy { $0["v"] as? Int == 1 })
        // Every view call ran on the main thread (this one).
        #expect(shell.threads == [myThread()])
        #expect(shell.calls.contains { $0.op == "create" })
    }

    @Test func aSnapshotResumesTheEventLoopInANewShell() throws {
        let path = NSTemporaryDirectory() + "kajo-shell-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).img"
        defer { unlink(path) }
        do {
            let shell = TestShell()
            let vm = try openShell(shell)
            defer { vm.close() }
            _ = try run(vm, "buildCounter")
            #expect(try run(vm, "start", on: "UIEventLoop") == .bool(true))
            #expect(vm.snapshot(to: path))
        }
        let shell = TestShell()
        let data = try #require(FileManager.default.contents(atPath: path))
        var o = Headless.Options()
        o.heapMiB = 256
        o.workers = 2
        let vm = try ShellVM(image: [UInt8](data), options: o, callbacks: shell.callbacks)
        vm.start()
        defer { vm.close() }
        #expect(vm.resumedProcessCount >= 2)  // the saver and the event loop
        // The old wrappers came back detached; a new counter works through
        // the resumed loop.
        let button = Int(try #require(try run(vm, "buildCounter")?.int))
        let label = Int(try #require(try run(vm, "labelHandle")?.int))
        vm.post(ShellEvent(kind: .click, target: button, timeNs: ShellVM.now()))
        #expect(drive(vm) { shell.property(label, "text") == .string("1") })
    }

    @Test func closeIsIdempotentAndFreesTheVM() throws {
        let shell = TestShell()
        let vm = try openShell(shell)
        _ = try run(vm, "buildCounter")
        vm.close()
        vm.close()
        #expect(throws: ShellError.self) { _ = try ShellVM(image: [1, 2, 3], callbacks: shell.callbacks) }
    }
}
