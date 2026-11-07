// The development answers (docs/modules/development-answers.md), part 1: a
// development image stops an unhandled error's Process wherever a debugger
// can still come, with or without a client, and never in a batch host. The
// host says which it is with one setting before the image resumes
// (`Headless.Options.stopsForDebugger`, `ShellVM.stopsForDebugger`,
// primitive 165); every batch host here ends the forked Process with the
// report, every stopping host keeps it for a client that comes later.

import Darwin
import Foundation
import Synchronization
import Testing
@testable import KajoApp
@testable import KajoAppDevelopment
@testable import KajoCompiler
@testable import KajoDev
@testable import KajoVM

let answersFixtureDirectory: String = {
    var url = URL(fileURLWithPath: #filePath)
    url.deleteLastPathComponent()
    return url.appendingPathComponent("Fixtures/answers").path
}()

/// The kernel and the fixture (package Answers), as a development image
/// and as a release image.
let answersImage: [UInt8] = {
    try! KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, answersFixtureDirectory])).image
}()

let answersReleaseImage: [UInt8] = {
    var o = KernelBuild.Options()
    o.release = true
    return try! KernelBuild.build(KernelBuild.sources(in: [kernelDirectory, answersFixtureDirectory]), options: o).image
}()

func answersImageFile(_ tag: String, _ bytes: [UInt8] = answersImage) -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("kajo-answers-\(getpid())-\(tag).img").path
    FileManager.default.createFile(atPath: path, contents: Data(bytes))
    return path
}

/// How long a host may take to end before the test calls it hung: a host
/// that stops a Process nobody can reach never ends, and the test fails at
/// this bound rather than waiting with it.
let hostBoundSeconds: Double = compilerTestsUnderThreadSanitizer ? 600 : 120

/// Runs `f` on a thread of its own; nil when it did not return within
/// `seconds` (the thread is left behind: the host hung).
func within<T: Sendable>(_ seconds: Double, _ f: @escaping @Sendable () -> T) -> T? {
    let box = Mutex<T?>(nil)
    let done = DispatchSemaphore(value: 0)
    let t = Thread {
        let v = f()
        box.withLock { $0 = v }
        done.signal()
    }
    t.stackSize = 8 << 20
    t.start()
    guard done.wait(timeout: .now() + seconds) == .success else { return nil }
    return box.withLock { $0 }
}

/// The transcript lines among NDJSON event lines.
func transcriptLines(_ events: [[UInt8]]) -> [String] {
    events.compactMap { e -> String? in
        guard case .success(let v) = parseJSON(e), v["kind"]?.string == "transcript" else { return nil }
        return v["text"]?.string
    }
}

final class AnswerEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [[UInt8]] = []
    func add(_ l: [UInt8]) {
        lock.lock()
        lines.append(l)
        lock.unlock()
    }
    var all: [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

/// A ShellVM over `image` with no views, the host's setting given.
func answersVM(stops: Bool, image: [UInt8] = answersImage, events: AnswerEvents? = nil, shell: TestShell? = nil) throws -> ShellVM {
    var o = Headless.Options()
    o.heapMiB = 256
    o.workers = 2
    o.stopsForDebugger = stops
    var c = shell?.callbacks ?? ShellCallbacks()
    if let events { c.events = { events.add($0) } }
    let vm = try ShellVM(image: image, options: o, callbacks: c)
    vm.start()
    return vm
}

/// Spawn `selector` to AnswersProbe on a background worker and wait for its
/// answer (at most `hostBoundSeconds`).
func probe(_ vm: ShellVM, _ selector: String, _ args: [ShellValue] = []) -> ShellValue? {
    guard let p = vm.spawn(selector, receiver: "AnswersProbe", arguments: args) else { return nil }
    defer { vm.release(p) }
    let end = ShellVM.now() + UInt64(hostBoundSeconds * 1e9)
    while vm.state(of: p) != .terminated && ShellVM.now() < end { usleep(500) }
    return vm.state(of: p) == .terminated ? vm.result(of: p) : nil
}

/// Ask until `cond` holds of the probe's answer, at most `hostBoundSeconds`
/// (the condition is on work done, the bound only ends a failing test).
func probeUntil(_ vm: ShellVM, _ selector: String, _ cond: (ShellValue?) -> Bool) -> Bool {
    let end = ShellVM.now() + UInt64(hostBoundSeconds * 1e9)
    while ShellVM.now() < end {
        if cond(probe(vm, selector)) { return true }
        usleep(2000)
    }
    return false
}

@Suite(.serialized) struct DevelopmentAnswersTests {
    // MARK: batch hosts

    /// `kajo test`: the forked Process's unhandled error is reported and
    /// the Process ends; the run finishes with the test passed.
    @Test func kajoTestReportsAndEndsAForkedProcessError() {
        let events = AnswerEvents()
        let outcome = within(hostBoundSeconds) {
            Headless.test(image: answersImage, arguments: ["--filter", "AnswersBatchTest"]) { events.add($0) }
        }
        guard let outcome else { Issue.record("kajo test did not end: a batch host stopped a Process"); return }
        guard case .success(let failures) = outcome else { Issue.record("kajo test: \(outcome)"); return }
        #expect(failures == 0)
        #expect(transcriptLines(events.all).contains { $0 == "Unhandled MessageNotUnderstood" })
    }

    /// `kajo run` (and the golden mode, which runs images the same way).
    @Test func kajoRunReportsAndEndsAForkedProcessError() {
        let events = AnswerEvents()
        let outcome = within(hostBoundSeconds) { () -> Headless.Outcome in
            var o = Headless.Options()
            o.workers = 1
            o.heapMiB = 256
            o.events = { events.add($0) }
            return Headless.run(image: answersImage, options: o)
        }
        guard let outcome else { Issue.record("kajo run did not end: a batch host stopped a Process"); return }
        guard case .success(let checksum) = outcome.checksum else { Issue.record("kajo run: \(outcome.checksum)"); return }
        #expect(checksum == 1)
        #expect(transcriptLines(events.all).contains { $0 == "Unhandled MessageNotUnderstood" })
    }

    /// The image build's host (`KernelRun`: `kajo build-image` runs
    /// `Smalltalk initializeKernel` there and waits for every Process).
    @Test func theImageBuildsHostReportsAndEndsAForkedProcessError() throws {
        let problem = within(hostBoundSeconds) { () -> String? in
            var c = ObjectMemoryConfig()
            c.heapBytes = 256 << 20
            guard let image = try? Image.load(image: answersImage, config: c) else { return "load" }
            defer { image.destroy() }
            return image.runToCompletion(className: "AnswersProbe", selector: "recordForkEnded")
        }
        guard let problem else { Issue.record("the build's host did not end: a batch host stopped a Process"); return }
        #expect(problem == nil)
    }

    /// A shell VM whose host made no setting (the shells' tests, golden and
    /// scenario modes, the demo without a protocol): the default reports
    /// and ends.
    @Test func aShellVMWithTheDefaultSettingReportsAndEnds() throws {
        let events = AnswerEvents()
        var o = Headless.Options()
        o.heapMiB = 256
        o.workers = 2
        var c = ShellCallbacks()
        c.events = { events.add($0) }
        let vm = try ShellVM(image: answersImage, options: o, callbacks: c)
        vm.start()
        defer { vm.close() }
        #expect(vm.stopsForDebugger == false)
        #expect(probe(vm, "forkFailureAndWait") == .bool(true))
        #expect(probe(vm, "stopCount") == .int(0))
        #expect(transcriptLines(events.all).contains { $0.hasPrefix("Unhandled") })
    }

    /// A release image never stops, whatever its host says.
    @Test func aReleaseImageNeverStops() throws {
        let vm = try answersVM(stops: true, image: answersReleaseImage)
        defer { vm.close() }
        #expect(vm.isReleaseImage)
        #expect(probe(vm, "forkFailureAndWait") == .bool(true))
        #expect(probe(vm, "stopCount") == .int(0))
    }

    // MARK: stopping without a client

    /// No client and no protocol yet: the error stops its Process; serving
    /// starts later; a client that connects finds the stop in session.open's
    /// answer, reads its frames, defines the missing method and retries the
    /// send, and the Process finishes with the method's answer.
    @Test @MainActor func anErrorWithNoClientStopsAndALaterClientFindsIt() async throws {
        var o = Headless.Options()
        o.heapMiB = 256
        o.workers = 2
        o.stopsForDebugger = true
        let platform = PropertyPlatform()
        let rt = try ShellRuntime(imagePath: answersImageFile("later"), options: o, platform: platform, events: { _ in })
        rt.start()
        defer {
            rt.stopProtocol()
            rt.vm.close()
        }
        let vm = rt.vm
        let id = try #require(try await offMain { probe(vm, "forkFailure")?.int })
        #expect(try await offMain { probeUntil(vm, "lastIsStopped") { $0 == .bool(true) } })
        #expect(try await offMain { probe(vm, "lastIsTerminated") } == .bool(false))
        let server = try #require(try rt.serveProtocol(socket: socketNames.next()))
        let token = server.token, path = server.path
        let (info, frames, result): (JSONValue, JSONValue, String) = try await offMain {
            let c = try ProtocolClient(path: path)
            defer { c.close() }
            let info = try c.open(token: token, client: "agent:answers", package: "Answers")
            let frames = try c.request("process.frames", [("process", .int(id))])
            _ = try c.request("method.compile", [("className", .string("AnswersSample")), ("source", .string("missingPart\n\t^ 41")),
                                                 ("category", .string("computing"))])
            _ = try c.request("process.retrySend", [("process", .int(id))])
            var r = ""
            for _ in 0..<20000 where r != "42" {
                r = try c.eval("AnswersProbe result printString")["value"]?.string ?? ""
                if r != "'42'" { usleep(1000) } else { r = "42" }
            }
            return (info, frames, r)
        }
        let stopped = try #require(info["stopped"]?.array)
        let mine = try #require(stopped.first { $0["process"] == .int(id) })
        #expect(mine["reason"] == .string("error"))
        #expect(mine["error"]?.string?.contains("missingPart") == true)
        #expect((mine["frames"]?.array?.count ?? 0) > 0)
        #expect(frames.array?.contains { $0["method"]?.string?.contains("AnswersSample>>compute") == true } == true)
        #expect(result == "42")
        #expect(try await offMain { probe(vm, "stopCount") } == .int(0))
    }

    /// An app's own start-up: `open` fails before serving starts; the open
    /// Process stops, serving starts anyway, and a client finds it, defines
    /// the method and retries, and the app finishes opening.
    @Test @MainActor func anAppsStartUpErrorStopsAndServingStillStarts() async throws {
        let dir = scratchDirectory("answers-store")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = PairingTokenStore(directory: dir)
        let development = Development(store: store, loopbackOnly: true, advertise: false, presenter: RecordingPresenter())
        let platform = PropertyPlatform()
        let app = KajoAppRunner(configuration: KajoAppConfiguration(name: "Answers", appClass: "AnswersApp"), platform: platform,
                                development: development)
        #expect(app.start(imagePath: answersImageFile("app")))
        defer { closeApp(app) }
        // A launch tells the development half after the first frame.
        app.startDevelopment()
        let server = try #require(development.server)
        let port = try #require(server.port)
        let token = store.load()
        let (info, started): (JSONValue, String) = try await offMain {
            let c = try ProtocolClient(address: .tcp(host: "127.0.0.1", port: port))
            defer { c.close() }
            let info = try c.open(token: token, client: "developer", package: "Answers")
            guard let id = info["stopped"]?.array?.first?["process"] else { return (info, "no stop") }
            _ = try c.request("method.compile", [("className", .string("AnswersApp")), ("source", .string("startUpValue\n\t^ 7")),
                                                 ("category", .string("opening")), ("side", .string("class"))])
            _ = try c.request("process.retrySend", [("process", id)])
            var r = ""
            for _ in 0..<20000 where r != "7" {
                r = try c.eval("AnswersApp started printString")["value"]?.string ?? ""
                if r != "'7'" { usleep(1000) } else { r = "7" }
            }
            return (info, r)
        }
        let stops = try #require(info["stopped"]?.array)
        #expect(stops.count == 1)
        #expect(stops.first?["error"]?.string?.contains("startUpValue") == true)
        #expect(started == "7")
    }

    /// An error in the event loop's handler with no client: the loop hands
    /// itself over to a new Process (the next event is handled) and the old
    /// one stands stopped.
    @Test func theEventLoopHandsOverWithNoClient() throws {
        let shell = TestShell()
        let vm = try answersVM(stops: true, shell: shell)
        defer { vm.close() }
        #expect(try run(vm, "start", on: "UIEventLoop") == .bool(true))
        #expect(try run(vm, "breakSyntheticEvents", on: "AnswersProbe") == .bool(true))
        let before = try #require(try run(vm, "loopProcessId", on: "AnswersProbe")?.int)
        vm.post(ShellEvent(kind: .synthetic, value: .int(1), timeNs: ShellVM.now()))
        vm.post(ShellEvent(kind: .synthetic, value: .int(2), timeNs: ShellVM.now()))
        #expect(drive(vm, seconds: hostBoundSeconds) { probe(vm, "syntheticHandled") == .int(1) })
        #expect(probe(vm, "handOvers") == .int(1))
        #expect(probe(vm, "stoppedErrorCount") == .int(1))
        let after = try #require(try run(vm, "loopProcessId", on: "AnswersProbe")?.int)
        #expect(after != before)
        vm.post(ShellEvent(kind: .synthetic, value: .int(3), timeNs: ShellVM.now()))
        #expect(drive(vm, seconds: hostBoundSeconds) { probe(vm, "syntheticHandled") == .int(2) })
    }

    /// The cap: past `Debugger stopCap` standing error stops the newest
    /// error is reported and its Process ended, counted and written on the
    /// Transcript; the stops already standing stay.
    @Test func stopsAreCappedAndPastTheCapReportedAndEnded() throws {
        let events = AnswerEvents()
        let vm = try answersVM(stops: true, events: events)
        defer { vm.close() }
        let cap = try #require(probe(vm, "stopCap")?.int)
        let n = cap + 8
        #expect(probe(vm, "fill:", [.int(n)]) == .int(n))
        #expect(probeUntil(vm, "refusedStops") { $0 == .int(8) })
        #expect(probeUntil(vm, "stoppedErrorCount") { $0 == .int(cap) })
        // The lines follow the counts (written after the lock is let go):
        // wait for them, bounded.
        func lines() -> [String] { transcriptLines(events.all) }
        let end = ShellVM.now() + UInt64(hostBoundSeconds * 1e9)
        while ShellVM.now() < end && (lines().filter { $0.hasPrefix("Unhandled") }.count < 8
                                      || lines().filter { $0.contains(" stopped (error): ") }.count < cap) { usleep(2000) }
        let refusals = transcriptLines(events.all).filter { $0.contains("not stopped: \(cap) stops stand") }
        #expect(refusals.count == 8)
        #expect(transcriptLines(events.all).filter { $0.hasPrefix("Unhandled") }.count == 8)
        #expect(transcriptLines(events.all).filter { $0.hasPrefix("Process ") && $0.contains(" stopped (error): ") }.count == cap)
        // A further error is refused as well; the standing stops stay.
        #expect(probe(vm, "forkFailureAndWait") == .bool(true))
        #expect(probe(vm, "refusedStops") == .int(9))
        #expect(probe(vm, "stoppedErrorCount") == .int(cap))
    }

    /// A snapshot taken with a stop standing holds it: the resumed image
    /// lists it, and a client lets it go on.
    @Test func aSavedImageKeepsItsStops() throws {
        let vm = try answersVM(stops: true)
        let id = try #require(probe(vm, "forkFailure")?.int)
        #expect(probeUntil(vm, "lastIsStopped") { $0 == .bool(true) })
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("kajo-answers-saved-\(getpid()).img").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(vm.snapshot(to: path))
        vm.close()
        let bytes = try #require(FileManager.default.contents(atPath: path))
        let t = try RunningTarget([UInt8](bytes))
        defer { t.close() }
        let s = try t.session("agent:answers", package: "Answers")
        defer { s.close() }
        let list = try s.request("process.list")
        #expect(list.array?.contains { $0["process"] == .int(id) && $0["stopped"] == .string("error") } == true)
        _ = try s.request("method.compile", [("className", .string("AnswersSample")), ("source", .string("missingPart\n\t^ 41")),
                                             ("category", .string("computing"))])
        _ = try s.request("process.retrySend", [("process", .int(id))])
        var r = ""
        for _ in 0..<20000 where r != "'42'" {
            r = try s.eval("AnswersProbe result printString")["value"]?.string ?? ""
            if r != "'42'" { usleep(1000) }
        }
        #expect(r == "'42'")
    }

    // MARK: part 3: a cut-off unwinding is never silent

    /// process.terminate answers whether the unwinding ran to its end: a
    /// stopped Process and a waiting one whose ensure: block never ends are
    /// cut off at the bound, counted and written on the Transcript; one
    /// whose blocks end is unwound. The debugger's restart through the
    /// same block says it has not finished, where it stands.
    @Test func aCutOffUnwindingIsReportedThroughTheProtocol() throws {
        let t = try RunningTarget(answersImage)
        defer { t.close() }
        let s = try t.session("agent:answers", package: "Answers")
        defer { s.close() }
        func count() throws -> String { try s.eval("Unwinding cutOffCount")["value"]?.string ?? "" }
        let before = Int(try count()) ?? -1
        // A stopped Process whose ensure: block hangs.
        let mark = s.eventMark
        var (p, _) = try s.stopIn("AnswersSample new guarded")
        let r1 = try s.request("process.terminate", [("process", p)])
        #expect(r1["unwound"] == .bool(false))
        #expect(r1["cutOff"]?.string?.contains("cut off after") == true)
        #expect(r1["cutOff"]?.string?.contains("[] in AnswersSample>>guarded") == true)
        #expect(s.waitForEvent(since: mark, timeout: 60) {
            $0["kind"]?.string == "transcript" && $0["text"]?.string?.contains("its unwinding was cut off") == true
        } != nil)
        // A stopped Process whose blocks end: unwound.
        (p, _) = try s.stopIn("[AnswersSample new compute] ensure: [3 + 4]")
        let r2 = try s.request("process.terminate", [("process", p)])
        #expect(r2["unwound"] == .bool(true) && r2["cutOff"] == nil)
        // A waiting Process, not stopped, whose ensure: block hangs.
        let id = try s.eval("([[Semaphore new wait] ensure: [Semaphore new wait]] forkAt: 1) id")["value"]?.string ?? ""
        var n = 0
        while n < 3000, try s.eval("(Debugger processWithId: \(id)) state")["value"] != .string("#waiting") {
            usleep(1000)
            n += 1
        }
        let r3 = try s.request("process.terminate", [("process", .int(Int64(id) ?? -1))])
        #expect(r3["unwound"] == .bool(false))
        #expect(Int(try count()) == before + 2)
        // The debugger's restart unwinds through the same kind of block:
        // its answer says the unwinding has not finished and where.
        (p, _) = try s.stopIn("AnswersSample new callGuarded")
        let frames = try s.request("process.frames", [("process", p)]).array ?? []
        let k = try #require(frames.firstIndex { $0["method"] == .string("AnswersSample>>guarded") })
        let r4 = try s.request("process.restart", [("process", p), ("frame", .int(Int64(k + 1)))])
        #expect(r4["unwound"] == .bool(false))
        #expect(r4["cutOff"]?.string?.contains("has not finished unwinding") == true)
        #expect(r4["cutOff"]?.string?.contains("[] in AnswersSample>>guarded") == true)
        // Restart's unwinding is not a cut-off: the Process still runs it.
        #expect(Int(try count()) == before + 2)
        // Terminated there, it leaves the block it waits in and finds
        // nothing more to run: the block was already marked as run.
        let r5 = try s.request("process.terminate", [("process", p)])
        #expect(r5["unwound"] == .bool(true))
        #expect(Int(try count()) == before + 2)
    }

    /// The development answers' measurement (`KAJO_MEASURE=1`, release
    /// build): the memory standing stops hold and the cost of a full cap,
    /// in a VM of its own each round (the process's physical footprint
    /// after a full collection, before and after 32 Processes stop; the
    /// time from forking them to the last one standing; the time an error
    /// past the cap takes to be reported and ended).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KAJO_MEASURE"] != nil))
    func standingStopsMeasured() throws {
        func footprint() -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                unsafe $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    unsafe task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return kr == KERN_SUCCESS ? info.phys_footprint : 0
        }
        var lines: [String] = []
        for round in 1...5 {
            let vm = try answersVM(stops: true)
            defer { vm.close() }
            _ = probe(vm, "stopCount")
            if let p = vm.spawn("garbageCollect", receiver: "Smalltalk") { vm.waitUntilTerminated(p); vm.release(p) }
            let f0 = footprint()
            let cap = Int64(probe(vm, "stopCap")?.int ?? 32)
            let t0 = ShellVM.now()
            _ = probe(vm, "fill:", [.int(cap)])
            #expect(probeUntil(vm, "stoppedErrorCount") { $0 == .int(cap) })
            let fillMs = Double(ShellVM.now() - t0) / 1e6
            if let p = vm.spawn("garbageCollect", receiver: "Smalltalk") { vm.waitUntilTerminated(p); vm.release(p) }
            let f1 = footprint()
            let t1 = ShellVM.now()
            #expect(probe(vm, "forkFailureAndWait") == .bool(true))
            let refusedMs = Double(ShellVM.now() - t1) / 1e6
            lines.append("round=\(round) stops=\(cap) footprint_delta_kb=\((Int64(f1) - Int64(f0)) / 1024) per_stop_kb=\((Int64(f1) - Int64(f0)) / cap / 1024) fill_ms=\(String(format: "%.2f", fillMs)) refused_error_ms=\(String(format: "%.2f", refusedMs))")
        }
        let r = lines.joined(separator: "\n")
        print(r)
        if let f = ProcessInfo.processInfo.environment["KAJO_MEASURE_OUT"] { try? (r + "\n").write(toFile: f, atomically: true, encoding: .utf8) }
    }
}
